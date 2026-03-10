const std = @import("std");
const Allocator = std.mem.Allocator;
const alpm = @import("alpm.zig");
const repo_mod = @import("repo.zig");

// ── Public Types ─────────────────────────────────────────────────────────

/// Version constraint operator.
pub const CmpOp = enum {
    eq,
    ge,
    le,
    gt,
    lt,
};

/// A version constraint: operator + version string.
pub const VersionConstraint = struct {
    op: CmpOp,
    version: []const u8,
};

/// Result of a provider search.
pub const ProviderMatch = struct {
    provider_name: []const u8,
    provider_version: []const u8,
    db_name: []const u8,
};

/// A locally installed package's identity.
pub const InstalledPackage = struct {
    name: []const u8,
    version: []const u8,
};

/// Which set of sync databases to search.
pub const DbSet = enum {
    all_sync,
    official_only,
    aurpkgs_only,
};

// ── Pacman Struct ────────────────────────────────────────────────────────

/// High-level domain queries against the local pacman database.
///
/// Wraps alpm.Handle and answers questions like "is this installed?",
/// "which repo provides this?", "does version X satisfy constraint Y?"
///
/// All returned string slices are borrowed from libalpm internal memory
/// and are valid until Pacman.deinit().
pub const Pacman = struct {
    allocator: Allocator,
    handle: alpm.Handle,
    local_db: alpm.Database,
    sync_dbs: []alpm.Database,
    aurpkgs_db: ?alpm.Database,
    aur_repo_name: []const u8,
    owns_sync_dbs: bool,
    verbose_pkg_lists: bool = false,

    /// Initialize by parsing /etc/pacman.conf and registering all
    /// discovered sync databases.
    /// `aur_repo_name` identifies the local AUR repository section in pacman.conf.
    pub fn init(allocator: Allocator, aur_repo_name: []const u8) !Pacman {
        var handle = try alpm.Handle.init("/", "/var/lib/pacman/");
        errdefer handle.deinit();

        const conf = try registerSyncDbs(allocator, handle);
        errdefer allocator.free(conf.sync_dbs);

        var aurpkgs_db: ?alpm.Database = null;
        for (conf.sync_dbs) |db| {
            if (std.mem.eql(u8, db.getName(), aur_repo_name)) {
                aurpkgs_db = db;
                break;
            }
        }

        return .{
            .allocator = allocator,
            .handle = handle,
            .local_db = handle.getLocalDb(),
            .sync_dbs = conf.sync_dbs,
            .aurpkgs_db = aurpkgs_db,
            .aur_repo_name = aur_repo_name,
            .owns_sync_dbs = true,
            .verbose_pkg_lists = conf.verbose_pkg_lists,
        };
    }

    /// Initialize with a pre-configured handle (for testing or custom setup).
    /// The caller retains ownership of sync_dbs.
    pub fn initWithHandle(
        allocator: Allocator,
        handle: alpm.Handle,
        sync_dbs: []alpm.Database,
    ) Pacman {
        return initWithHandleAndName(allocator, handle, sync_dbs, repo_mod.DEFAULT_REPO_NAME);
    }

    /// Initialize with a pre-configured handle and custom AUR repo name.
    pub fn initWithHandleAndName(
        allocator: Allocator,
        handle: alpm.Handle,
        sync_dbs: []alpm.Database,
        aur_repo_name: []const u8,
    ) Pacman {
        var aurpkgs_db: ?alpm.Database = null;
        for (sync_dbs) |db| {
            if (std.mem.eql(u8, db.getName(), aur_repo_name)) {
                aurpkgs_db = db;
                break;
            }
        }

        return .{
            .allocator = allocator,
            .handle = handle,
            .local_db = handle.getLocalDb(),
            .sync_dbs = sync_dbs,
            .aurpkgs_db = aurpkgs_db,
            .aur_repo_name = aur_repo_name,
            .owns_sync_dbs = false,
        };
    }

    pub fn deinit(self: *Pacman) void {
        if (self.owns_sync_dbs) self.allocator.free(self.sync_dbs);
        self.handle.deinit();
    }

    /// Is this the name of the local AUR repository?
    pub fn isAurRepo(self: Pacman, db_name: []const u8) bool {
        return std.mem.eql(u8, db_name, self.aur_repo_name);
    }

    // ── Package Queries ──────────────────────────────────────────────────

    /// Is this package installed on the system?
    pub fn isInstalled(self: Pacman, name: []const u8) bool {
        return self.local_db.getPackage(name) != null;
    }

    /// What version of this package is installed? Null if not installed.
    pub fn installedVersion(self: Pacman, name: []const u8) ?[]const u8 {
        const pkg = self.local_db.getPackage(name) orelse return null;
        return pkg.getVersion();
    }

    /// Is this package available in any sync database (including aurpkgs)?
    pub fn isInSyncDb(self: Pacman, name: []const u8) bool {
        for (self.sync_dbs) |db| {
            if (db.getPackage(name) != null) return true;
        }
        return false;
    }

    /// Is this package available in an official sync database (excludes aurpkgs)?
    pub fn isInOfficialSyncDb(self: Pacman, name: []const u8) bool {
        for (self.sync_dbs) |db| {
            if (std.mem.eql(u8, db.getName(), self.aur_repo_name)) continue;
            if (db.getPackage(name) != null) return true;
        }
        return false;
    }

    /// Which sync database provides this package? Returns db name or null.
    pub fn syncDbFor(self: Pacman, name: []const u8) ?[]const u8 {
        for (self.sync_dbs) |db| {
            if (db.getPackage(name) != null) return db.getName();
        }
        return null;
    }

    /// What version is available in sync databases? Returns first match.
    pub fn syncVersion(self: Pacman, name: []const u8) ?[]const u8 {
        for (self.sync_dbs) |db| {
            if (db.getPackage(name)) |pkg| return pkg.getVersion();
        }
        return null;
    }

    /// Size information for a set of repo dependency packages.
    pub const SizeInfo = struct {
        download: i64 = 0,
        install: i64 = 0,
        net_upgrade: i64 = 0,
        has_upgrades: bool = false,
    };

    /// Compute aggregate download/install/upgrade sizes for repo deps.
    pub fn repoDepSizes(self: Pacman, names: []const []const u8) SizeInfo {
        var info = SizeInfo{};
        for (names) |name| {
            for (self.sync_dbs) |db| {
                if (db.getPackage(name)) |sync_pkg| {
                    info.download += sync_pkg.getSize();
                    info.install += sync_pkg.getIsize();
                    if (self.local_db.getPackage(name)) |local_pkg| {
                        if (alpm.vercmp(sync_pkg.getVersion(), local_pkg.getVersion()) != 0) {
                            info.net_upgrade += sync_pkg.getIsize() - local_pkg.getIsize();
                            info.has_upgrades = true;
                        }
                    }
                    break;
                }
            }
        }
        return info;
    }

    /// What version is available in official sync databases (excludes aurpkgs)?
    pub fn officialSyncVersion(self: Pacman, name: []const u8) ?[]const u8 {
        for (self.sync_dbs) |db| {
            if (std.mem.eql(u8, db.getName(), self.aur_repo_name)) continue;
            if (db.getPackage(name)) |pkg| return pkg.getVersion();
        }
        return null;
    }

    // ── Version Satisfaction ─────────────────────────────────────────────

    /// Does the installed version of `name` satisfy `constraint`?
    /// Returns false if the package is not installed.
    pub fn satisfies(self: Pacman, name: []const u8, constraint: VersionConstraint) bool {
        const installed = self.installedVersion(name) orelse return false;
        return checkVersion(installed, constraint);
    }

    /// Does any installed package satisfy this dependency string?
    /// Handles both direct name matches and versioned constraints.
    /// Uses libalpm's native satisfier which checks provides too.
    pub fn satisfiesDep(self: Pacman, depstring: []const u8) bool {
        const local_pkgs = self.local_db.getPkgcache();
        return alpm.findSatisfier(local_pkgs, depstring) != null;
    }

    // ── Provider Resolution ──────────────────────────────────────────────

    /// Find a package that provides the given dependency.
    /// Checks official repos first (priority), then aurpkgs.
    /// Returns null if no provider found.
    pub fn findProvider(self: Pacman, dep: []const u8) ?ProviderMatch {
        // Check official repos first (skip aurpkgs)
        for (self.sync_dbs) |db| {
            if (std.mem.eql(u8, db.getName(), self.aur_repo_name)) continue;

            if (findProviderInDb(db, dep)) |match| return match;
        }

        // Then check aurpkgs
        if (self.aurpkgs_db) |aurdb| {
            if (findProviderInDb(aurdb, dep)) |match| return match;
        }

        return null;
    }

    /// Find a package satisfying a dependency string in the given database set.
    pub fn findDbsSatisfier(self: Pacman, db_set: DbSet, depstring: []const u8) ?[]const u8 {
        const dbs = switch (db_set) {
            .all_sync => self.sync_dbs,
            .official_only => blk: {
                // Filter out aurpkgs — iterate sync_dbs checking names
                for (self.sync_dbs) |db| {
                    if (std.mem.eql(u8, db.getName(), self.aur_repo_name)) continue;
                    const pkgcache = db.getPkgcache();
                    if (alpm.findSatisfier(pkgcache, depstring)) |pkg| {
                        return pkg.getName();
                    }
                }
                break :blk &.{};
            },
            .aurpkgs_only => blk: {
                if (self.aurpkgs_db) |aurdb| {
                    const pkgcache = aurdb.getPkgcache();
                    if (alpm.findSatisfier(pkgcache, depstring)) |pkg| {
                        return pkg.getName();
                    }
                }
                break :blk &.{};
            },
        };

        // all_sync path
        for (dbs) |db| {
            const pkgcache = db.getPkgcache();
            if (alpm.findSatisfier(pkgcache, depstring)) |pkg| {
                return pkg.getName();
            }
        }
        return null;
    }

    // ── Database Refresh ─────────────────────────────────────────────────

    /// Refresh only the aurpkgs database.
    /// Safe because aurpkgs is our local repo — refreshing it
    /// cannot cause a partial system update.
    pub fn refreshAurDb(self: Pacman) !void {
        const db = self.aurpkgs_db orelse return error.AurDbNotConfigured;
        try self.handle.dbUpdate(&.{db}, false);
    }

    // ── Aurpkgs Database Queries ────────────────────────────────────────

    /// List all package names in the aurpkgs database that are NOT installed locally.
    /// These are stale entries — built at some point but since removed.
    pub fn uninstalledAurpkgs(self: Pacman) ![]const []const u8 {
        const aurdb = self.aurpkgs_db orelse return error.AurDbNotConfigured;

        var names: std.ArrayList([]const u8) = .empty;
        errdefer names.deinit(self.allocator);

        var it = aurdb.getPkgcache();
        while (it.next()) |pkg| {
            const name = pkg.getName();
            if (!self.isInstalled(name)) {
                try names.append(self.allocator, name);
            }
        }

        return try names.toOwnedSlice(self.allocator);
    }

    // ── Foreign Package Detection ────────────────────────────────────────

    /// List all installed packages that aren't in any official sync database.
    /// These are "foreign" packages — typically AUR packages.
    pub fn allForeignPackages(self: Pacman) ![]InstalledPackage {
        var foreign: std.ArrayList(InstalledPackage) = .empty;
        errdefer foreign.deinit(self.allocator);

        var it = self.local_db.getPkgcache();
        while (it.next()) |pkg| {
            const name = pkg.getName();
            const in_official = blk: {
                for (self.sync_dbs) |db| {
                    if (std.mem.eql(u8, db.getName(), self.aur_repo_name)) continue;
                    if (db.getPackage(name) != null) break :blk true;
                }
                break :blk false;
            };

            if (!in_official) {
                try foreign.append(self.allocator, .{
                    .name = name,
                    .version = pkg.getVersion(),
                });
            }
        }

        return try foreign.toOwnedSlice(self.allocator);
    }
};

// ── Internal Helpers ─────────────────────────────────────────────────────

/// Check if `version` satisfies `constraint` using libalpm's vercmp.
pub fn checkVersion(version: []const u8, constraint: VersionConstraint) bool {
    const cmp = alpm.vercmp(version, constraint.version);
    return switch (constraint.op) {
        .eq => cmp == 0,
        .ge => cmp >= 0,
        .le => cmp <= 0,
        .gt => cmp > 0,
        .lt => cmp < 0,
    };
}

/// Search a single database for a package that provides `dep`.
fn findProviderInDb(db: alpm.Database, dep: []const u8) ?ProviderMatch {
    var it = db.getPkgcache();
    while (it.next()) |pkg| {
        // Check direct name match
        if (std.mem.eql(u8, pkg.getName(), dep)) {
            return .{
                .provider_name = pkg.getName(),
                .provider_version = pkg.getVersion(),
                .db_name = db.getName(),
            };
        }

        // Check provides list
        var dep_it = pkg.getProvides();
        while (dep_it.next()) |prov| {
            if (std.mem.eql(u8, prov.name, dep)) {
                return .{
                    .provider_name = pkg.getName(),
                    .provider_version = pkg.getVersion(),
                    .db_name = db.getName(),
                };
            }
        }
    }
    return null;
}

const PacmanConf = struct {
    sync_dbs: []alpm.Database,
    verbose_pkg_lists: bool,
};

/// Parse /etc/pacman.conf and register each [repo] section as a sync database.
/// Handles Include directives for mirror server lists.
fn registerSyncDbs(allocator: Allocator, handle: alpm.Handle) !PacmanConf {
    var dbs: std.ArrayList(alpm.Database) = .empty;
    defer dbs.deinit(allocator);

    const conf = std.fs.openFileAbsolute("/etc/pacman.conf", .{}) catch
        return error.PacmanConfNotFound;
    defer conf.close();

    // pacman.conf is small — read entire file
    var buf: [64 * 1024]u8 = undefined;
    const len = conf.readAll(&buf) catch return error.PacmanConfNotFound;
    const content = buf[0..len];

    var current_repo: ?alpm.Database = null;
    var in_options = false;
    var verbose_pkg_lists = false;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip comments and empty lines
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Section header: [reponame]
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            const name = trimmed[1 .. trimmed.len - 1];
            if (std.mem.eql(u8, name, "options")) {
                current_repo = null;
                in_options = true;
                continue;
            }
            in_options = false;

            const db = handle.registerSyncDb(name, .use_default) catch {
                current_repo = null;
                continue;
            };
            try dbs.append(allocator, db);
            current_repo = db;
            continue;
        }

        // Options section directives
        if (in_options and std.mem.eql(u8, trimmed, "VerbosePkgLists")) {
            verbose_pkg_lists = true;
        }

        // Include directive: add servers from mirrorlist file
        if (current_repo != null and std.mem.startsWith(u8, trimmed, "Include")) {
            const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const path = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
            addServersFromMirrorlist(current_repo.?, path);
        }

        // Direct Server directive
        if (current_repo != null and std.mem.startsWith(u8, trimmed, "Server")) {
            const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const url = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
            current_repo.?.addServer(url) catch {};
        }
    }

    return .{
        .sync_dbs = try dbs.toOwnedSlice(allocator),
        .verbose_pkg_lists = verbose_pkg_lists,
    };
}

/// Read a mirrorlist file and add each Server= URL to the database.
fn addServersFromMirrorlist(db: alpm.Database, path: []const u8) void {
    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    var buf: [256 * 1024]u8 = undefined;
    const len = file.readAll(&buf) catch return;
    const content = buf[0..len];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.startsWith(u8, trimmed, "Server")) {
            const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const url = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
            db.addServer(url) catch {};
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────────

fn isArchLinux() bool {
    std.fs.accessAbsolute("/var/lib/pacman/local", .{}) catch return false;
    return true;
}

// ── Pure Logic Tests (no system dependencies) ────────────────────────────

test "checkVersion: eq operator" {
    try std.testing.expect(checkVersion("1.0.0", .{ .op = .eq, .version = "1.0.0" }));
    try std.testing.expect(!checkVersion("1.0.0", .{ .op = .eq, .version = "2.0.0" }));
}

test "checkVersion: ge operator" {
    try std.testing.expect(checkVersion("2.0.0", .{ .op = .ge, .version = "1.0.0" }));
    try std.testing.expect(checkVersion("1.0.0", .{ .op = .ge, .version = "1.0.0" }));
    try std.testing.expect(!checkVersion("0.9.0", .{ .op = .ge, .version = "1.0.0" }));
}

test "checkVersion: le operator" {
    try std.testing.expect(checkVersion("1.0.0", .{ .op = .le, .version = "2.0.0" }));
    try std.testing.expect(checkVersion("1.0.0", .{ .op = .le, .version = "1.0.0" }));
    try std.testing.expect(!checkVersion("2.0.0", .{ .op = .le, .version = "1.0.0" }));
}

test "checkVersion: gt operator" {
    try std.testing.expect(checkVersion("2.0.0", .{ .op = .gt, .version = "1.0.0" }));
    try std.testing.expect(!checkVersion("1.0.0", .{ .op = .gt, .version = "1.0.0" }));
}

test "checkVersion: lt operator" {
    try std.testing.expect(checkVersion("1.0.0", .{ .op = .lt, .version = "2.0.0" }));
    try std.testing.expect(!checkVersion("1.0.0", .{ .op = .lt, .version = "1.0.0" }));
}

test "checkVersion: with epochs and pkgrel" {
    try std.testing.expect(checkVersion("1:1.0", .{ .op = .gt, .version = "2.0" }));
    try std.testing.expect(checkVersion("1.0-2", .{ .op = .gt, .version = "1.0-1" }));
    try std.testing.expect(!checkVersion("1.0-1", .{ .op = .ge, .version = "2.0-1" }));
}

// ── Integration Tests (require real pacman database) ─────────────────────

test "Pacman.init and deinit on Arch system" {
    if (!isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(std.testing.allocator, repo_mod.DEFAULT_REPO_NAME);
    defer pm.deinit();

    // Should have at least one sync db (core/extra)
    try std.testing.expect(pm.sync_dbs.len > 0);
}

test "isInstalled returns true for pacman itself" {
    if (!isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(std.testing.allocator, repo_mod.DEFAULT_REPO_NAME);
    defer pm.deinit();

    try std.testing.expect(pm.isInstalled("pacman"));
    try std.testing.expect(!pm.isInstalled("zzz-not-installed-pkg-12345"));
}

test "installedVersion returns version for installed package" {
    if (!isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(std.testing.allocator, repo_mod.DEFAULT_REPO_NAME);
    defer pm.deinit();

    const version = pm.installedVersion("pacman");
    try std.testing.expect(version != null);
    try std.testing.expect(version.?.len > 0);

    try std.testing.expect(pm.installedVersion("zzz-not-installed") == null);
}

test "isInSyncDb finds official packages" {
    if (!isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(std.testing.allocator, repo_mod.DEFAULT_REPO_NAME);
    defer pm.deinit();

    // glibc is always in an official sync db
    try std.testing.expect(pm.isInSyncDb("glibc"));
    try std.testing.expect(!pm.isInSyncDb("zzz-definitely-not-in-repos"));
}

test "syncDbFor returns correct repository name" {
    if (!isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(std.testing.allocator, repo_mod.DEFAULT_REPO_NAME);
    defer pm.deinit();

    // glibc is in core
    const repo = pm.syncDbFor("glibc");
    try std.testing.expect(repo != null);
    // Don't assert exact repo name — it varies between core/extra

    try std.testing.expect(pm.syncDbFor("zzz-not-real") == null);
}

test "satisfies checks installed version against constraint" {
    if (!isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(std.testing.allocator, repo_mod.DEFAULT_REPO_NAME);
    defer pm.deinit();

    // pacman is definitely installed with version >= 1.0
    try std.testing.expect(pm.satisfies("pacman", .{ .op = .ge, .version = "1.0" }));
    // But probably not version 99.0
    try std.testing.expect(!pm.satisfies("pacman", .{ .op = .ge, .version = "99.0" }));
    // Not-installed package can't satisfy anything
    try std.testing.expect(!pm.satisfies("zzz-not-installed", .{ .op = .eq, .version = "1.0" }));
}

test "satisfiesDep checks dependency string against installed packages" {
    if (!isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(std.testing.allocator, repo_mod.DEFAULT_REPO_NAME);
    defer pm.deinit();

    try std.testing.expect(pm.satisfiesDep("glibc"));
    try std.testing.expect(!pm.satisfiesDep("zzz-not-real-dep-12345"));
}

test "findProvider finds package providing dependency" {
    if (!isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(std.testing.allocator, repo_mod.DEFAULT_REPO_NAME);
    defer pm.deinit();

    // glibc is a direct package name — should be found
    const result = pm.findProvider("glibc");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("glibc", result.?.provider_name);

    // Nonexistent provider
    try std.testing.expect(pm.findProvider("zzz-nonexistent-virtual-dep") == null);
}

test "allForeignPackages returns packages not in official repos" {
    if (!isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(std.testing.allocator, repo_mod.DEFAULT_REPO_NAME);
    defer pm.deinit();

    const foreign = try pm.allForeignPackages();
    defer std.testing.allocator.free(foreign);

    // Verify: no foreign package should be in an official sync db
    for (foreign) |pkg| {
        try std.testing.expect(pkg.name.len > 0);
        try std.testing.expect(pkg.version.len > 0);

        // Check it's truly not in official repos
        const in_official = blk: {
            for (pm.sync_dbs) |db| {
                if (std.mem.eql(u8, db.getName(), pm.aur_repo_name)) continue;
                if (db.getPackage(pkg.name) != null) break :blk true;
            }
            break :blk false;
        };
        try std.testing.expect(!in_official);
    }
}

test "repoDepSizes returns nonzero sizes for real packages" {
    if (!isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(std.testing.allocator, repo_mod.DEFAULT_REPO_NAME);
    defer pm.deinit();

    // glibc is always in sync dbs and installed
    const names = &[_][]const u8{"glibc"};
    const sizes = pm.repoDepSizes(names);
    try std.testing.expect(sizes.download > 0);
    try std.testing.expect(sizes.install > 0);
    // has_upgrades is only true when versions differ (not for same-version reinstalls)
}

test "repoDepSizes returns zeros for unknown packages" {
    if (!isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(std.testing.allocator, repo_mod.DEFAULT_REPO_NAME);
    defer pm.deinit();

    const names = &[_][]const u8{"zzz-nonexistent-pkg-99999"};
    const sizes = pm.repoDepSizes(names);
    try std.testing.expectEqual(@as(i64, 0), sizes.download);
    try std.testing.expectEqual(@as(i64, 0), sizes.install);
    try std.testing.expect(!sizes.has_upgrades);
}

test "refreshAurDb errors when aurpkgs not configured" {
    if (!isArchLinux()) return error.SkipZigTest;

    // Create a handle without aurpkgs
    const handle = try alpm.Handle.init("/", "/var/lib/pacman/");
    // Register only core, not aurpkgs
    const core_db = try handle.registerSyncDb("core", .use_default);
    var dbs = [_]alpm.Database{core_db};

    var pm = Pacman.initWithHandle(std.testing.allocator, handle, &dbs);
    defer pm.deinit();

    try std.testing.expect(pm.aurpkgs_db == null);
    try std.testing.expectError(error.AurDbNotConfigured, pm.refreshAurDb());
}
