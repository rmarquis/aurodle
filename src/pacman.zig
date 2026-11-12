const std = @import("std");
const Allocator = std.mem.Allocator;
const alpm = @import("alpm.zig");
const repo_conf = @import("repo_conf.zig");
const version = @import("version.zig");
const dep_spec = @import("dep_spec.zig");
const pacman_conf = @import("pacman_conf.zig");

pub const CmpOp = version.CmpOp;
pub const VersionConstraint = version.VersionConstraint;
pub const checkVersion = version.checkVersion;

// ── Public Types ─────────────────────────────────────────────────────────

/// A package providing a dependency, as found by a provider search.
pub const ProviderCandidate = @import("provider.zig").ProviderCandidate;

/// A locally installed package's identity.
pub const InstalledPackage = struct {
    name: []const u8,
    version: []const u8,
};

/// A virtual dep (e.g. "jack") with multiple uninstalled providers in official repos.
/// Returned by findTransitiveProviderChoices for interactive selection.
pub const SyncProviderChoice = struct {
    dep_name: []const u8, // virtual dep name, borrowed from alpm memory
    candidates: []ProviderCandidate, // all uninstalled providers; caller owns slice
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
    /// Subset of sync_dbs excluding the local AUR repo.  Precomputed so that
    /// "official repos only" lookups don't repeatedly re-filter by name.
    /// Always owned by this struct (freed in deinit).
    official_dbs: []alpm.Database,
    aurpkgs_db: ?alpm.Database,
    aur_repo_name: []const u8,
    owns_sync_dbs: bool,
    verbose_pkg_lists: bool = false,
    color: bool = false,
    ignore_pkgs: []const []const u8 = &.{},
    /// pacman.conf CacheDir values (owned); see cacheDirs().
    cache_dirs: []const []const u8 = &.{},
    /// Name/provision → provider lookup table, built on first use. Null
    /// only if allocating it failed; lookups then scan the databases.
    provides_index: ?*ProvidesIndex = null,

    /// Initialize by parsing /etc/pacman.conf and registering all
    /// discovered sync databases.
    /// `aur_repo_name` identifies the local AUR repository section in pacman.conf.
    pub fn init(allocator: Allocator, aur_repo_name: []const u8) !Pacman {
        var handle = try alpm.Handle.init("/", "/var/lib/pacman/");
        errdefer handle.deinit();

        const conf = try pacman_conf.registerSyncDbs(allocator, handle);
        errdefer allocator.free(conf.sync_dbs);

        const official_dbs = try buildOfficialDbs(allocator, conf.sync_dbs, aur_repo_name);
        errdefer allocator.free(official_dbs);

        const index = try ProvidesIndex.create(allocator);
        errdefer index.destroy();

        return .{
            .allocator = allocator,
            .handle = handle,
            .local_db = handle.getLocalDb(),
            .sync_dbs = conf.sync_dbs,
            .official_dbs = official_dbs,
            .aurpkgs_db = findAurpkgsDb(conf.sync_dbs, aur_repo_name),
            .aur_repo_name = aur_repo_name,
            .owns_sync_dbs = true,
            .verbose_pkg_lists = conf.verbose_pkg_lists,
            .color = conf.color,
            .ignore_pkgs = conf.ignore_pkgs,
            .cache_dirs = conf.cache_dirs,
            .provides_index = index,
        };
    }

    /// Initialize with a pre-configured handle (for testing or custom setup).
    /// The caller retains ownership of sync_dbs.
    pub fn initWithHandle(
        allocator: Allocator,
        handle: alpm.Handle,
        sync_dbs: []alpm.Database,
    ) !Pacman {
        return initWithHandleAndName(allocator, handle, sync_dbs, repo_conf.DEFAULT_REPO_NAME);
    }

    /// Initialize with a pre-configured handle and custom AUR repo name.
    pub fn initWithHandleAndName(
        allocator: Allocator,
        handle: alpm.Handle,
        sync_dbs: []alpm.Database,
        aur_repo_name: []const u8,
    ) !Pacman {
        const official_dbs = try buildOfficialDbs(allocator, sync_dbs, aur_repo_name);
        errdefer allocator.free(official_dbs);

        const index = try ProvidesIndex.create(allocator);
        errdefer index.destroy();

        return .{
            .allocator = allocator,
            .handle = handle,
            .local_db = handle.getLocalDb(),
            .sync_dbs = sync_dbs,
            .official_dbs = official_dbs,
            .aurpkgs_db = findAurpkgsDb(sync_dbs, aur_repo_name),
            .aur_repo_name = aur_repo_name,
            .owns_sync_dbs = false,
            .provides_index = index,
        };
    }

    pub fn deinit(self: *Pacman) void {
        if (self.provides_index) |index| index.destroy();
        self.allocator.free(self.official_dbs);
        if (self.owns_sync_dbs) self.allocator.free(self.sync_dbs);
        for (self.ignore_pkgs) |pkg| self.allocator.free(pkg);
        self.allocator.free(self.ignore_pkgs);
        for (self.cache_dirs) |dir| self.allocator.free(dir);
        self.allocator.free(self.cache_dirs);
        self.handle.deinit();
    }

    /// pacman's package cache directories, as pacman uses them: the
    /// pacman.conf CacheDir values, or its default when there are none.
    pub fn cacheDirs(self: Pacman) []const []const u8 {
        if (self.cache_dirs.len > 0) return self.cache_dirs;
        return &.{pacman_conf.default_cache_dir};
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
        return self.findInOfficialDbs(name) != null;
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

    /// Per-package size data for the verbose table.
    pub const PkgSizeInfo = struct {
        download: i64, // compressed download size from sync db
        net_change: i64, // installed size delta (positive = new or growing)
    };

    /// Download and net-change sizes for a single sync db package.
    /// Returns null if the package is not found in any sync db.
    pub fn repoPkgSizeInfo(self: Pacman, name: []const u8) ?PkgSizeInfo {
        for (self.sync_dbs) |db| {
            if (db.getPackage(name)) |sync_pkg| {
                const old_isize: i64 = if (self.local_db.getPackage(name)) |lp| lp.getIsize() else 0;
                return .{
                    .download = sync_pkg.getSize(),
                    .net_change = sync_pkg.getIsize() - old_isize,
                };
            }
        }
        return null;
    }

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
        const pkg = self.findInOfficialDbs(name) orelse return null;
        return pkg.getVersion();
    }

    // ── Sync Package Conflict Queries ─────────────────────────────────────

    /// Check if a sync db package conflicts with any installed package.
    /// Returns the name of the first installed package that conflicts, or null.
    /// Only checks official repos (skips aurpkgs).
    pub fn syncPkgConflictsWithInstalled(self: Pacman, name: []const u8) ?[]const u8 {
        return self.syncPkgDepViolatesInstalled(name, .conflicts);
    }

    /// Check if a sync db package replaces any installed package.
    /// Returns the name of the first installed package that would be replaced, or null.
    /// Only checks official repos (skips aurpkgs).
    pub fn syncPkgReplacesInstalled(self: Pacman, name: []const u8) ?[]const u8 {
        return self.syncPkgDepViolatesInstalled(name, .replaces);
    }

    const DepListKind = enum { conflicts, replaces };

    /// Shared implementation for conflict/replaces checking against installed packages.
    /// Mirrors libalpm's conflict semantics: the dependency's version
    /// constraint is honoured, and the package never conflicts with (or
    /// replaces) an installed copy of itself.
    fn syncPkgDepViolatesInstalled(self: Pacman, name: []const u8, kind: DepListKind) ?[]const u8 {
        const sync_pkg = self.findInOfficialDbs(name) orelse return null;

        var it = switch (kind) {
            .conflicts => sync_pkg.getConflicts(),
            .replaces => sync_pkg.getReplaces(),
        };
        while (it.next()) |dep| {
            var local_it = self.local_db.getPkgcache();
            while (local_it.next()) |local_pkg| {
                const local_name = local_pkg.getName();
                if (std.mem.eql(u8, local_name, name)) continue;
                if (pkgSatisfiesDep(local_pkg, dep)) return local_name;
            }
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
        return self.findLocalSatisfierPkg(depstring) != null;
    }

    /// Find the installed package that satisfies a dependency (by name or provides).
    /// Returns the satisfier's name, or null if nothing installed satisfies it.
    pub fn findLocalSatisfier(self: Pacman, depstring: []const u8) ?[]const u8 {
        const pkg = self.findLocalSatisfierPkg(depstring) orelse return null;
        return pkg.getName();
    }

    /// alpm_find_satisfier over the installed packages, with a hashed
    /// lookup first. libalpm walks every package twice: first for one
    /// whose own name and version match, then for a provision. Only one
    /// installed package can have the dep's name, so when it matches it
    /// is what the walk would return; anything else takes the walk.
    fn findLocalSatisfierPkg(self: Pacman, depstring: []const u8) ?alpm.AlpmPackage {
        const spec = dep_spec.parseDep(depstring);
        if (self.local_db.getPackage(spec.name)) |pkg| {
            const matches = if (spec.constraint) |c| checkVersion(pkg.getVersion(), c) else true;
            if (matches) return pkg;
        }
        return alpm.findSatisfier(self.local_db.getPkgcache(), depstring);
    }

    /// Pkgbase of the installed package that satisfies `dep` (by name or
    /// provision). Falls back to the package's own name when the local
    /// database has no %BASE% entry. Null if nothing installed satisfies it.
    pub fn installedPkgbase(self: Pacman, dep: []const u8) ?[]const u8 {
        const pkg = self.findLocalSatisfierPkg(dep) orelse return null;
        return pkg.getBase() orelse pkg.getName();
    }

    /// Pkgbase of the package in the local AUR repository that provides
    /// `dep` (by name or provision). Falls back to the package's own name
    /// when the database has no %BASE% entry. Null if the repository has none.
    pub fn aurRepoPkgbase(self: Pacman, dep: []const u8) ?[]const u8 {
        const db = self.aurpkgs_db orelse return null;
        const pkg = db.getPackage(dep_spec.parseDep(dep).name) orelse blk: {
            const match = findProviderInDb(db, dep) orelse return null;
            break :blk db.getPackage(match.name) orelse return null;
        };
        return pkg.getBase() orelse pkg.getName();
    }

    // ── Provider Resolution ──────────────────────────────────────────────

    /// Find a package that provides the given dependency.
    /// Checks official repos first (priority), then aurpkgs.
    /// Returns null if no provider found.
    pub fn findProvider(self: Pacman, dep: []const u8) ?ProviderCandidate {
        if (self.readyIndex()) |index| {
            const entries = index.get(dep);
            return if (entries.len > 0) entries[0].match else null;
        }

        // Check official repos first
        for (self.official_dbs) |db| {
            if (findProviderInDb(db, dep)) |match| return match;
        }

        // Then check aurpkgs
        if (self.aurpkgs_db) |aurdb| {
            if (findProviderInDb(aurdb, dep)) |match| return match;
        }

        return null;
    }

    /// Find ALL packages that provide the given dependency across all sync databases.
    /// Official repos are listed first, then aurpkgs.
    /// Returns empty slice if none found. Caller owns the returned slice.
    pub fn findAllProviders(self: Pacman, allocator: Allocator, dep: []const u8) ![]ProviderCandidate {
        if (self.readyIndex()) |index| return index.collect(allocator, dep, false);

        var matches: std.ArrayList(ProviderCandidate) = .empty;
        errdefer matches.deinit(allocator);

        // Official repos first
        for (self.official_dbs) |db| {
            try findAllProvidersInDb(allocator, db, dep, &matches);
        }

        // Then aurpkgs
        if (self.aurpkgs_db) |aurdb| {
            try findAllProvidersInDb(allocator, aurdb, dep, &matches);
        }

        return try matches.toOwnedSlice(allocator);
    }

    /// The provides index, built now if it has become worth it. Null while
    /// the caller should scan the databases instead: during the first few
    /// lookups, or if the index can't be built (out of memory).
    fn readyIndex(self: Pacman) ?*ProvidesIndex {
        const index = self.provides_index orelse return null;
        if (!index.built) {
            // Building costs about as much as `scan_lookups` scans, so a
            // short resolution never pays for it and a long one pays once.
            if (index.lookups < ProvidesIndex.scan_lookups) {
                index.lookups += 1;
                return null;
            }
            index.build(self.official_dbs, self.aurpkgs_db) catch {
                index.reset();
                return null;
            };
        }
        return index;
    }

    /// Find the first sync DB package (as an AlpmPackage) satisfying `dep`.
    /// Skips aurpkgs — only official repos are searched.
    fn findSyncPkgForDep(self: Pacman, dep: []const u8) ?alpm.AlpmPackage {
        for (self.official_dbs) |db| {
            if (alpm.findSatisfier(db.getPkgcache(), dep)) |pkg| return pkg;
        }
        return null;
    }

    /// Find ALL packages in official sync dbs (no aurpkgs) that satisfy `dep`.
    /// Caller owns the returned slice.
    fn findAllOfficialProviders(self: Pacman, allocator: Allocator, dep: []const u8) ![]ProviderCandidate {
        if (self.readyIndex()) |index| return index.collect(allocator, dep, true);

        var matches: std.ArrayList(ProviderCandidate) = .empty;
        errdefer matches.deinit(allocator);
        for (self.official_dbs) |db| {
            try findAllProvidersInDb(allocator, db, dep, &matches);
        }
        return try matches.toOwnedSlice(allocator);
    }

    /// Compute the full set of official-repo packages that would need to be
    /// installed when installing `root_names`, following runtime `depends`
    /// transitively and excluding packages already installed locally.
    ///
    /// `provider_choices` maps virtual dep names (e.g. "jack") to the chosen
    /// provider package name (e.g. "pipewire-jack"). When a dep is present in
    /// the map the chosen package is used; otherwise first-satisfier wins.
    ///
    /// Deps already satisfied by an installed package (by name or provides)
    /// are excluded — installing a repo provider would conflict with the
    /// installed satisfier (e.g. nodejs-lts-jod vs nodejs-lts-krypton).
    ///
    /// Caller owns the returned slice (strings themselves are borrowed from
    /// libalpm memory and remain valid until Pacman.deinit).
    pub fn transitiveRepoDeps(
        self: anytype,
        allocator: Allocator,
        root_names: []const []const u8,
        provider_choices: std.StringHashMapUnmanaged([]const u8),
    ) ![][]const u8 {
        var result = std.StringArrayHashMapUnmanaged(void){};
        defer result.deinit(allocator);

        var queue: std.ArrayListUnmanaged([]const u8) = .empty;
        defer queue.deinit(allocator);

        var seen = std.StringHashMapUnmanaged(void){};
        defer seen.deinit(allocator);

        for (root_names) |name| {
            if (!(try seen.getOrPut(allocator, name)).found_existing) {
                try queue.append(allocator, name);
            }
        }

        var head: usize = 0;
        while (head < queue.items.len) {
            const dep_str = queue.items[head];
            head += 1;

            // Satisfied by an installed package (by name or via provides) —
            // do not pull in a repo provider that would conflict with it.
            if (self.satisfiesDep(dep_str)) continue;

            const pkg = (if (provider_choices.get(dep_str)) |chosen_name|
                self.findInOfficialDbs(chosen_name)
            else
                self.findSyncPkgForDep(dep_str)) orelse continue;
            const pkg_name = pkg.getName();

            try seen.put(allocator, pkg_name, {});

            if (self.isInstalled(pkg_name)) continue;

            if (!(try result.getOrPut(allocator, pkg_name)).found_existing) {
                var dep_it = pkg.getDepends();
                while (dep_it.next()) |dep| {
                    if (!(try seen.getOrPut(allocator, dep.name)).found_existing) {
                        try queue.append(allocator, dep.name);
                    }
                }
            }
        }

        return try allocator.dupe([]const u8, result.keys());
    }

    /// Walk the transitive repo dep closure of `root_names` and return a
    /// `SyncProviderChoice` for each virtual dep that has more than one
    /// uninstalled provider in official repos.
    ///
    /// Deps already satisfied by an installed package (by name or provides)
    /// are skipped — no choice is needed and offering one would propose
    /// providers that conflict with the installed satisfier.
    ///
    /// BFS uses first-satisfier order; the returned choices are in BFS
    /// encounter order.  Caller owns the slice and each `candidates` slice
    /// inside it.
    pub fn findTransitiveProviderChoices(
        self: anytype,
        allocator: Allocator,
        root_names: []const []const u8,
    ) ![]SyncProviderChoice {
        var choices: std.ArrayListUnmanaged(SyncProviderChoice) = .empty;
        errdefer {
            for (choices.items) |ch| allocator.free(ch.candidates);
            choices.deinit(allocator);
        }

        var queue: std.ArrayListUnmanaged([]const u8) = .empty;
        defer queue.deinit(allocator);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(allocator);

        for (root_names) |name| {
            if (!(try seen.getOrPut(allocator, name)).found_existing) {
                try queue.append(allocator, name);
            }
        }

        var head: usize = 0;
        while (head < queue.items.len) {
            const dep_str = queue.items[head];
            head += 1;

            // Already satisfied by an installed package (by name or via
            // provides, e.g. nodejs-lts-krypton provides nodejs) — nothing
            // to choose or install.
            if (self.satisfiesDep(dep_str)) continue;

            const all = try self.findAllOfficialProviders(allocator, dep_str);
            defer allocator.free(all);

            var uninstalled: std.ArrayListUnmanaged(ProviderCandidate) = .empty;
            defer uninstalled.deinit(allocator);
            for (all) |p| {
                if (!self.isInstalled(p.name)) {
                    try uninstalled.append(allocator, p);
                }
            }

            if (uninstalled.items.len == 0) continue;

            const first_name = uninstalled.items[0].name;
            try seen.put(allocator, first_name, {});

            if (uninstalled.items.len > 1) {
                var claimed = false;
                const candidates = try uninstalled.toOwnedSlice(allocator);
                errdefer if (!claimed) allocator.free(candidates);
                try choices.append(allocator, .{ .dep_name = dep_str, .candidates = candidates });
                claimed = true;
            }

            const pkg = self.findInOfficialDbs(first_name) orelse continue;
            if (self.isInstalled(first_name)) continue;

            var dep_it = pkg.getDepends();
            while (dep_it.next()) |dep| {
                if (!(try seen.getOrPut(allocator, dep.name)).found_existing) {
                    try queue.append(allocator, dep.name);
                }
            }
        }

        return try choices.toOwnedSlice(allocator);
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
            if (!self.isInOfficialSyncDb(name)) {
                try foreign.append(self.allocator, .{
                    .name = name,
                    .version = pkg.getVersion(),
                });
            }
        }

        return try foreign.toOwnedSlice(self.allocator);
    }

    /// Find a package by name in official sync databases (skips aurpkgs).
    fn findInOfficialDbs(self: Pacman, name: []const u8) ?alpm.AlpmPackage {
        for (self.official_dbs) |db| {
            if (db.getPackage(name)) |pkg| return pkg;
        }
        return null;
    }
};

// ── Internal Helpers ─────────────────────────────────────────────────────

/// Find the AUR repo database among sync databases by name.
fn findAurpkgsDb(sync_dbs: []alpm.Database, aur_repo_name: []const u8) ?alpm.Database {
    for (sync_dbs) |db| {
        if (std.mem.eql(u8, db.getName(), aur_repo_name)) return db;
    }
    return null;
}

/// Allocate a copy of `sync_dbs` excluding the AUR repo.  The resulting slice
/// is always owned by the caller.
fn buildOfficialDbs(allocator: Allocator, sync_dbs: []alpm.Database, aur_repo_name: []const u8) ![]alpm.Database {
    var list: std.ArrayListUnmanaged(alpm.Database) = .empty;
    errdefer list.deinit(allocator);
    try list.ensureTotalCapacity(allocator, sync_dbs.len);
    for (sync_dbs) |db| {
        if (!std.mem.eql(u8, db.getName(), aur_repo_name)) {
            list.appendAssumeCapacity(db);
        }
    }
    return try list.toOwnedSlice(allocator);
}

/// Check if a package matches a dependency by name or provides list.
/// libalpm's dependency match (_alpm_depcmp): `pkg` satisfies `dep` by
/// name with a matching version, or through a provision. A versioned dep
/// is only satisfied by a provision that carries a version (`foo=1.2`).
fn pkgSatisfiesDep(pkg: alpm.AlpmPackage, dep: alpm.Dependency) bool {
    if (depMatches(dep, pkg.getName(), pkg.getVersion())) return true;
    var prov_it = pkg.getProvides();
    while (prov_it.next()) |prov| {
        const prov_version: ?[]const u8 = if (prov.mod == .eq) prov.version else null;
        if (depMatches(dep, prov.name, prov_version)) return true;
    }
    return false;
}

/// Does a package or provision called `name` at `version` satisfy `dep`?
/// `ver` is null for an unversioned provision.
fn depMatches(dep: alpm.Dependency, name: []const u8, ver: ?[]const u8) bool {
    if (!std.mem.eql(u8, dep.name, name)) return false;
    const op: CmpOp = switch (dep.mod) {
        .any => return true,
        .eq => .eq,
        .ge => .ge,
        .le => .le,
        .gt => .gt,
        .lt => .lt,
    };
    const v = ver orelse return false;
    return checkVersion(v, .{ .op = op, .version = dep.version });
}

fn packageMatchesDep(pkg: alpm.AlpmPackage, dep: []const u8) bool {
    if (std.mem.eql(u8, pkg.getName(), dep)) return true;
    var dep_it = pkg.getProvides();
    while (dep_it.next()) |prov| {
        if (std.mem.eql(u8, prov.name, dep)) return true;
    }
    return false;
}

fn providerMatchFromPkg(pkg: alpm.AlpmPackage, db: alpm.Database) ProviderCandidate {
    return .{
        .name = pkg.getName(),
        .version = pkg.getVersion(),
        .db_name = db.getName(),
    };
}

/// Every sync package indexed under its own name and each name it
/// provides, so provider lookups cost a hash lookup instead of a walk over
/// all ~15k packages and their provides lists. Entries for a name keep the
/// scan order: official databases in pacman.conf order, then the AUR repo,
/// each in package cache order. Strings are borrowed from libalpm and stay
/// valid until Pacman.deinit.
/// Not thread-safe.
const ProvidesIndex = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Entry)) = .empty,
    built: bool = false,
    /// Lookups answered by scanning while the index was not built.
    lookups: u32 = 0,

    /// One scan of every sync package takes about 1 ms; building the
    /// index about 8 ms.
    const scan_lookups = 8;

    const Entry = struct {
        match: ProviderCandidate,
        /// False for the local AUR repository.
        official: bool,
    };

    fn create(allocator: Allocator) !*ProvidesIndex {
        const index = try allocator.create(ProvidesIndex);
        index.* = .{ .allocator = allocator, .arena = .init(allocator) };
        return index;
    }

    fn destroy(self: *ProvidesIndex) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn reset(self: *ProvidesIndex) void {
        _ = self.arena.reset(.free_all);
        self.map = .empty;
        self.built = false;
        self.lookups = 0;
    }

    fn build(self: *ProvidesIndex, official_dbs: []const alpm.Database, aurpkgs_db: ?alpm.Database) !void {
        for (official_dbs) |db| try self.addDb(db, true);
        if (aurpkgs_db) |db| try self.addDb(db, false);
        self.built = true;
    }

    fn addDb(self: *ProvidesIndex, db: alpm.Database, official: bool) !void {
        var it = db.getPkgcache();
        while (it.next()) |pkg| {
            const entry: Entry = .{ .match = providerMatchFromPkg(pkg, db), .official = official };
            try self.add(pkg.getName(), entry);
            var prov_it = pkg.getProvides();
            while (prov_it.next()) |prov| try self.add(prov.name, entry);
        }
    }

    fn add(self: *ProvidesIndex, name: []const u8, entry: Entry) !void {
        const arena = self.arena.allocator();
        const gop = try self.map.getOrPut(arena, name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const list = gop.value_ptr;
        // A package listing a name twice (or providing its own name)
        // is still one provider.
        if (list.items.len > 0 and list.items[list.items.len - 1].match.name.ptr == entry.match.name.ptr) return;
        try list.append(arena, entry);
    }

    fn get(self: *const ProvidesIndex, name: []const u8) []const Entry {
        const list = self.map.get(name) orelse return &.{};
        return list.items;
    }

    /// Providers of `name`, optionally official ones only. Caller owns
    /// the slice.
    fn collect(self: *const ProvidesIndex, allocator: Allocator, name: []const u8, official_only: bool) ![]ProviderCandidate {
        var matches: std.ArrayList(ProviderCandidate) = .empty;
        errdefer matches.deinit(allocator);
        for (self.get(name)) |entry| {
            if (official_only and !entry.official) continue;
            try matches.append(allocator, entry.match);
        }
        return try matches.toOwnedSlice(allocator);
    }
};

/// Search a single database for a package that provides `dep`.
fn findProviderInDb(db: alpm.Database, dep: []const u8) ?ProviderCandidate {
    var it = db.getPkgcache();
    while (it.next()) |pkg| {
        if (packageMatchesDep(pkg, dep)) return providerMatchFromPkg(pkg, db);
    }
    return null;
}

/// Collect ALL packages in a single database that provide `dep`.
fn findAllProvidersInDb(allocator: Allocator, db: alpm.Database, dep: []const u8, matches: *std.ArrayList(ProviderCandidate)) !void {
    var it = db.getPkgcache();
    while (it.next()) |pkg| {
        if (packageMatchesDep(pkg, dep)) {
            try matches.append(allocator, providerMatchFromPkg(pkg, db));
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────────

fn testDep(name: []const u8, mod: alpm.DepMod, ver: []const u8) alpm.Dependency {
    return .{ .name = name, .version = ver, .desc = null, .name_hash = 0, .mod = mod };
}

test "depMatches: unversioned dep matches any version or provision" {
    const dep = testDep("jack", .any, "");
    try std.testing.expect(depMatches(dep, "jack", "0.126"));
    try std.testing.expect(depMatches(dep, "jack", null));
    try std.testing.expect(!depMatches(dep, "jack2", "1.9"));
}

test "depMatches: versioned dep honours the constraint" {
    const dep = testDep("foo", .lt, "2");
    try std.testing.expect(depMatches(dep, "foo", "1.5"));
    try std.testing.expect(!depMatches(dep, "foo", "3"));
}

test "depMatches: versioned dep is not satisfied by an unversioned provision" {
    const dep = testDep("foo", .ge, "1");
    try std.testing.expect(!depMatches(dep, "foo", null));
}

const testing = std.testing;

/// The scan the provides index replaces, kept as the reference for tests.
fn scanAllProviders(pm: Pacman, allocator: Allocator, dep: []const u8, official_only: bool) ![]ProviderCandidate {
    var matches: std.ArrayList(ProviderCandidate) = .empty;
    errdefer matches.deinit(allocator);
    for (pm.official_dbs) |db| try findAllProvidersInDb(allocator, db, dep, &matches);
    if (!official_only) {
        if (pm.aurpkgs_db) |aurdb| try findAllProvidersInDb(allocator, aurdb, dep, &matches);
    }
    return try matches.toOwnedSlice(allocator);
}

fn expectSameProviders(pm: Pacman, name: []const u8) !void {
    const a = testing.allocator;
    inline for (.{ false, true }) |official_only| {
        const want = try scanAllProviders(pm, a, name, official_only);
        defer a.free(want);
        const got = if (official_only) try pm.findAllOfficialProviders(a, name) else try pm.findAllProviders(a, name);
        defer a.free(got);
        try testing.expectEqual(want.len, got.len);
        for (want, got) |w, g| {
            try testing.expectEqualStrings(w.name, g.name);
            try testing.expectEqualStrings(w.db_name, g.db_name);
        }
    }
    const first = pm.findProvider(name);
    const all = try scanAllProviders(pm, a, name, false);
    defer a.free(all);
    if (all.len == 0) {
        try testing.expect(first == null);
    } else {
        try testing.expectEqualStrings(all[0].name, first.?.name);
    }
}

test "provides index answers like a database scan" {
    if (!pacman_conf.isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(testing.allocator, repo_conf.DEFAULT_REPO_NAME);
    defer pm.deinit();

    for ([_][]const u8{ "sh", "java-runtime", "jack", "nodejs", "libgl", "glibc", "zzz-not-a-package" }) |name| {
        try expectSameProviders(pm, name);
    }
    // A sample of real names and provisions from every official database.
    var n: usize = 0;
    for (pm.official_dbs) |db| {
        var it = db.getPkgcache();
        while (it.next()) |pkg| : (n += 1) {
            if (n % 400 != 0) continue;
            try expectSameProviders(pm, pkg.getName());
            var prov_it = pkg.getProvides();
            while (prov_it.next()) |prov| try expectSameProviders(pm, prov.name);
        }
    }
    try testing.expect(pm.provides_index.?.built);

    // Dropping the index (as a failed index build does) falls back to scanning,
    // then rebuilds it once lookups pile up again.
    pm.provides_index.?.reset();
    try testing.expect(!pm.provides_index.?.built);
    for (0..ProvidesIndex.scan_lookups + 1) |_| try expectSameProviders(pm, "sh");
    try testing.expect(pm.provides_index.?.built);
}

test "installed-package fast path agrees with alpm_find_satisfier" {
    if (!pacman_conf.isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(testing.allocator, repo_conf.DEFAULT_REPO_NAME);
    defer pm.deinit();

    var checked: usize = 0;
    var it = pm.local_db.getPkgcache();
    while (it.next()) |pkg| {
        const name = pkg.getName();
        const ver = pkg.getVersion();
        var buf: [512]u8 = undefined;
        const deps = [_][]const u8{
            name,
            try std.fmt.bufPrint(buf[0..128], "{s}={s}", .{ name, ver }),
            try std.fmt.bufPrint(buf[128..256], "{s}>={s}", .{ name, ver }),
            try std.fmt.bufPrint(buf[256..384], "{s}>{s}", .{ name, ver }),
            try std.fmt.bufPrint(buf[384..512], "{s}<1", .{name}),
        };
        for (deps) |dep| {
            const want = alpm.findSatisfier(pm.local_db.getPkgcache(), dep);
            const got = pm.findLocalSatisfierPkg(dep);
            try testing.expectEqual(want == null, got == null);
            if (want) |w| try testing.expectEqualStrings(w.getName(), got.?.getName());
        }
        // Provisions of installed packages (resolved by the walk).
        var prov_it = pkg.getProvides();
        while (prov_it.next()) |prov| {
            const want = alpm.findSatisfier(pm.local_db.getPkgcache(), prov.name);
            const got = pm.findLocalSatisfierPkg(prov.name);
            try testing.expectEqual(want == null, got == null);
            if (want) |w| try testing.expectEqualStrings(w.getName(), got.?.getName());
        }
        checked += 1;
    }
    try testing.expect(checked > 0);
    try testing.expect(!pm.satisfiesDep("zzz-not-installed-12345"));
}
