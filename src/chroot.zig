//! Clean-chroot builds with devtools, the aurutils way: the chroot has its
//! own pacman.conf, generated from the host's, that includes the local
//! repository. makepkg inside the chroot then resolves AUR dependencies
//! like any other, and arch-nspawn bind-mounts every `file://` repository
//! read-only, so nothing has to be injected with `makechrootpkg -I`.
//!
//! Layout under the chroot directory ($CHROOT_DIR, default
//! /var/lib/aurodle/chroot):
//!   pacman.conf  generated once, never overwritten, so users can edit it
//!   root/        the pristine chroot, updated once per run
//!   <user>/      makechrootpkg's working copy, reset from root per build
const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const auth_mod = @import("auth.zig");
const color = @import("color.zig");

pub const default_dir = "/var/lib/aurodle/chroot";

/// The chroot directory: $CHROOT_DIR, or default_dir.
pub fn dir() []const u8 {
    if (std.c.getenv("CHROOT_DIR")) |p| {
        const value = std.mem.span(p);
        if (value.len > 0) return value;
    }
    return default_dir;
}

/// [options] directives copied into the chroot's pacman.conf. The others
/// describe the host (RootDir, DBPath, CacheDir, HookDir, GPGDir, LogFile)
/// or its preferences (IgnorePkg, HoldPkg, Color), which must not shape a
/// clean build.
const kept_options = [_][]const u8{
    "Architecture",
    "SigLevel",
    "LocalFileSigLevel",
    "RemoteFileSigLevel",
    "ParallelDownloads",
    "DisableDownloadTimeout",
};

const conf_header =
    \\# pacman.conf for aurodle's build chroot, generated from the host's
    \\# configuration. aurodle never overwrites this file: edit it to change
    \\# the repositories available to builds, or delete it to regenerate it.
    \\
;

/// Render the chroot's pacman.conf from `pacman-conf` output (the host's
/// resolved configuration, with Include files expanded). Keeps every
/// repository as configured, including the local one, and only the
/// [options] directives in kept_options. Caller frees.
pub fn renderPacmanConf(allocator: Allocator, dump: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, conf_header);

    var in_options = false;
    var lines = std.mem.splitScalar(u8, dump, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            in_options = std.mem.eql(u8, line, "[options]");
            try out.append(allocator, '\n');
        } else if (in_options and !isKeptOption(line)) {
            continue;
        }
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn isKeptOption(line: []const u8) bool {
    const end = std.mem.indexOfAny(u8, line, " =") orelse line.len;
    for (kept_options) |key| {
        if (std.mem.eql(u8, line[0..end], key)) return true;
    }
    return false;
}

/// Does a pacman.conf have a [`repo`] section?
pub fn confHasRepo(conf: []const u8, repo: []const u8) bool {
    var lines = std.mem.splitScalar(u8, conf, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < 2 or line[0] != '[' or line[line.len - 1] != ']') continue;
        if (std.mem.eql(u8, line[1 .. line.len - 1], repo)) return true;
    }
    return false;
}

/// Is "nosuid" among comma-separated mount options?
pub fn hasNosuid(options: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, std.mem.trim(u8, options, " \t\r\n"), ',');
    while (it.next()) |opt| {
        if (std.mem.eql(u8, opt, "nosuid")) return true;
    }
    return false;
}

/// Would a chroot at `path` live on a nosuid mount? sudo inside the chroot,
/// which makepkg uses to install build dependencies, cannot work there.
/// Checks the nearest existing ancestor; null if findmnt cannot tell.
fn onNosuidMount(allocator: Allocator, path: []const u8) !?bool {
    var existing = path;
    while (true) {
        std.Io.Dir.accessAbsolute(utils.currentIo(), existing, .{}) catch {
            existing = std.fs.path.dirname(existing) orelse return null;
            continue;
        };
        break;
    }
    const result = utils.runCommand(allocator, &.{ "findmnt", "-no", "OPTIONS", "-T", existing }) catch return null;
    defer result.deinit(allocator);
    if (!result.success()) return null;
    return hasNosuid(result.stdout);
}

/// The user aurodle runs as, who makepkg runs as inside the chroot.
pub fn currentUser() ?[]const u8 {
    if (std.c.getpwuid(std.c.getuid())) |pw| {
        if (pw.name) |name| return std.mem.span(name);
    }
    const user = std.c.getenv("USER") orelse return null;
    return std.mem.span(user);
}

/// Variables makechrootpkg reads from the environment before makepkg.conf.
/// The PACMAN_AUTH tool may reset the environment, so they are passed on
/// explicitly. PKGDEST is always set (see buildArgv).
const forwarded_vars = [_][:0]const u8{
    "SRCDEST",
    "SRCPKGDEST",
    "LOGDEST",
    "MAKEFLAGS",
    "PACKAGER",
    "NPROC",
    "GNUPGHOME",
    "SOURCE_DATE_EPOCH",
};

/// `NAME=value` for each forwarded variable set in aurodle's environment.
pub fn forwardedEnv(arena: Allocator) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (forwarded_vars) |name| {
        const value = std.c.getenv(name.ptr) orelse continue;
        const v = std.mem.span(value);
        if (v.len == 0) continue;
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ name, v }));
    }
    return out.toOwnedSlice(arena);
}

pub const BuildOptions = struct {
    chroot_dir: []const u8,
    user: []const u8,
    pkgdest: []const u8,
    /// From forwardedEnv.
    env: []const []const u8 = &.{},
    rebuild: bool = false,
};

/// argv for one chroot build, to run through PACMAN_AUTH in the clone
/// directory. `makechrootpkg -c -u` resets the working copy from root and
/// syncs its databases, so packages built earlier in the run are visible.
/// SUDO_USER and -U make makechrootpkg build as the user, own the products
/// and read the user's makepkg.conf even when PACMAN_AUTH is not sudo.
/// Allocations go to `arena`.
pub fn buildArgv(arena: Allocator, opts: BuildOptions) ![]const []const u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        "env",
        try std.fmt.allocPrint(arena, "SUDO_USER={s}", .{opts.user}),
        try std.fmt.allocPrint(arena, "PKGDEST={s}", .{opts.pkgdest}),
    });
    try argv.appendSlice(arena, opts.env);
    try argv.appendSlice(arena, &.{ "makechrootpkg", "-c", "-u", "-U", opts.user, "-r", opts.chroot_dir });
    if (opts.rebuild) try argv.appendSlice(arena, &.{ "--", "--force" });
    return argv.toOwnedSlice(arena);
}

/// Get the chroot ready for this run: check devtools and the mount, write
/// pacman.conf if missing, then create root or bring it up to date. Root is
/// updated once here so each build's `-u` only has to sync databases.
/// Returns false after printing why when the chroot cannot be used.
pub fn prepare(
    allocator: Allocator,
    auth: *auth_mod.Auth,
    cache_root: []const u8,
    repo_name: []const u8,
    err_writer: anytype,
    ec: color.Style,
) !bool {
    for ([_][]const u8{ "makechrootpkg", "mkarchroot", "arch-nspawn" }) |tool| {
        if (!utils.findOnPath(tool)) {
            err_writer.print("{s}error:{s} {s} not found -- install devtools: pacman -S devtools\n", .{ ec.red, ec.reset, tool });
            return false;
        }
    }

    const chroot_dir = dir();
    if (try onNosuidMount(allocator, chroot_dir) orelse false) {
        err_writer.print(
            "{s}error:{s} {s} is on a nosuid mount, where sudo cannot install build dependencies -- set CHROOT_DIR to another location\n",
            .{ ec.red, ec.reset, chroot_dir },
        );
        return false;
    }

    const conf_path = try std.fs.path.join(allocator, &.{ chroot_dir, "pacman.conf" });
    defer allocator.free(conf_path);
    const root_path = try std.fs.path.join(allocator, &.{ chroot_dir, "root" });
    defer allocator.free(root_path);

    if (!fileExists(conf_path)) {
        if (!try writePacmanConf(allocator, auth, cache_root, conf_path, err_writer, ec)) return false;
    }
    warnIfRepoMissing(allocator, conf_path, repo_name, err_writer, ec);

    const exit_code = if (!utils.dirExists(root_path)) blk: {
        err_writer.print("{s}::{s} creating chroot at {s}...\n", .{ ec.blue, ec.reset, chroot_dir });
        break :blk try auth.runInteractive(&.{ "mkarchroot", "-C", conf_path, root_path, "base-devel" }, null);
    } else blk: {
        err_writer.print("{s}::{s} updating chroot at {s}...\n", .{ ec.blue, ec.reset, chroot_dir });
        // -C also copies pacman.conf into root, so edits and chroots made
        // before it existed pick it up.
        break :blk try auth.runInteractive(&.{ "arch-nspawn", "-C", conf_path, root_path, "pacman", "-Syu", "--noconfirm" }, null);
    };
    if (exit_code != 0) {
        err_writer.print("{s}error:{s} failed to set up the chroot (exit {d})\n", .{ ec.red, ec.reset, exit_code });
        return false;
    }
    return true;
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(utils.currentIo(), path, .{}) catch return false;
    return true;
}

/// Generate the chroot's pacman.conf from the host's. The chroot directory
/// is root-owned, so the file is staged in the cache and installed through
/// PACMAN_AUTH.
fn writePacmanConf(
    allocator: Allocator,
    auth: *auth_mod.Auth,
    cache_root: []const u8,
    conf_path: []const u8,
    err_writer: anytype,
    ec: color.Style,
) !bool {
    const dump = try utils.runCommand(allocator, &.{"pacman-conf"});
    defer dump.deinit(allocator);
    if (!dump.success()) {
        err_writer.print("{s}error:{s} pacman-conf failed: {s}\n", .{ ec.red, ec.reset, dump.stderr });
        return false;
    }
    const conf = try renderPacmanConf(allocator, dump.stdout);
    defer allocator.free(conf);

    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), utils.currentIo(), cache_root);
    const staged = try std.fs.path.join(allocator, &.{ cache_root, "chroot-pacman.conf" });
    defer allocator.free(staged);
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), utils.currentIo(), .{ .sub_path = staged, .data = conf });
    defer std.Io.Dir.deleteFile(std.Io.Dir.cwd(), utils.currentIo(), staged) catch {};

    err_writer.print("{s}::{s} writing {s}\n", .{ ec.blue, ec.reset, conf_path });
    const result = try auth.runCaptured(&.{ "install", "-D", "-m644", staged, conf_path });
    defer result.deinit(allocator);
    if (!result.success()) {
        err_writer.print("{s}error:{s} could not write {s}: {s}\n", .{ ec.red, ec.reset, conf_path, result.stderr });
        return false;
    }
    return true;
}

/// Builds still work without the local repository in the chroot's
/// pacman.conf (an edit may have removed it), but not ones with AUR
/// dependencies.
fn warnIfRepoMissing(allocator: Allocator, conf_path: []const u8, repo_name: []const u8, err_writer: anytype, ec: color.Style) void {
    const conf = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), utils.currentIo(), conf_path, allocator, .limited(1024 * 1024)) catch return;
    defer allocator.free(conf);
    if (!confHasRepo(conf, repo_name)) {
        err_writer.print(
            "{s}warning:{s} {s} has no [{s}] section; builds with AUR dependencies will fail\n",
            .{ ec.yellow, ec.reset, conf_path, repo_name },
        );
    }
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "renderPacmanConf keeps repositories and only build-relevant options" {
    const dump =
        \\[options]
        \\RootDir = /
        \\DBPath = /var/lib/pacman/
        \\CacheDir = /var/cache/pacman/pkg/
        \\HoldPkg = pacman
        \\IgnorePkg = linux
        \\Architecture = x86_64
        \\Color
        \\ParallelDownloads = 5
        \\SigLevel = PackageRequired
        \\SigLevel = DatabaseOptional
        \\LocalFileSigLevel = PackageOptional
        \\[core]
        \\Usage = All
        \\Server = https://mirror.example/core/os/x86_64
        \\[aur]
        \\Usage = All
        \\SigLevel = PackageOptional
        \\SigLevel = PackageTrustAll
        \\Server = file:///var/lib/aurodle/aur
        \\
    ;
    const conf = try renderPacmanConf(testing.allocator, dump);
    defer testing.allocator.free(conf);

    try testing.expectEqualStrings(conf_header ++
        \\
        \\[options]
        \\Architecture = x86_64
        \\ParallelDownloads = 5
        \\SigLevel = PackageRequired
        \\SigLevel = DatabaseOptional
        \\LocalFileSigLevel = PackageOptional
        \\
        \\[core]
        \\Usage = All
        \\Server = https://mirror.example/core/os/x86_64
        \\
        \\[aur]
        \\Usage = All
        \\SigLevel = PackageOptional
        \\SigLevel = PackageTrustAll
        \\Server = file:///var/lib/aurodle/aur
        \\
    , conf);
    try testing.expect(confHasRepo(conf, "aur"));
    try testing.expect(confHasRepo(conf, "core"));
    try testing.expect(!confHasRepo(conf, "options2"));
    try testing.expect(!confHasRepo(conf, "multilib"));
}

test "isKeptOption matches whole directive names" {
    try testing.expect(isKeptOption("SigLevel = Required"));
    try testing.expect(isKeptOption("Architecture=auto"));
    try testing.expect(!isKeptOption("SigLevelX = Required"));
    try testing.expect(!isKeptOption("CacheDir = /x"));
    try testing.expect(!isKeptOption("Color"));
}

test "hasNosuid finds the option among mount options" {
    try testing.expect(hasNosuid("rw,nosuid,nodev,size=12304304k\n"));
    try testing.expect(hasNosuid("nosuid"));
    try testing.expect(!hasNosuid("rw,relatime,discard\n"));
    try testing.expect(!hasNosuid("rw,nosuidx"));
    try testing.expect(!hasNosuid(""));
}

test "buildArgv passes the user and PKGDEST and builds without -I" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const argv = try buildArgv(arena.allocator(), .{
        .chroot_dir = "/var/lib/aurodle/chroot",
        .user = "alice",
        .pkgdest = "/var/lib/aurodle/aur",
        .env = &.{"MAKEFLAGS=-j8"},
    });
    const expected = [_][]const u8{
        "env",           "SUDO_USER=alice", "PKGDEST=/var/lib/aurodle/aur", "MAKEFLAGS=-j8",
        "makechrootpkg", "-c",              "-u",                           "-U",
        "alice",         "-r",              "/var/lib/aurodle/chroot",
    };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |e, a| try testing.expectEqualStrings(e, a);
}

test "buildArgv forwards --force to makepkg on rebuild" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const argv = try buildArgv(arena.allocator(), .{
        .chroot_dir = "/c",
        .user = "alice",
        .pkgdest = "/p",
        .rebuild = true,
    });
    try testing.expectEqualStrings("--", argv[argv.len - 2]);
    try testing.expectEqualStrings("--force", argv[argv.len - 1]);
}
