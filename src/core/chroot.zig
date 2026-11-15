//! Clean-chroot builds with devtools, the aurutils way: the chroot has its
//! own pacman.conf, devtools' clean-build template plus the local
//! repository. makepkg inside the chroot then resolves AUR dependencies
//! like any other, and arch-nspawn bind-mounts every `file://` repository
//! read-only, so nothing has to be injected with `makechrootpkg -I`.
//!
//! Layout under the chroot directory ($CHROOT_DIR, default
//! /var/lib/aurodle/chroot):
//!   pacman.conf  generated once, never overwritten, so users can edit it;
//!                must serve the local repository from its directory
//!   makepkg.conf optional; replaces devtools' makepkg.conf for builds
//!   root/        the pristine chroot, updated once per run
//!   <user>/      makechrootpkg's working copy, reset from root per build
//!
//! Like `aur build`, each package is built into an empty staging PKGDEST
//! and what lands there is moved into the repository, so the files to add
//! are exactly the ones this build produced.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const auth_mod = @import("auth.zig");
const Reporter = @import("report.zig").Reporter;

pub const default_dir = "/var/lib/aurodle/chroot";

/// The chroot directory: $CHROOT_DIR, or default_dir.
pub fn dir() []const u8 {
    if (std.c.getenv("CHROOT_DIR")) |p| {
        const value = std.mem.span(p);
        if (value.len > 0) return value;
    }
    return default_dir;
}

/// devtools' pacman.conf templates, the ones its own clean chroots use:
/// official repositories only, with `Include = /etc/pacman.d/mirrorlist`,
/// which arch-nspawn fills from the host's mirrors on every run.
const devtools_conf_dir = "/usr/share/devtools/pacman.conf.d";

const conf_header =
    \\# pacman.conf for aurodle's build chroot: devtools' template for clean
    \\# builds, followed by the local repository. aurodle never overwrites
    \\# this file: edit it to change the repositories available to builds,
    \\# or delete it to generate it again.
    \\
    \\
;

/// The devtools template for a host with these repositories
/// (`pacman-conf --repo-list` output): with [multilib] when the host has
/// it on x86_64, as aurutils does, so 32-bit packages build.
pub fn templatePath(repo_list: []const u8, x86_64: bool) []const u8 {
    if (x86_64 and listHasLine(repo_list, "multilib")) return devtools_conf_dir ++ "/multilib.conf";
    return devtools_conf_dir ++ "/extra.conf";
}

fn listHasLine(list: []const u8, wanted: []const u8) bool {
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r"), wanted)) return true;
    }
    return false;
}

/// Render the chroot's pacman.conf: the devtools template, then the local
/// repository's section as the host resolves it (`pacman-conf --repo`
/// output: Usage, SigLevel, Server). Caller frees.
pub fn renderPacmanConf(allocator: Allocator, template: []const u8, repo_name: []const u8, repo_dump: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, conf_header);
    try out.appendSlice(allocator, template);
    if (template.len > 0 and template[template.len - 1] != '\n') try out.append(allocator, '\n');
    try out.print(allocator, "\n[{s}]\n", .{repo_name});
    var lines = std.mem.splitScalar(u8, repo_dump, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// Does one of these servers (`pacman-conf --repo NAME Server` output,
/// one per line) point to `repo_dir`?
pub fn serversInclude(servers: []const u8, repo_dir: []const u8) bool {
    const want = std.mem.trimEnd(u8, repo_dir, "/");
    var lines = std.mem.splitScalar(u8, servers, '\n');
    while (lines.next()) |raw| {
        const url = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, url, "file://")) continue;
        if (std.mem.eql(u8, std.mem.trimEnd(u8, url["file://".len..], "/"), want)) return true;
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
    "SSH_AUTH_SOCK",
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

/// Name of the staging PKGDEST under the cache root.
const staging_name = "chroot-pkgdest";

/// Create the staging PKGDEST under `cache_root`, or empty it if a failed
/// build left files there. Returns its absolute path, which makechrootpkg
/// needs. Caller frees.
pub fn resetStaging(allocator: Allocator, io: std.Io, cache_root: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    const path = try std.fs.path.join(allocator, &.{ cache_root, staging_name });
    defer allocator.free(path);
    cwd.deleteTree(io, path) catch {};
    try cwd.createDirPath(io, path);
    const abs = try cwd.realPathFileAlloc(io, path, allocator);
    defer allocator.free(abs);
    return allocator.dupe(u8, abs);
}

/// Move every file in `staging` into `repo_dir`, replacing files of the
/// same name (a rebuild). Returns the repo_dir paths of the package files,
/// without signatures (repo-add finds those itself), in name order.
/// Caller frees each path and the slice.
pub fn moveStaged(allocator: Allocator, io: std.Io, staging: []const u8, repo_dir: []const u8) ![]const []const u8 {
    const cwd = std.Io.Dir.cwd();
    var src = try cwd.openDir(io, staging, .{ .iterate = true });
    defer src.close(io);
    var dst = try cwd.openDir(io, repo_dir, .{});
    defer dst.close(io);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    for (names.items) |name| {
        src.rename(name, dst, name, io) catch |err| switch (err) {
            // The cache and the repository may be on different filesystems.
            error.CrossDevice => {
                try src.copyFile(name, dst, name, io, .{});
                try src.deleteFile(io, name);
            },
            else => |e| return e,
        };
        if (std.mem.endsWith(u8, name, ".sig")) continue;
        try paths.append(allocator, try std.fs.path.join(allocator, &.{ repo_dir, name }));
    }
    return paths.toOwnedSlice(allocator);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub const BuildOptions = struct {
    chroot_dir: []const u8,
    user: []const u8,
    /// The staging PKGDEST (see resetStaging).
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

/// Packages a new chroot starts with: base-devel, plus multilib-devel when
/// its pacman.conf (`pacman-conf --repo-list` output) has [multilib] on
/// x86_64, as aurutils does, so 32-bit packages can build.
pub fn basePackages(repo_list: []const u8, x86_64: bool) []const []const u8 {
    if (x86_64 and listHasLine(repo_list, "multilib")) return &.{ "base-devel", "multilib-devel" };
    return &.{"base-devel"};
}

/// The makepkg.conf chroot builds use, as aurutils picks it:
/// `makepkg.conf` in the chroot directory if the user wrote one, otherwise
/// the one devtools uses for clean builds on this architecture. Given to
/// mkarchroot and arch-nspawn with -M, so root always has it, and to
/// `makepkg --packagelist --config`, so the already-built check names the
/// files the chroot produces. Caller frees.
pub fn makepkgConfPath(allocator: Allocator, chroot_dir: []const u8, user_conf_exists: bool, arch: []const u8) ![]u8 {
    if (user_conf_exists) return std.fs.path.join(allocator, &.{ chroot_dir, "makepkg.conf" });
    return std.fmt.allocPrint(allocator, "/usr/share/devtools/makepkg.conf.d/{s}.conf", .{arch});
}

/// Get the chroot ready for this run: check devtools and the mount, write
/// pacman.conf if missing and check that it serves the local repository
/// from `repo_dir`, pick makepkg.conf, then create root or bring it up to
/// date. Root is updated once here so each build's `-u` only has to sync
/// databases.
/// Returns the makepkg.conf path (see makepkgConfPath; caller frees), or
/// null after reporting why when the chroot cannot be used.
pub fn prepare(
    allocator: Allocator,
    auth: *auth_mod.Auth,
    cache_root: []const u8,
    repo_name: []const u8,
    repo_dir: []const u8,
    reporter: Reporter,
) !?[]u8 {
    for ([_][]const u8{ "makechrootpkg", "mkarchroot", "arch-nspawn" }) |tool| {
        if (!utils.findOnPath(tool)) {
            reporter.print(.err, "{s} not found -- install devtools: pacman -S devtools", .{tool});
            return null;
        }
    }

    const chroot_dir = dir();
    if (try onNosuidMount(allocator, chroot_dir) orelse false) {
        reporter.print(.err, "{s} is on a nosuid mount, where sudo cannot install build dependencies -- set CHROOT_DIR to another location", .{chroot_dir});
        return null;
    }

    const conf_path = try std.fs.path.join(allocator, &.{ chroot_dir, "pacman.conf" });
    defer allocator.free(conf_path);
    const root_path = try std.fs.path.join(allocator, &.{ chroot_dir, "root" });
    defer allocator.free(root_path);

    if (!fileExists(conf_path)) {
        if (!try writePacmanConf(allocator, auth, cache_root, conf_path, repo_name, reporter)) return null;
    }
    if (!try checkRepo(allocator, conf_path, repo_name, repo_dir, reporter)) return null;

    const user_makepkg_conf = try std.fs.path.join(allocator, &.{ chroot_dir, "makepkg.conf" });
    defer allocator.free(user_makepkg_conf);
    const makepkg_conf = try makepkgConfPath(allocator, chroot_dir, fileExists(user_makepkg_conf), @tagName(builtin.cpu.arch));
    errdefer allocator.free(makepkg_conf);
    if (!fileExists(makepkg_conf)) {
        reporter.print(.err, "{s} not found -- write a makepkg.conf for the chroot at {s}", .{ makepkg_conf, user_makepkg_conf });
        allocator.free(makepkg_conf);
        return null;
    }

    // -C and -M copy pacman.conf and makepkg.conf into root, so edits and
    // chroots made before aurodle wrote them pick them up.
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    const creating = !utils.dirExists(root_path);
    if (creating) {
        const repo_list = try utils.runCommand(allocator, &.{ "pacman-conf", "--config", conf_path, "--repo-list" });
        defer repo_list.deinit(allocator);
        try argv.appendSlice(allocator, &.{ "mkarchroot", "-C", conf_path, "-M", makepkg_conf, root_path });
        try argv.appendSlice(allocator, basePackages(repo_list.stdout, builtin.cpu.arch == .x86_64));
    } else {
        try argv.appendSlice(allocator, &.{ "arch-nspawn", "-C", conf_path, "-M", makepkg_conf, root_path, "pacman", "-Syu", "--noconfirm" });
    }
    reporter.print(.info, "{s} chroot at {s} (makepkg.conf: {s})...", .{ if (creating) "creating" else "updating", chroot_dir, makepkg_conf });
    const exit_code = try auth.runInteractive(argv.items, null);
    if (exit_code != 0) {
        reporter.print(.err, "failed to set up the chroot (exit {d})", .{exit_code});
        allocator.free(makepkg_conf);
        return null;
    }
    return makepkg_conf;
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(utils.currentIo(), path, .{}) catch return false;
    return true;
}

/// Generate the chroot's pacman.conf (see renderPacmanConf). The chroot
/// directory is root-owned, so the file is staged in the cache and
/// installed through PACMAN_AUTH.
fn writePacmanConf(
    allocator: Allocator,
    auth: *auth_mod.Auth,
    cache_root: []const u8,
    conf_path: []const u8,
    repo_name: []const u8,
    reporter: Reporter,
) !bool {
    const repo_list = try utils.runCommand(allocator, &.{ "pacman-conf", "--repo-list" });
    defer repo_list.deinit(allocator);
    const repo_dump = try utils.runCommand(allocator, &.{ "pacman-conf", "--repo", repo_name });
    defer repo_dump.deinit(allocator);
    for ([_]utils.ProcessResult{ repo_list, repo_dump }) |r| {
        if (!r.success()) {
            reporter.print(.err, "pacman-conf failed: {s}", .{r.stderr});
            return false;
        }
    }

    const template_path = templatePath(repo_list.stdout, builtin.cpu.arch == .x86_64);
    const template = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), utils.currentIo(), template_path, allocator, .limited(1024 * 1024)) catch |err| {
        reporter.print(.err, "could not read {s}: {} -- reinstall devtools", .{ template_path, err });
        return false;
    };
    defer allocator.free(template);
    const conf = try renderPacmanConf(allocator, template, repo_name, repo_dump.stdout);
    defer allocator.free(conf);

    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), utils.currentIo(), cache_root);
    const staged = try std.fs.path.join(allocator, &.{ cache_root, "chroot-pacman.conf" });
    defer allocator.free(staged);
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), utils.currentIo(), .{ .sub_path = staged, .data = conf });
    defer std.Io.Dir.deleteFile(std.Io.Dir.cwd(), utils.currentIo(), staged) catch {};

    reporter.print(.info, "writing {s}", .{conf_path});
    const result = try auth.runCaptured(&.{ "install", "-D", "-m644", staged, conf_path });
    defer result.deinit(allocator);
    if (!result.success()) {
        reporter.print(.err, "could not write {s}: {s}", .{ conf_path, result.stderr });
        return false;
    }
    return true;
}

/// Builds read AUR dependencies from the repository the chroot's
/// pacman.conf names, and their packages are added to `repo_dir`: the
/// two must be the same, or builds would see a stale or missing database
/// (after an edit, or after the repository moved). Asks pacman-conf, so
/// Include files in an edited pacman.conf count.
fn checkRepo(
    allocator: Allocator,
    conf_path: []const u8,
    repo_name: []const u8,
    repo_dir: []const u8,
    reporter: Reporter,
) !bool {
    const servers = try utils.runCommand(allocator, &.{ "pacman-conf", "--config", conf_path, "--repo", repo_name, "Server" });
    defer servers.deinit(allocator);
    if (servers.success() and serversInclude(servers.stdout, repo_dir)) return true;
    if (servers.success()) {
        reporter.print(.err, "[{s}] in {s} has no Server = file://{s} -- edit the file, or delete it to generate it again", .{ repo_name, conf_path, repo_dir });
    } else {
        reporter.print(.err, "{s} has no usable [{s}] section ({s}) -- edit the file, or delete it to generate it again", .{ conf_path, repo_name, std.mem.trim(u8, servers.stderr, " \t\r\n") });
    }
    return false;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "templatePath adds multilib when the host has it on x86_64" {
    const with = "core\nextra\nmultilib\naur\n";
    try testing.expectEqualStrings(devtools_conf_dir ++ "/multilib.conf", templatePath(with, true));
    try testing.expectEqualStrings(devtools_conf_dir ++ "/extra.conf", templatePath(with, false));
    try testing.expectEqualStrings(devtools_conf_dir ++ "/extra.conf", templatePath("core\nextra\nmultilib-testing\n", true));
}

test "renderPacmanConf appends the local repository to the template" {
    const template =
        \\[options]
        \\Architecture = auto
        \\
        \\[core]
        \\Include = /etc/pacman.d/mirrorlist
    ;
    const dump =
        \\Usage = All
        \\SigLevel = PackageOptional
        \\Server = file:///var/lib/aurodle/aur
        \\
    ;
    const conf = try renderPacmanConf(testing.allocator, template, "aur", dump);
    defer testing.allocator.free(conf);

    try testing.expectEqualStrings(conf_header ++
        \\[options]
        \\Architecture = auto
        \\
        \\[core]
        \\Include = /etc/pacman.d/mirrorlist
        \\
        \\[aur]
        \\Usage = All
        \\SigLevel = PackageOptional
        \\Server = file:///var/lib/aurodle/aur
        \\
    , conf);
}

test "serversInclude matches the repository directory" {
    const servers = "https://mirror.example/aur\nfile:///var/lib/aurodle/aur/\n";
    try testing.expect(serversInclude(servers, "/var/lib/aurodle/aur"));
    try testing.expect(serversInclude(servers, "/var/lib/aurodle/aur/"));
    try testing.expect(!serversInclude(servers, "/var/lib/aurodle/other"));
    try testing.expect(!serversInclude(servers, "/var/lib/aurodle"));
    try testing.expect(!serversInclude("", "/var/lib/aurodle/aur"));
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
        .pkgdest = "/home/alice/.cache/aurodle/chroot-pkgdest",
        .env = &.{"MAKEFLAGS=-j8"},
    });
    const expected = [_][]const u8{
        "env",           "SUDO_USER=alice", "PKGDEST=/home/alice/.cache/aurodle/chroot-pkgdest", "MAKEFLAGS=-j8",
        "makechrootpkg", "-c",              "-u",                                                "-U",
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

test "resetStaging empties the staging directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    const first = try resetStaging(testing.allocator, testing.io, root);
    defer testing.allocator.free(first);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = staging_name ++ "/left-over.pkg.tar.zst", .data = "x" });

    const again = try resetStaging(testing.allocator, testing.io, root);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(first, again);
    try testing.expect(std.fs.path.isAbsolute(again));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, staging_name ++ "/left-over.pkg.tar.zst", .{}));
}

test "moveStaged moves every file and returns the packages without signatures" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "staging");
    try tmp.dir.createDirPath(testing.io, "repo");
    for ([_][]const u8{ "foo-1-1-x86_64.pkg.tar.zst", "foo-1-1-x86_64.pkg.tar.zst.sig", "foo-debug-1-1-x86_64.pkg.tar.zst" }) |name| {
        const sub = try std.fs.path.join(testing.allocator, &.{ "staging", name });
        defer testing.allocator.free(sub);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = "new" });
    }
    // A rebuild replaces the file already in the repository.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/foo-1-1-x86_64.pkg.tar.zst", .data = "old" });

    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const staging = try std.fs.path.join(testing.allocator, &.{ root, "staging" });
    defer testing.allocator.free(staging);
    const repo = try std.fs.path.join(testing.allocator, &.{ root, "repo" });
    defer testing.allocator.free(repo);

    const paths = try moveStaged(testing.allocator, testing.io, staging, repo);
    defer {
        for (paths) |p| testing.allocator.free(p);
        testing.allocator.free(paths);
    }
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expectEqualStrings("foo-1-1-x86_64.pkg.tar.zst", std.fs.path.basename(paths[0]));
    try testing.expectEqualStrings("foo-debug-1-1-x86_64.pkg.tar.zst", std.fs.path.basename(paths[1]));
    try testing.expectEqualStrings(repo, std.fs.path.dirname(paths[0]).?);

    var buf: [8]u8 = undefined;
    const data = try tmp.dir.readFile(testing.io, "repo/foo-1-1-x86_64.pkg.tar.zst", &buf);
    try testing.expectEqualStrings("new", data);
    try tmp.dir.access(testing.io, "repo/foo-1-1-x86_64.pkg.tar.zst.sig", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "staging/foo-1-1-x86_64.pkg.tar.zst", .{}));
}

test "makepkgConfPath prefers the user's makepkg.conf over devtools'" {
    const user = try makepkgConfPath(testing.allocator, "/c", true, "x86_64");
    defer testing.allocator.free(user);
    try testing.expectEqualStrings("/c/makepkg.conf", user);

    const devtools = try makepkgConfPath(testing.allocator, "/c", false, "x86_64");
    defer testing.allocator.free(devtools);
    try testing.expectEqualStrings("/usr/share/devtools/makepkg.conf.d/x86_64.conf", devtools);
}

test "basePackages adds multilib-devel with multilib on x86_64" {
    const with = "core\nextra\nmultilib\naur\n";
    try testing.expectEqual(@as(usize, 2), basePackages(with, true).len);
    try testing.expectEqualStrings("multilib-devel", basePackages(with, true)[1]);
    try testing.expectEqual(@as(usize, 1), basePackages(with, false).len);
    try testing.expectEqual(@as(usize, 1), basePackages("core\nextra\n", true).len);
}
