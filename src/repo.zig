const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

// ── Constants ────────────────────────────────────────────────────────────

pub const REPO_NAME = "aurpkgs";
pub const DB_FILENAME = "aurpkgs.db.tar.xz";
pub const DEFAULT_PKGEXT = ".pkg.tar.zst";
pub const DEFAULT_REPO_DIR = "/var/lib/aurodle/aurpkgs";

// ── Types ────────────────────────────────────────────────────────────────

pub const RepoPackage = struct {
    name: []const u8,
    version: []const u8,
    filename: []const u8,
};

pub const CleanResult = struct {
    removed_clones: []const []const u8,
    removed_logs: []const []const u8,
    bytes_freed: u64,
};

pub const MakepkgConfig = struct {
    pkgdest: ?[]const u8 = null,
    pkgext: []const u8 = DEFAULT_PKGEXT,
    owns_pkgext: bool = false,

    fn deinit(self: MakepkgConfig, allocator: Allocator) void {
        if (self.pkgdest) |p| allocator.free(p);
        if (self.owns_pkgext) allocator.free(self.pkgext);
    }
};

// ── Repository ───────────────────────────────────────────────────────────

pub const Repository = struct {
    allocator: Allocator,
    repo_dir: []const u8,
    db_path: []const u8,
    log_dir: []const u8,
    cache_dir: []const u8,
    makepkg_conf: MakepkgConfig,
    skip_repo_add: bool,

    /// Create a Repository using paths derived from makepkg.conf:
    /// - repo_dir: PKGDEST from makepkg.conf (falls back to /var/lib/aurodle/aurpkgs)
    /// - cache_dir: ~/.cache/aurodle (user-owned clones and logs)
    /// Parses makepkg.conf for PKGDEST and PKGEXT.
    pub fn init(allocator: Allocator) !Repository {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
        const cache_dir = try std.fs.path.join(allocator, &.{ home, ".cache/aurodle" });
        errdefer allocator.free(cache_dir);

        const conf = parseMakepkgConf(allocator) catch MakepkgConfig{};

        const repo_dir = if (conf.pkgdest) |p|
            try allocator.dupe(u8, p)
        else
            try allocator.dupe(u8, DEFAULT_REPO_DIR);
        errdefer allocator.free(repo_dir);

        return initFromParts(allocator, cache_dir, repo_dir, conf);
    }

    /// Create a Repository with an explicit cache root (for testing).
    /// Both repo_dir and cache_dir are under cache_root.
    /// Does NOT parse system makepkg.conf.
    pub fn initWithRoot(allocator: Allocator, cache_root: []const u8) !Repository {
        const cache_dir = try allocator.dupe(u8, cache_root);
        errdefer allocator.free(cache_dir);

        const repo_dir = try std.fs.path.join(allocator, &.{ cache_root, REPO_NAME });

        return initFromParts(allocator, cache_dir, repo_dir, .{});
    }

    fn initFromParts(allocator: Allocator, cache_dir: []const u8, repo_dir: []const u8, conf: MakepkgConfig) !Repository {
        const db_path = try std.fs.path.join(allocator, &.{ repo_dir, DB_FILENAME });
        errdefer allocator.free(db_path);
        const log_dir = try std.fs.path.join(allocator, &.{ cache_dir, "logs" });

        return .{
            .allocator = allocator,
            .cache_dir = cache_dir,
            .repo_dir = repo_dir,
            .db_path = db_path,
            .log_dir = log_dir,
            .makepkg_conf = conf,
            .skip_repo_add = false,
        };
    }

    pub fn deinit(self: *Repository) void {
        self.makepkg_conf.deinit(self.allocator);
        self.allocator.free(self.log_dir);
        self.allocator.free(self.db_path);
        self.allocator.free(self.repo_dir);
        self.allocator.free(self.cache_dir);
    }

    // ── Directory Management ─────────────────────────────────────────────

    /// Create repository and log directories if they don't exist.
    /// Idempotent — safe to call multiple times.
    pub fn ensureExists(self: *const Repository) !void {
        try std.fs.cwd().makePath(self.repo_dir);
        try std.fs.cwd().makePath(self.log_dir);
    }

    // ── Package Addition ─────────────────────────────────────────────────

    /// Find built packages in the repository directory (placed there by
    /// makepkg via PKGDEST) and update the database.
    /// Returns filenames of added packages.
    ///
    /// Handles split packages: one PKGBUILD may produce multiple .pkg.tar.* files.
    pub fn addBuiltPackages(self: *const Repository) ![]const []const u8 {
        const pkg_files = try self.findBuiltPackages(self.repo_dir);

        if (pkg_files.len == 0) return error.PackageNotFound;

        // Update database
        try self.runRepoAdd(pkg_files);

        return pkg_files;
    }

    /// Find .pkg.tar.* files in a directory matching PKGEXT.
    pub fn findBuiltPackages(self: *const Repository, dir_path: []const u8) ![]const []const u8 {
        var results: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (results.items) |p| self.allocator.free(p);
            results.deinit(self.allocator);
        }

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return results.toOwnedSlice(self.allocator),
            else => return err,
        };
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.endsWith(u8, entry.name, self.makepkg_conf.pkgext)) {
                const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
                try results.append(self.allocator, full_path);
            }
        }

        return results.toOwnedSlice(self.allocator);
    }

    /// Run `repo-add -R <db_path> <pkg1> <pkg2> ...`
    /// -R removes old package versions from disk automatically.
    fn runRepoAdd(self: *const Repository, pkg_paths: []const []const u8) !void {
        if (self.skip_repo_add) return;

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.ensureTotalCapacity(self.allocator, pkg_paths.len + 3);

        argv.appendAssumeCapacity("repo-add");
        argv.appendAssumeCapacity("-R");
        argv.appendAssumeCapacity(self.db_path);
        argv.appendSliceAssumeCapacity(pkg_paths);

        const result = try utils.runCommand(self.allocator, argv.items);
        defer result.deinit(self.allocator);

        if (!result.success()) return error.RepoAddFailed;
    }

    // ── Package Listing ──────────────────────────────────────────────────

    /// List all packages in the repository directory by scanning for .pkg.tar.* files.
    pub fn listPackages(self: *const Repository) ![]RepoPackage {
        var packages: std.ArrayList(RepoPackage) = .empty;
        errdefer {
            for (packages.items) |pkg| {
                self.allocator.free(pkg.name);
                self.allocator.free(pkg.version);
                self.allocator.free(pkg.filename);
            }
            packages.deinit(self.allocator);
        }

        var dir = std.fs.cwd().openDir(self.repo_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return packages.toOwnedSlice(self.allocator),
            else => return err,
        };
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            // Skip non-package files
            if (std.mem.indexOf(u8, entry.name, ".pkg.tar.") == null) continue;
            // Skip database files
            if (std.mem.startsWith(u8, entry.name, "aurpkgs.")) continue;

            if (parsePackageFilename(entry.name)) |parsed| {
                try packages.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, parsed.name),
                    .version = try self.allocator.dupe(u8, parsed.version),
                    .filename = try self.allocator.dupe(u8, entry.name),
                });
            }
        }

        return packages.toOwnedSlice(self.allocator);
    }

    // ── Configuration Check ──────────────────────────────────────────────

    /// Check if [aurpkgs] repository is configured in pacman.conf.
    pub fn isConfigured(self: *const Repository) !bool {
        _ = self;
        return isConfiguredFromPath("/etc/pacman.conf");
    }

    /// Copy-pasteable pacman.conf configuration for the aurpkgs repository.
    pub fn configInstructions() []const u8 {
        return
            \\Add the following to /etc/pacman.conf:
            \\
            \\[aurpkgs]
            \\SigLevel = Optional TrustAll
            \\Server = file:///var/lib/aurodle/aurpkgs
            \\
            \\Set PKGDEST in /etc/makepkg.conf:
            \\
            \\PKGDEST=/var/lib/aurodle/aurpkgs
            \\
            \\Then run:
            \\  sudo install -d -o $USER /var/lib/aurodle/aurpkgs
            \\  sudo pacman -Sy
        ;
    }

    // ── Clean ────────────────────────────────────────────────────────────

    /// Identify stale artifacts for removal.
    /// Returns a plan — actual deletion is done by cleanExecute().
    pub fn clean(self: *const Repository, installed_names: []const []const u8) !CleanResult {
        // Build set of installed names for O(1) lookup
        var installed: std.StringHashMapUnmanaged(void) = .empty;
        defer installed.deinit(self.allocator);
        for (installed_names) |name| {
            try installed.put(self.allocator, name, {});
        }

        // Find stale clones: directories in cache_dir that aren't installed
        var stale_clones: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (stale_clones.items) |s| self.allocator.free(s);
            stale_clones.deinit(self.allocator);
        }

        if (std.fs.cwd().openDir(self.cache_dir, .{ .iterate = true })) |dir_handle| {
            var cache = dir_handle;
            defer cache.close();

            var it = cache.iterate();
            while (try it.next()) |entry| {
                if (entry.kind != .directory) continue;
                if (std.mem.eql(u8, entry.name, REPO_NAME)) continue;
                if (std.mem.eql(u8, entry.name, "logs")) continue;

                if (!installed.contains(entry.name)) {
                    try stale_clones.append(self.allocator, try self.allocator.dupe(u8, entry.name));
                }
            }
        } else |_| {}

        // Find stale logs
        var stale_logs: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (stale_logs.items) |s| self.allocator.free(s);
            stale_logs.deinit(self.allocator);
        }

        if (std.fs.cwd().openDir(self.log_dir, .{ .iterate = true })) |dir_handle| {
            var log_dir = dir_handle;
            defer log_dir.close();

            var log_it = log_dir.iterate();
            while (try log_it.next()) |entry| {
                if (entry.kind != .file) continue;
                const stem = stripExtension(entry.name);
                if (!installed.contains(stem)) {
                    try stale_logs.append(self.allocator, try self.allocator.dupe(u8, entry.name));
                }
            }
        } else |_| {}

        return .{
            .removed_clones = try stale_clones.toOwnedSlice(self.allocator),
            .removed_logs = try stale_logs.toOwnedSlice(self.allocator),
            .bytes_freed = 0,
        };
    }

    /// Execute the actual deletion after user confirmation.
    pub fn cleanExecute(self: *const Repository, plan: CleanResult) void {
        for (plan.removed_clones) |name| {
            const path = std.fs.path.join(self.allocator, &.{ self.cache_dir, name }) catch continue;
            defer self.allocator.free(path);
            std.fs.cwd().deleteTree(path) catch {};
        }

        for (plan.removed_logs) |name| {
            const path = std.fs.path.join(self.allocator, &.{ self.log_dir, name }) catch continue;
            defer self.allocator.free(path);
            std.fs.cwd().deleteFile(path) catch {};
        }
    }

    /// Free a CleanResult's allocated slices.
    pub fn freeCleanResult(self: *const Repository, result: CleanResult) void {
        for (result.removed_clones) |s| self.allocator.free(s);
        self.allocator.free(result.removed_clones);
        for (result.removed_logs) |s| self.allocator.free(s);
        self.allocator.free(result.removed_logs);
    }
};

// ── Standalone Functions ─────────────────────────────────────────────────

/// Parse "pkgname-pkgver-pkgrel-arch.pkg.tar.ext" into name and version.
///
/// Package names can contain hyphens, so parsing is done right-to-left:
///   yay-bin-12.3.5-1-x86_64.pkg.tar.zst
///   ├─────┘ name = "yay-bin"
///   │       ├─────┘ version = "12.3.5-1"
///   │       │       └──────┘ arch = "x86_64"
pub fn parsePackageFilename(filename: []const u8) ?struct { name: []const u8, version: []const u8 } {
    // Strip .pkg.tar.* suffix
    const pkg_idx = std.mem.indexOf(u8, filename, ".pkg.tar.") orelse return null;
    const stem = filename[0..pkg_idx];

    // From the right: arch, then pkgrel, then pkgver; rest is pkgname
    const arch_sep = std.mem.lastIndexOfScalar(u8, stem, '-') orelse return null;
    const before_arch = stem[0..arch_sep];

    const rel_sep = std.mem.lastIndexOfScalar(u8, before_arch, '-') orelse return null;
    const before_rel = before_arch[0..rel_sep];

    const ver_sep = std.mem.lastIndexOfScalar(u8, before_rel, '-') orelse return null;

    return .{
        .name = stem[0..ver_sep],
        .version = stem[ver_sep + 1 .. arch_sep], // "pkgver-pkgrel"
    };
}

/// Check if [aurpkgs] is configured in a pacman.conf file.
pub fn isConfiguredFromPath(path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();

    // pacman.conf is small — read entire file
    var buf: [64 * 1024]u8 = undefined;
    const len = file.readAll(&buf) catch return false;
    const content = buf[0..len];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, "[aurpkgs]")) return true;
    }
    return false;
}

// ── makepkg.conf Parsing ─────────────────────────────────────────────────

/// Parse PKGDEST and PKGEXT from makepkg.conf files.
/// Reads /etc/makepkg.conf first, then ~/.makepkg.conf (user overrides).
/// Environment variables override config files.
fn parseMakepkgConf(allocator: Allocator) !MakepkgConfig {
    var config = MakepkgConfig{};

    // System config
    parseMakepkgConfFromFile(allocator, "/etc/makepkg.conf", &config) catch {};

    // User config (overrides system)
    if (std.posix.getenv("HOME")) |home| {
        const user_conf = try std.fs.path.join(allocator, &.{ home, ".makepkg.conf" });
        defer allocator.free(user_conf);
        parseMakepkgConfFromFile(allocator, user_conf, &config) catch {};
    }

    // Environment variables override everything
    if (std.posix.getenv("PKGDEST")) |v| {
        if (config.pkgdest) |old| allocator.free(old);
        config.pkgdest = try allocator.dupe(u8, v);
    }
    if (std.posix.getenv("PKGEXT")) |v| {
        if (config.owns_pkgext) allocator.free(config.pkgext);
        config.pkgext = try allocator.dupe(u8, v);
        config.owns_pkgext = true;
    }

    return config;
}

/// Parse a single makepkg.conf file for PKGDEST and PKGEXT.
pub fn parseMakepkgConfFromFile(allocator: Allocator, path: []const u8, config: *MakepkgConfig) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buf: [64 * 1024]u8 = undefined;
    const len = try file.readAll(&buf);
    const content = buf[0..len];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (parseAssignment(trimmed, "PKGDEST")) |val| {
            if (config.pkgdest) |old| allocator.free(old);
            config.pkgdest = try allocator.dupe(u8, stripQuotes(val));
        } else if (parseAssignment(trimmed, "PKGEXT")) |val| {
            if (config.owns_pkgext) allocator.free(config.pkgext);
            config.pkgext = try allocator.dupe(u8, stripQuotes(val));
            config.owns_pkgext = true;
        }
    }
}

// ── Internal Helpers ─────────────────────────────────────────────────────

/// Parse "KEY=value" and return value if key matches.
fn parseAssignment(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    if (line.len <= key.len or line[key.len] != '=') return null;
    return line[key.len + 1 ..];
}

/// Strip surrounding single or double quotes from a value.
fn stripQuotes(val: []const u8) []const u8 {
    if (val.len >= 2) {
        if ((val[0] == '"' and val[val.len - 1] == '"') or
            (val[0] == '\'' and val[val.len - 1] == '\''))
        {
            return val[1 .. val.len - 1];
        }
    }
    return val;
}

/// Strip the file extension (everything after the last dot).
fn stripExtension(filename: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, filename, '.')) |dot| {
        return filename[0..dot];
    }
    return filename;
}

fn dirExists(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    return stat.kind == .directory;
}

// ── Tests ────────────────────────────────────────────────────────────────

fn getTmpPath(tmp: std.testing.TmpDir) ![]u8 {
    return tmp.dir.realpathAlloc(std.testing.allocator, ".");
}

test "parsePackageFilename: simple name" {
    const result = parsePackageFilename("yay-12.3.5-1-x86_64.pkg.tar.zst").?;
    try std.testing.expectEqualStrings("yay", result.name);
    try std.testing.expectEqualStrings("12.3.5-1", result.version);
}

test "parsePackageFilename: hyphenated name" {
    const result = parsePackageFilename("lib32-mesa-24.0.1-1-x86_64.pkg.tar.zst").?;
    try std.testing.expectEqualStrings("lib32-mesa", result.name);
    try std.testing.expectEqualStrings("24.0.1-1", result.version);
}

test "parsePackageFilename: multi-hyphen name" {
    const result = parsePackageFilename("python-my-lib-0.1.0-1-any.pkg.tar.zst").?;
    try std.testing.expectEqualStrings("python-my-lib", result.name);
    try std.testing.expectEqualStrings("0.1.0-1", result.version);
}

test "parsePackageFilename: epoch version" {
    const result = parsePackageFilename("python-3:3.12.1-1-x86_64.pkg.tar.zst").?;
    try std.testing.expectEqualStrings("python", result.name);
    try std.testing.expectEqualStrings("3:3.12.1-1", result.version);
}

test "parsePackageFilename: xz compression" {
    const result = parsePackageFilename("xorg-x11-utils-7.5-1-x86_64.pkg.tar.xz").?;
    try std.testing.expectEqualStrings("xorg-x11-utils", result.name);
    try std.testing.expectEqualStrings("7.5-1", result.version);
}

test "parsePackageFilename: invalid input returns null" {
    try std.testing.expect(parsePackageFilename("not-a-package.txt") == null);
    try std.testing.expect(parsePackageFilename("") == null);
    try std.testing.expect(parsePackageFilename("a.pkg.tar.zst") == null); // too few hyphens
}

test "parseAssignment: matches key" {
    try std.testing.expectEqualStrings("/home/packages", parseAssignment("PKGDEST=/home/packages", "PKGDEST").?);
}

test "parseAssignment: rejects non-matching key" {
    try std.testing.expect(parseAssignment("BUILDDIR=/tmp", "PKGDEST") == null);
}

test "parseAssignment: rejects partial key match" {
    try std.testing.expect(parseAssignment("PKGDEST_EXTRA=foo", "PKGDEST") == null);
}

test "stripQuotes: double quotes" {
    try std.testing.expectEqualStrings("/home/packages", stripQuotes("\"/home/packages\""));
}

test "stripQuotes: single quotes" {
    try std.testing.expectEqualStrings(".pkg.tar.zst", stripQuotes("'.pkg.tar.zst'"));
}

test "stripQuotes: no quotes" {
    try std.testing.expectEqualStrings("/tmp/build", stripQuotes("/tmp/build"));
}

test "stripQuotes: mismatched quotes" {
    try std.testing.expectEqualStrings("\"foo'", stripQuotes("\"foo'"));
}

test "configInstructions contains required elements" {
    const instructions = Repository.configInstructions();
    try std.testing.expect(std.mem.indexOf(u8, instructions, "[aurpkgs]") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "SigLevel") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "Server = file://") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "PKGDEST=") != null);
}

test "isConfiguredFromPath detects aurpkgs section" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write a test pacman.conf
    try tmp.dir.writeFile(.{
        .sub_path = "pacman.conf",
        .data =
        \\[options]
        \\HoldPkg = pacman glibc
        \\
        \\[core]
        \\Include = /etc/pacman.d/mirrorlist
        \\
        \\[aurpkgs]
        \\SigLevel = Optional TrustAll
        \\Server = file:///home/user/.cache/aurodle/aurpkgs
        ,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "pacman.conf");
    defer std.testing.allocator.free(path);

    try std.testing.expect(isConfiguredFromPath(path));
}

test "isConfiguredFromPath returns false when missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "pacman.conf",
        .data =
        \\[options]
        \\[core]
        \\Include = /etc/pacman.d/mirrorlist
        ,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "pacman.conf");
    defer std.testing.allocator.free(path);

    try std.testing.expect(!isConfiguredFromPath(path));
}

test "isConfiguredFromPath returns false for nonexistent file" {
    try std.testing.expect(!isConfiguredFromPath("/tmp/nonexistent-aurodle-test-pacman.conf"));
}

test "ensureExists creates directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer std.testing.allocator.free(tmp_path);

    var repo = try Repository.initWithRoot(std.testing.allocator, tmp_path);
    defer repo.deinit();

    try repo.ensureExists();

    try std.testing.expect(dirExists(repo.repo_dir));
    try std.testing.expect(dirExists(repo.log_dir));
}

test "ensureExists is idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer std.testing.allocator.free(tmp_path);

    var repo = try Repository.initWithRoot(std.testing.allocator, tmp_path);
    defer repo.deinit();

    try repo.ensureExists();
    try repo.ensureExists(); // second call should not error
    try repo.ensureExists(); // third call should not error

    try std.testing.expect(dirExists(repo.repo_dir));
}

test "findBuiltPackages finds matching files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer std.testing.allocator.free(tmp_path);

    // Create fake package files
    try tmp.dir.writeFile(.{ .sub_path = "yay-12.3.5-1-x86_64.pkg.tar.zst", .data = "fake" });
    try tmp.dir.writeFile(.{ .sub_path = "paru-2.0.3-1-x86_64.pkg.tar.zst", .data = "fake" });
    try tmp.dir.writeFile(.{ .sub_path = "README.md", .data = "not a package" });

    var repo = try Repository.initWithRoot(std.testing.allocator, tmp_path);
    defer repo.deinit();

    const found = try repo.findBuiltPackages(tmp_path);
    defer {
        for (found) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(found);
    }

    try std.testing.expectEqual(@as(usize, 2), found.len);
}

test "findBuiltPackages returns empty for nonexistent directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer std.testing.allocator.free(tmp_path);

    var repo = try Repository.initWithRoot(std.testing.allocator, tmp_path);
    defer repo.deinit();

    const not_exist = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "nonexistent" });
    defer std.testing.allocator.free(not_exist);

    const found = try repo.findBuiltPackages(not_exist);
    defer std.testing.allocator.free(found);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "addBuiltPackages finds and registers split packages in repo dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer std.testing.allocator.free(tmp_path);

    var repo = try Repository.initWithRoot(std.testing.allocator, tmp_path);
    defer repo.deinit();
    repo.skip_repo_add = true;

    try repo.ensureExists();

    // Place packages directly in repo dir (as makepkg with PKGDEST would)
    const repo_dir = repo.repo_dir;
    const pkg_a = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "python-attrs-23.1-1-any.pkg.tar.zst" });
    defer std.testing.allocator.free(pkg_a);
    const pkg_b = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "python-attrs-tests-23.1-1-any.pkg.tar.zst" });
    defer std.testing.allocator.free(pkg_b);

    try std.fs.cwd().writeFile(.{ .sub_path = pkg_a, .data = "pkg-a" });
    try std.fs.cwd().writeFile(.{ .sub_path = pkg_b, .data = "pkg-b" });

    const added = try repo.addBuiltPackages();
    defer {
        for (added) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(added);
    }

    try std.testing.expectEqual(@as(usize, 2), added.len);
}

test "addBuiltPackages returns PackageNotFound for empty repo dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer std.testing.allocator.free(tmp_path);

    var repo = try Repository.initWithRoot(std.testing.allocator, tmp_path);
    defer repo.deinit();
    repo.skip_repo_add = true;

    try repo.ensureExists();

    try std.testing.expectError(error.PackageNotFound, repo.addBuiltPackages());
}

test "listPackages returns parsed packages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer std.testing.allocator.free(tmp_path);

    var repo = try Repository.initWithRoot(std.testing.allocator, tmp_path);
    defer repo.deinit();

    try repo.ensureExists();

    // Create package files in the repo directory
    var repo_dir = try std.fs.cwd().openDir(repo.repo_dir, .{});
    defer repo_dir.close();
    try repo_dir.writeFile(.{ .sub_path = "yay-12.3.5-1-x86_64.pkg.tar.zst", .data = "pkg" });
    try repo_dir.writeFile(.{ .sub_path = "paru-2.0.3-1-x86_64.pkg.tar.zst", .data = "pkg" });

    const pkgs = try repo.listPackages();
    defer {
        for (pkgs) |pkg| {
            std.testing.allocator.free(pkg.name);
            std.testing.allocator.free(pkg.version);
            std.testing.allocator.free(pkg.filename);
        }
        std.testing.allocator.free(pkgs);
    }

    try std.testing.expectEqual(@as(usize, 2), pkgs.len);
}

test "listPackages returns empty for empty repo" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer std.testing.allocator.free(tmp_path);

    var repo = try Repository.initWithRoot(std.testing.allocator, tmp_path);
    defer repo.deinit();

    try repo.ensureExists();

    const pkgs = try repo.listPackages();
    defer std.testing.allocator.free(pkgs);

    try std.testing.expectEqual(@as(usize, 0), pkgs.len);
}

test "listPackages skips database files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer std.testing.allocator.free(tmp_path);

    var repo = try Repository.initWithRoot(std.testing.allocator, tmp_path);
    defer repo.deinit();

    try repo.ensureExists();

    var repo_dir = try std.fs.cwd().openDir(repo.repo_dir, .{});
    defer repo_dir.close();
    try repo_dir.writeFile(.{ .sub_path = "aurpkgs.db.tar.xz", .data = "db" });
    try repo_dir.writeFile(.{ .sub_path = "aurpkgs.files.tar.xz", .data = "files" });
    try repo_dir.writeFile(.{ .sub_path = "yay-12.3.5-1-x86_64.pkg.tar.zst", .data = "pkg" });

    const pkgs = try repo.listPackages();
    defer {
        for (pkgs) |pkg| {
            std.testing.allocator.free(pkg.name);
            std.testing.allocator.free(pkg.version);
            std.testing.allocator.free(pkg.filename);
        }
        std.testing.allocator.free(pkgs);
    }

    try std.testing.expectEqual(@as(usize, 1), pkgs.len);
    try std.testing.expectEqualStrings("yay", pkgs[0].name);
}

test "clean identifies stale clones and logs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer std.testing.allocator.free(tmp_path);

    var repo = try Repository.initWithRoot(std.testing.allocator, tmp_path);
    defer repo.deinit();

    try repo.ensureExists();

    // Create clone directories
    const yay_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "yay" });
    defer std.testing.allocator.free(yay_path);
    try std.fs.cwd().makePath(yay_path);
    const paru_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "paru" });
    defer std.testing.allocator.free(paru_path);
    try std.fs.cwd().makePath(paru_path);

    // Create log files
    var log_dir = try std.fs.cwd().openDir(repo.log_dir, .{});
    defer log_dir.close();
    try log_dir.writeFile(.{ .sub_path = "yay.log", .data = "log" });
    try log_dir.writeFile(.{ .sub_path = "paru.log", .data = "log" });
    try log_dir.writeFile(.{ .sub_path = "orphan.log", .data = "log" });

    // Only "yay" is installed
    const result = try repo.clean(&.{"yay"});
    defer repo.freeCleanResult(result);

    // "paru" should be stale (not installed)
    try std.testing.expectEqual(@as(usize, 1), result.removed_clones.len);
    try std.testing.expectEqualStrings("paru", result.removed_clones[0]);

    // "paru.log" and "orphan.log" should be stale
    try std.testing.expectEqual(@as(usize, 2), result.removed_logs.len);
}

test "clean skips aurpkgs and logs directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer std.testing.allocator.free(tmp_path);

    var repo = try Repository.initWithRoot(std.testing.allocator, tmp_path);
    defer repo.deinit();

    try repo.ensureExists();

    const result = try repo.clean(&.{});
    defer repo.freeCleanResult(result);

    // aurpkgs and logs should not appear as stale clones
    for (result.removed_clones) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, REPO_NAME));
        try std.testing.expect(!std.mem.eql(u8, name, "logs"));
    }
}

test "parseMakepkgConfFromFile reads PKGDEST and PKGEXT" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "makepkg.conf",
        .data =
        \\# Test config
        \\PKGDEST="/home/user/packages"
        \\PKGEXT='.pkg.tar.zst'
        ,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "makepkg.conf");
    defer std.testing.allocator.free(path);

    var config = MakepkgConfig{};
    try parseMakepkgConfFromFile(std.testing.allocator, path, &config);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/home/user/packages", config.pkgdest.?);
    try std.testing.expectEqualStrings(".pkg.tar.zst", config.pkgext);
    try std.testing.expect(config.owns_pkgext);
}

test "parseMakepkgConfFromFile skips comments and empty lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "makepkg.conf",
        .data =
        \\# PKGEXT="/should/be/ignored"
        \\
        \\PKGEXT='.pkg.tar.xz'
        ,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "makepkg.conf");
    defer std.testing.allocator.free(path);

    var config = MakepkgConfig{};
    try parseMakepkgConfFromFile(std.testing.allocator, path, &config);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(".pkg.tar.xz", config.pkgext);
}

test "Repository paths are correct" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer std.testing.allocator.free(tmp_path);

    var repo = try Repository.initWithRoot(std.testing.allocator, tmp_path);
    defer repo.deinit();

    try std.testing.expect(std.mem.endsWith(u8, repo.repo_dir, "/aurpkgs"));
    try std.testing.expect(std.mem.endsWith(u8, repo.db_path, "/aurpkgs/aurpkgs.db.tar.xz"));
    try std.testing.expect(std.mem.endsWith(u8, repo.log_dir, "/logs"));
}

test "stripExtension works correctly" {
    try std.testing.expectEqualStrings("yay", stripExtension("yay.log"));
    try std.testing.expectEqualStrings("yay.build", stripExtension("yay.build.log"));
    try std.testing.expectEqualStrings("noext", stripExtension("noext"));
}
