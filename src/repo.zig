const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

// ── Constants ────────────────────────────────────────────────────────────

pub const DEFAULT_REPO_NAME = "aur";
pub const DEFAULT_PKGEXT = ".pkg.tar.zst";

// ── Types ────────────────────────────────────────────────────────────────

pub const RepoPackage = struct {
    name: []const u8,
    version: []const u8,
    filename: []const u8,
};

pub const CleanResult = struct {
    removed_clones: []const []const u8,
    removed_packages: []const []const u8,
    bytes_freed: u64,
};

pub const MakepkgConfig = struct {
    pkgdest: ?[]const u8 = null,
    pkgext: []const u8 = DEFAULT_PKGEXT,
    owns_pkgext: bool = false,
    pacman_auth: ?[]const u8 = null,

    fn deinit(self: MakepkgConfig, allocator: Allocator) void {
        if (self.pkgdest) |p| allocator.free(p);
        if (self.owns_pkgext) allocator.free(self.pkgext);
        if (self.pacman_auth) |a| allocator.free(a);
    }
};

// ── Repository ───────────────────────────────────────────────────────────

pub const Repository = struct {
    allocator: Allocator,
    repo_name: []const u8,
    repo_dir: []const u8,
    db_path: []const u8,
    cache_dir: []const u8,
    makepkg_conf: MakepkgConfig,
    skip_repo_add: bool,
    owns_repo_name: bool,

    /// Create a Repository using paths derived from makepkg.conf:
    /// - repo_dir: PKGDEST from makepkg.conf (required)
    /// - cache_dir: ~/.cache/aurodle (user-owned clones and logs)
    /// - repo_name: derived from pacman.conf by matching PKGDEST to a Server directive
    /// Parses makepkg.conf for PKGDEST and PKGEXT.
    pub fn init(allocator: Allocator) !Repository {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
        const cache_dir = try std.fs.path.join(allocator, &.{ home, ".cache/aurodle" });
        errdefer allocator.free(cache_dir);

        const conf = parseMakepkgConf(allocator) catch MakepkgConfig{};

        const repo_dir = try allocator.dupe(u8, conf.pkgdest orelse return error.PkgdestNotSet);
        errdefer allocator.free(repo_dir);

        // Derive the repo name from pacman.conf by finding which section
        // has a Server = file:// URL pointing to PKGDEST.
        const derived_name = try deriveRepoNameFromPacmanConf(allocator, repo_dir) orelse
            return error.RepoNotInPacmanConf;

        return initFromParts(allocator, cache_dir, repo_dir, conf, derived_name);
    }

    /// Create a Repository with an explicit cache root (for testing).
    /// Both repo_dir and cache_dir are under cache_root.
    /// Does NOT parse system makepkg.conf.
    pub fn initWithRoot(allocator: Allocator, cache_root: []const u8) !Repository {
        const cache_dir = try allocator.dupe(u8, cache_root);
        errdefer allocator.free(cache_dir);

        const repo_dir = try std.fs.path.join(allocator, &.{ cache_root, DEFAULT_REPO_NAME });

        return initFromParts(allocator, cache_dir, repo_dir, .{}, null);
    }

    fn initFromParts(allocator: Allocator, cache_dir: []const u8, repo_dir: []const u8, conf: MakepkgConfig, derived_name: ?[]const u8) !Repository {
        const repo_name = derived_name orelse DEFAULT_REPO_NAME;
        const owns_name = derived_name != null;

        const db_path = try std.fmt.allocPrint(allocator, "{s}/{s}.db.tar.xz", .{ repo_dir, repo_name });
        errdefer allocator.free(db_path);

        return .{
            .allocator = allocator,
            .repo_name = repo_name,
            .cache_dir = cache_dir,
            .repo_dir = repo_dir,
            .db_path = db_path,
            .makepkg_conf = conf,
            .skip_repo_add = false,
            .owns_repo_name = owns_name,
        };
    }

    pub fn deinit(self: *Repository) void {
        self.makepkg_conf.deinit(self.allocator);
        if (self.owns_repo_name) self.allocator.free(self.repo_name);
        self.allocator.free(self.db_path);
        self.allocator.free(self.repo_dir);
        self.allocator.free(self.cache_dir);
    }

    // ── Directory Management ─────────────────────────────────────────────

    /// Create repository and log directories if they don't exist.
    /// Idempotent — safe to call multiple times.
    pub fn ensureExists(self: *const Repository) !void {
        try std.fs.cwd().makePath(self.repo_dir);
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
            // Skip database files (e.g., reponame.db.tar.xz, reponame.files.tar.xz)
            if (self.isDbFile(entry.name)) continue;

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

    /// Check if the local AUR repository is configured in pacman.conf.
    pub fn isConfigured(self: *const Repository) !bool {
        return isConfiguredFromPathWithName("/etc/pacman.conf", self.repo_name);
    }

    /// Copy-pasteable pacman.conf configuration for the local AUR repository.
    pub fn configInstructions() []const u8 {
        return 
        \\Add the following to /etc/pacman.conf (name can be customized):
        \\
        \\[aurpkgs]
        \\SigLevel = Optional TrustAll
        \\Server = file:///var/lib/aurodle/aurpkgs
        \\
        \\Set PKGDEST in /etc/makepkg.conf to match the Server path:
        \\
        \\PKGDEST=/var/lib/aurodle/aurpkgs
        \\
        \\Then run:
        \\  sudo install -d -o $USER /var/lib/aurodle/aurpkgs
        \\  sudo pacman -Sy
        ;
    }

    // ── Clean ────────────────────────────────────────────────────────────

    /// Identify stale artifacts for removal given package names from the
    /// aurpkgs database that are no longer installed locally.
    /// Returns a plan — actual deletion is done by cleanExecute().
    pub fn clean(self: *const Repository, uninstalled_names: []const []const u8) !CleanResult {
        // Build set of uninstalled names for O(1) lookup
        var uninstalled: std.StringHashMapUnmanaged(void) = .empty;
        defer uninstalled.deinit(self.allocator);
        for (uninstalled_names) |name| {
            try uninstalled.put(self.allocator, name, {});
        }

        return self.collectCleanResult(&uninstalled);
    }

    /// Identify ALL artifacts for removal — every clone dir and package file.
    /// Returns a plan — actual deletion is done by cleanExecute().
    pub fn cleanAll(self: *const Repository) !CleanResult {
        return self.collectCleanResult(null);
    }

    /// Shared implementation for clean/cleanAll. When `filter` is non-null,
    /// only collects entries whose names are in the set; otherwise collects all.
    fn collectCleanResult(self: *const Repository, filter: ?*const std.StringHashMapUnmanaged(void)) !CleanResult {
        var clones: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (clones.items) |s| self.allocator.free(s);
            clones.deinit(self.allocator);
        }

        if (std.fs.cwd().openDir(self.cache_dir, .{ .iterate = true })) |dir_handle| {
            var cache = dir_handle;
            defer cache.close();

            var it = cache.iterate();
            while (try it.next()) |entry| {
                if (entry.kind != .directory) continue;
                if (std.mem.eql(u8, entry.name, self.repo_name)) continue;
                if (filter) |f| {
                    if (!f.contains(entry.name)) continue;
                }
                try clones.append(self.allocator, try self.allocator.dupe(u8, entry.name));
            }
        } else |_| {}

        var packages: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (packages.items) |s| self.allocator.free(s);
            packages.deinit(self.allocator);
        }

        if (std.fs.cwd().openDir(self.repo_dir, .{ .iterate = true })) |dir_handle| {
            var repo_dir = dir_handle;
            defer repo_dir.close();

            var it = repo_dir.iterate();
            while (try it.next()) |entry| {
                if (entry.kind != .file) continue;
                if (std.mem.indexOf(u8, entry.name, ".pkg.tar.") == null) continue;
                if (self.isDbFile(entry.name)) continue;
                if (filter) |f| {
                    const parsed = parsePackageFilename(entry.name) orelse continue;
                    if (!f.contains(parsed.name)) continue;
                }
                try packages.append(self.allocator, try self.allocator.dupe(u8, entry.name));
            }
        } else |_| {}

        return .{
            .removed_clones = try clones.toOwnedSlice(self.allocator),
            .removed_packages = try packages.toOwnedSlice(self.allocator),
            .bytes_freed = 0,
        };
    }

    /// Execute the actual deletion after user confirmation.
    pub fn cleanExecute(self: *const Repository, plan: CleanResult) void {
        // Remove stale clone directories
        for (plan.removed_clones) |name| {
            const path = std.fs.path.join(self.allocator, &.{ self.cache_dir, name }) catch continue;
            defer self.allocator.free(path);
            std.fs.cwd().deleteTree(path) catch {};
        }

        // Remove stale package files and their database entries
        if (plan.removed_packages.len > 0) {
            // Collect unique package names for repo-remove
            var pkg_names: std.StringHashMapUnmanaged(void) = .empty;
            defer pkg_names.deinit(self.allocator);

            for (plan.removed_packages) |filename| {
                // Delete the package file from disk
                const path = std.fs.path.join(self.allocator, &.{ self.repo_dir, filename }) catch continue;
                defer self.allocator.free(path);
                std.fs.cwd().deleteFile(path) catch {};

                // Collect the package name for repo-remove
                if (parsePackageFilename(filename)) |parsed| {
                    pkg_names.put(self.allocator, parsed.name, {}) catch {};
                }
            }

            // Run repo-remove for each unique package name
            self.runRepoRemove(pkg_names) catch {};
        }
    }

    /// Check if a filename is a database file (e.g., reponame.db.tar.xz, reponame.files.tar.xz).
    fn isDbFile(self: *const Repository, filename: []const u8) bool {
        if (filename.len <= self.repo_name.len) return false;
        if (!std.mem.startsWith(u8, filename, self.repo_name)) return false;
        return filename[self.repo_name.len] == '.';
    }

    /// Run `repo-remove <db_path> <pkg1> <pkg2> ...`
    fn runRepoRemove(self: *const Repository, names: std.StringHashMapUnmanaged(void)) !void {
        if (self.skip_repo_add) return;
        if (names.count() == 0) return;

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.ensureTotalCapacity(self.allocator, names.count() + 2);

        argv.appendAssumeCapacity("repo-remove");
        argv.appendAssumeCapacity(self.db_path);

        var it = names.keyIterator();
        while (it.next()) |key| {
            argv.appendAssumeCapacity(key.*);
        }

        const result = try utils.runCommand(self.allocator, argv.items);
        defer result.deinit(self.allocator);
        // Best-effort: don't fail the whole clean if repo-remove errors
    }

    /// Free a CleanResult's allocated slices.
    pub fn freeCleanResult(self: *const Repository, result: CleanResult) void {
        for (result.removed_clones) |s| self.allocator.free(s);
        self.allocator.free(result.removed_clones);
        for (result.removed_packages) |s| self.allocator.free(s);
        self.allocator.free(result.removed_packages);
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

/// Check if [repo_name] is configured in a pacman.conf file.
pub fn isConfiguredFromPath(path: []const u8) bool {
    return isConfiguredFromPathWithName(path, DEFAULT_REPO_NAME);
}

/// Check if [name] is configured in a pacman.conf file.
fn isConfiguredFromPathWithName(path: []const u8, name: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();

    // pacman.conf is small — read entire file
    var buf: [64 * 1024]u8 = undefined;
    const len = file.readAll(&buf) catch return false;
    const content = buf[0..len];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        // Match [name] section header
        if (trimmed.len < 3 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') continue;
        if (std.mem.eql(u8, trimmed[1 .. trimmed.len - 1], name)) return true;
    }
    return false;
}

/// Derive the local AUR repository name from pacman.conf by finding a section
/// whose `Server = file://` URL matches the given PKGDEST path.
///
/// For example, if PKGDEST is `/var/lib/aurodle/mypkgs` and pacman.conf contains:
///   [mypkgs]
///   Server = file:///var/lib/aurodle/mypkgs
///
/// This returns "mypkgs".
fn deriveRepoNameFromPacmanConf(allocator: Allocator, pkgdest: []const u8) !?[]const u8 {
    const file = std.fs.cwd().openFile("/etc/pacman.conf", .{}) catch return null;
    defer file.close();

    var buf: [64 * 1024]u8 = undefined;
    const len = file.readAll(&buf) catch return null;
    const content = buf[0..len];

    var current_section: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Section header: [reponame]
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            const name = trimmed[1 .. trimmed.len - 1];
            if (std.mem.eql(u8, name, "options")) {
                current_section = null;
            } else {
                current_section = name;
            }
            continue;
        }

        // Server directive with file:// protocol
        if (current_section != null and std.mem.startsWith(u8, trimmed, "Server")) {
            const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const url = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

            // Match "file:///path" against pkgdest
            if (std.mem.startsWith(u8, url, "file://")) {
                const server_path = url["file://".len..];
                if (std.mem.eql(u8, server_path, pkgdest)) {
                    return try allocator.dupe(u8, current_section.?);
                }
            }
        }
    }

    return null;
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
    if (std.posix.getenv("PACMAN_AUTH")) |v| {
        if (config.pacman_auth) |old| allocator.free(old);
        config.pacman_auth = try allocator.dupe(u8, v);
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
        } else if (parseAssignment(trimmed, "PACMAN_AUTH")) |val| {
            if (config.pacman_auth) |old| allocator.free(old);
            config.pacman_auth = try allocator.dupe(u8, stripBashArray(stripQuotes(val)));
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

/// Strip bash array syntax: "(content)" → "content".
/// Also strips quotes from the inner content.
/// Handles: (sudo), ("doas"), ('doas -s'), (sudo --askpass)
fn stripBashArray(val: []const u8) []const u8 {
    if (val.len >= 2 and val[0] == '(' and val[val.len - 1] == ')') {
        return stripQuotes(val[1 .. val.len - 1]);
    }
    return val;
}

const dirExists = utils.dirExists;

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
    try std.testing.expect(std.mem.indexOf(u8, instructions, "SigLevel") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "Server = file://") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "PKGDEST=") != null);
}

test "isConfiguredFromPath detects aur section" {
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
        \\[aur]
        \\SigLevel = Optional TrustAll
        \\Server = file:///home/user/.cache/aurodle/aur
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

test "isConfiguredFromPathWithName detects custom repo name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "pacman.conf",
        .data =
        \\[options]
        \\HoldPkg = pacman glibc
        \\
        \\[core]
        \\Include = /etc/pacman.d/mirrorlist
        \\
        \\[myaur]
        \\SigLevel = Optional TrustAll
        \\Server = file:///var/lib/aurodle/myaur
        ,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "pacman.conf");
    defer std.testing.allocator.free(path);

    try std.testing.expect(isConfiguredFromPathWithName(path, "myaur"));
    try std.testing.expect(!isConfiguredFromPathWithName(path, "aurpkgs"));
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
    try repo_dir.writeFile(.{ .sub_path = DEFAULT_REPO_NAME ++ ".db.tar.xz", .data = "db" });
    try repo_dir.writeFile(.{ .sub_path = DEFAULT_REPO_NAME ++ ".files.tar.xz", .data = "files" });
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

test "clean identifies stale clones" {
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

    // "paru" is uninstalled — should be cleaned
    const result = try repo.clean(&.{"paru"});
    defer repo.freeCleanResult(result);

    try std.testing.expectEqual(@as(usize, 1), result.removed_clones.len);
    try std.testing.expectEqualStrings("paru", result.removed_clones[0]);
}

test "clean skips repo directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer std.testing.allocator.free(tmp_path);

    var repo = try Repository.initWithRoot(std.testing.allocator, tmp_path);
    defer repo.deinit();

    try repo.ensureExists();

    // Even if the repo name were passed as uninstalled, the directory should be skipped
    const result = try repo.clean(&.{DEFAULT_REPO_NAME});
    defer repo.freeCleanResult(result);

    // repo dir should not appear as stale clones
    for (result.removed_clones) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, DEFAULT_REPO_NAME));
    }
}

test "clean identifies stale package files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer std.testing.allocator.free(tmp_path);

    var repo = try Repository.initWithRoot(std.testing.allocator, tmp_path);
    defer repo.deinit();
    repo.skip_repo_add = true;

    try repo.ensureExists();

    // Create package files in repo dir
    var repo_dir = try std.fs.cwd().openDir(repo.repo_dir, .{});
    defer repo_dir.close();
    try repo_dir.writeFile(.{ .sub_path = "yay-12.3.5-1-x86_64.pkg.tar.zst", .data = "pkg" });
    try repo_dir.writeFile(.{ .sub_path = "paru-2.0.3-1-x86_64.pkg.tar.zst", .data = "pkg" });

    // "paru" is uninstalled
    const result = try repo.clean(&.{"paru"});
    defer repo.freeCleanResult(result);

    try std.testing.expectEqual(@as(usize, 1), result.removed_packages.len);
    try std.testing.expectEqualStrings("paru-2.0.3-1-x86_64.pkg.tar.zst", result.removed_packages[0]);
    try std.testing.expectEqual(@as(usize, 0), result.removed_clones.len);
}

test "clean with no uninstalled packages finds nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer std.testing.allocator.free(tmp_path);

    var repo = try Repository.initWithRoot(std.testing.allocator, tmp_path);
    defer repo.deinit();

    try repo.ensureExists();

    // Create a clone dir and a package file
    const yay_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "yay" });
    defer std.testing.allocator.free(yay_path);
    try std.fs.cwd().makePath(yay_path);

    var repo_dir = try std.fs.cwd().openDir(repo.repo_dir, .{});
    defer repo_dir.close();
    try repo_dir.writeFile(.{ .sub_path = "yay-12.3.5-1-x86_64.pkg.tar.zst", .data = "pkg" });

    // Empty uninstalled list — everything is still installed
    const result = try repo.clean(&.{});
    defer repo.freeCleanResult(result);

    try std.testing.expectEqual(@as(usize, 0), result.removed_clones.len);
    try std.testing.expectEqual(@as(usize, 0), result.removed_packages.len);
}

test "cleanAll removes all clones and packages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer std.testing.allocator.free(tmp_path);

    var repo = try Repository.initWithRoot(std.testing.allocator, tmp_path);
    defer repo.deinit();

    try repo.ensureExists();

    // Create clone dirs
    const yay_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "yay" });
    defer std.testing.allocator.free(yay_path);
    try std.fs.cwd().makePath(yay_path);

    const paru_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "paru" });
    defer std.testing.allocator.free(paru_path);
    try std.fs.cwd().makePath(paru_path);

    // Create package files
    var repo_dir = try std.fs.cwd().openDir(repo.repo_dir, .{});
    defer repo_dir.close();
    try repo_dir.writeFile(.{ .sub_path = "yay-12.3.5-1-x86_64.pkg.tar.zst", .data = "pkg" });
    try repo_dir.writeFile(.{ .sub_path = "paru-2.0.3-1-x86_64.pkg.tar.zst", .data = "pkg" });

    const result = try repo.cleanAll();
    defer repo.freeCleanResult(result);

    try std.testing.expectEqual(@as(usize, 2), result.removed_clones.len);
    try std.testing.expectEqual(@as(usize, 2), result.removed_packages.len);
}

test "cleanAll with empty repo finds nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer std.testing.allocator.free(tmp_path);

    var repo = try Repository.initWithRoot(std.testing.allocator, tmp_path);
    defer repo.deinit();

    try repo.ensureExists();

    const result = try repo.cleanAll();
    defer repo.freeCleanResult(result);

    try std.testing.expectEqual(@as(usize, 0), result.removed_clones.len);
    try std.testing.expectEqual(@as(usize, 0), result.removed_packages.len);
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

test "parseMakepkgConfFromFile reads PACMAN_AUTH with array syntax" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "makepkg.conf",
        .data =
        \\PACMAN_AUTH=(sudo)
        ,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "makepkg.conf");
    defer std.testing.allocator.free(path);

    var config = MakepkgConfig{};
    try parseMakepkgConfFromFile(std.testing.allocator, path, &config);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("sudo", config.pacman_auth.?);
}

test "parseMakepkgConfFromFile reads PACMAN_AUTH with quoted array" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "makepkg.conf",
        .data =
        \\PACMAN_AUTH=("doas")
        ,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "makepkg.conf");
    defer std.testing.allocator.free(path);

    var config = MakepkgConfig{};
    try parseMakepkgConfFromFile(std.testing.allocator, path, &config);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("doas", config.pacman_auth.?);
}

test "parseMakepkgConfFromFile reads PACMAN_AUTH with args" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "makepkg.conf",
        .data =
        \\PACMAN_AUTH=(sudo --askpass)
        ,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "makepkg.conf");
    defer std.testing.allocator.free(path);

    var config = MakepkgConfig{};
    try parseMakepkgConfFromFile(std.testing.allocator, path, &config);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("sudo --askpass", config.pacman_auth.?);
}

test "parseMakepkgConfFromFile reads PACMAN_AUTH plain value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "makepkg.conf",
        .data =
        \\PACMAN_AUTH="doas"
        ,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "makepkg.conf");
    defer std.testing.allocator.free(path);

    var config = MakepkgConfig{};
    try parseMakepkgConfFromFile(std.testing.allocator, path, &config);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("doas", config.pacman_auth.?);
}

test "parseMakepkgConfFromFile PACMAN_AUTH last value wins" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "makepkg.conf",
        .data =
        \\PACMAN_AUTH=(sudo)
        \\PACMAN_AUTH=(doas)
        ,
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "makepkg.conf");
    defer std.testing.allocator.free(path);

    var config = MakepkgConfig{};
    try parseMakepkgConfFromFile(std.testing.allocator, path, &config);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("doas", config.pacman_auth.?);
}

test "stripBashArray strips parens" {
    try std.testing.expectEqualStrings("sudo", stripBashArray("(sudo)"));
    try std.testing.expectEqualStrings("doas -s", stripBashArray("(doas -s)"));
    try std.testing.expectEqualStrings("sudo", stripBashArray("sudo"));
    try std.testing.expectEqualStrings("doas", stripBashArray("(\"doas\")"));
    try std.testing.expectEqualStrings("doas", stripBashArray("('doas')"));
}

test "Repository paths are correct" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer std.testing.allocator.free(tmp_path);

    var repo = try Repository.initWithRoot(std.testing.allocator, tmp_path);
    defer repo.deinit();

    try std.testing.expect(std.mem.endsWith(u8, repo.repo_dir, "/" ++ DEFAULT_REPO_NAME));
    try std.testing.expect(std.mem.endsWith(u8, repo.db_path, "/" ++ DEFAULT_REPO_NAME ++ "/" ++ DEFAULT_REPO_NAME ++ ".db.tar.xz"));
}
