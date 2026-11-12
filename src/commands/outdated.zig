const std = @import("std");
const registry_mod = @import("../registry.zig");
const devel = @import("../devel.zig");
const pacman_mod = @import("../pacman.zig");
const git = @import("../git.zig");
const utils = @import("../utils.zig");
const types = @import("types.zig");
const build_ctx = @import("build_context.zig");

const BuildContext = build_ctx.BuildContext;
const OutdatedEntry = types.OutdatedEntry;
const OutdatedList = types.OutdatedList;
const printError = types.printError;

/// Shared core for `outdated` and `upgrade`: find installed AUR packages whose
/// AUR (or --devel) version is newer than the installed one.
///
/// When `filter` is non-empty, only packages matching those names are checked.
/// When `flags.devel` is set, VCS packages are additionally probed via
/// `makepkg --nobuild` + `--printsrcinfo`.  When `populate_hint` is true,
/// devel versions are also stored in `self.devel_version_hint` so downstream
/// `displayPlan` can show real VCS versions.
///
/// Returns `null` on a reportable failure (already logged); returns an
/// `OutdatedList` otherwise.  The caller owns the list and must `deinit` it;
/// if `populate_hint` was true, the caller must also clear `devel_version_hint`
/// *before* deinit (LIFO defer ordering makes this natural).
pub fn collectOutdated(self: *BuildContext, filter: []const []const u8, populate_hint: bool) !?OutdatedList {
    const ec = self.stderr_color;
    const pm = self.pacman;

    const foreign = try pm.allForeignPackages();
    defer self.allocator.free(foreign);

    const to_check = if (filter.len > 0) try filterByName(self.allocator, foreign, filter) else foreign;
    defer if (filter.len > 0) self.allocator.free(to_check);

    if (to_check.len == 0) {
        return .{ .entries = &.{}, .devel_versions = &.{}, .total_checked = 0 };
    }

    // Batch query AUR for all foreign package names
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(self.allocator);
    try names.ensureUnusedCapacity(self.allocator, to_check.len);
    for (to_check) |pkg| names.appendAssumeCapacity(pkg.name);

    const aur_pkgs = self.aur_client.multiInfo(names.items) catch |err| {
        printError(err, self.err_writer, ec);
        return null;
    };
    defer self.allocator.free(aur_pkgs);

    // Build lookup maps: name -> AUR version, name -> pkgbase
    var aur_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer aur_map.deinit(self.allocator);
    var pkgbase_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer pkgbase_map.deinit(self.allocator);
    for (aur_pkgs) |pkg| {
        try aur_map.put(self.allocator, pkg.name, pkg.version);
        try pkgbase_map.put(self.allocator, pkg.name, pkg.pkgbase);
    }

    var cmp = try compareWithAur(self.allocator, to_check, &aur_map, self.flags);
    defer cmp.deinit(self.allocator);
    if (!self.flags.quiet) {
        for (cmp.not_found.items) |name| {
            self.err_writer.print("{s}warning:{s} {s} not found in AUR\n", .{ ec.yellow, ec.reset, name });
        }
    }

    // --devel: VCS packages via makepkg --nobuild + --printsrcinfo
    var devel_versions: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (devel_versions.items) |v| self.allocator.free(v);
        devel_versions.deinit(self.allocator);
    }
    if (self.flags.devel) {
        try checkDevelPackages(self, to_check, &pkgbase_map, &cmp.outdated, &cmp.entries, &devel_versions, populate_hint);
    }

    return .{
        .entries = try cmp.entries.toOwnedSlice(self.allocator),
        .devel_versions = try devel_versions.toOwnedSlice(self.allocator),
        .total_checked = to_check.len,
    };
}

/// Check VCS packages for upstream updates via makepkg --nobuild.
/// Entries already flagged via AUR RPC are refined in place; pure-VCS updates
/// are appended.  When `populate_hint` is true, each computed version is also
/// stored in `self.devel_version_hint` so the build pipeline can render it.
///
/// `pkgbase_map` maps package names to their AUR pkgbase. The clone and
/// makepkg run happen once per pkgbase, so split VCS packages use the
/// right clone directory and are not re-checked for each package name.
/// Names missing from the map are assumed to be their own pkgbase.
/// One parallelFor job: run the VCS version check for `pkgbases[i]`.
const DevelJob = struct {
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    pkgbases: []const []const u8,
    outcomes: []Outcome,

    const Outcome = union(enum) {
        failed,
        no_version,
        /// `version` is owned; the caller moves it into devel_versions.
        version: devel.VersionCheck,
    };

    fn run(job: *const DevelJob, i: usize) void {
        const result = devel.checkVersion(job.allocator, job.cache_root, job.pkgbases[i]) catch {
            job.outcomes[i] = .failed;
            return;
        };
        job.outcomes[i] = if (result) |v| .{ .version = v } else .no_version;
    }
};

pub fn checkDevelPackages(
    self: *BuildContext,
    packages: []const pacman_mod.InstalledPackage,
    pkgbase_map: *const std.StringHashMapUnmanaged([]const u8),
    already_outdated: *const std.StringHashMapUnmanaged(void),
    entries: *std.ArrayListUnmanaged(OutdatedEntry),
    devel_versions: *std.ArrayListUnmanaged([]const u8),
    populate_hint: bool,
) !void {
    const ec2 = self.stderr_color;
    const c_root = self.cache_root;

    const has_vcs = for (packages) |pkg| {
        if (devel.isVcsPackage(pkg.name)) break true;
    } else false;
    if (has_vcs and !self.flags.quiet) {
        self.err_writer.print("{s}::{s} checking VCS package(s)...\n", .{ ec2.blue, ec2.reset });
    }

    // Check each VCS pkgbase once (split packages share one), all in
    // parallel: every check is a git fetch plus two makepkg runs.
    var pkgbase_index = try vcsPkgbases(self.allocator, packages, pkgbase_map);
    defer pkgbase_index.deinit(self.allocator);
    const pkgbases = pkgbase_index.keys();

    const outcomes = try self.allocator.alloc(DevelJob.Outcome, pkgbases.len);
    defer self.allocator.free(outcomes);
    const job: DevelJob = .{
        .allocator = self.allocator,
        .cache_root = c_root,
        .pkgbases = pkgbases,
        .outcomes = outcomes,
    };
    utils.parallelFor(pkgbases.len, utils.max_parallel_jobs, &job, DevelJob.run);

    // Hand every computed version to `devel_versions` (which owns them)
    // before anything below can fail, so none leak.
    devel_versions.ensureUnusedCapacity(self.allocator, pkgbases.len) catch |err| {
        for (outcomes) |o| if (o == .version) self.allocator.free(o.version.version);
        return err;
    };
    for (pkgbases, outcomes) |pkgbase, outcome| switch (outcome) {
        .failed => self.err_writer.print("{s}warning:{s} failed to check VCS version for {s}\n", .{ ec2.yellow, ec2.reset, pkgbase }),
        .no_version => {},
        .version => |v| devel_versions.appendAssumeCapacity(v.version),
    };

    for (packages) |pkg| {
        if (!devel.isVcsPackage(pkg.name)) continue;

        const pkgbase = pkgbase_map.get(pkg.name) orelse pkg.name;
        const check = switch (outcomes[pkgbase_index.getIndex(pkgbase).?]) {
            .version => |v| v,
            else => continue,
        };
        const version = check.version;
        if (populate_hint) {
            try self.devel_version_hint.put(self.allocator, pkg.name, version);
            if (check.prepared_stamp) |stamp| {
                try self.devel_prepared.put(self.allocator, pkg.name, stamp);
            }
        }

        try mergeDevelVersion(self.allocator, entries, already_outdated, pkg, version, self.flags);
    }
}

// ── Decisions (pure, no I/O) ─────────────────────────────────────────────

/// The packages in `installed` whose name is in `names`, in `installed`
/// order. Names that match nothing are ignored. Caller frees the slice;
/// the packages are borrowed from `installed`.
pub fn filterByName(
    allocator: std.mem.Allocator,
    installed: []const pacman_mod.InstalledPackage,
    names: []const []const u8,
) ![]pacman_mod.InstalledPackage {
    var name_set: std.StringHashMapUnmanaged(void) = .empty;
    defer name_set.deinit(allocator);
    for (names) |n| try name_set.put(allocator, n, {});

    var filtered: std.ArrayListUnmanaged(pacman_mod.InstalledPackage) = .empty;
    errdefer filtered.deinit(allocator);
    for (installed) |pkg| {
        if (name_set.contains(pkg.name)) try filtered.append(allocator, pkg);
    }
    return filtered.toOwnedSlice(allocator);
}

/// Installed packages compared against their AUR versions.
/// All strings are borrowed from the inputs of compareWithAur.
pub const AurComparison = struct {
    /// Packages whose AUR version is newer, in input order.
    entries: std.ArrayListUnmanaged(OutdatedEntry) = .empty,
    /// Names in `entries`. The --devel pass refines these entries instead
    /// of adding a second one.
    outdated: std.StringHashMapUnmanaged(void) = .empty,
    /// Installed packages the AUR does not know, in input order.
    not_found: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *AurComparison, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.outdated.deinit(allocator);
        self.not_found.deinit(allocator);
    }
};

/// Compare each installed package with its AUR version (`aur_versions`
/// maps name to version). Ignored packages are still listed, flagged
/// `ignored`, so callers can warn about them.
pub fn compareWithAur(
    allocator: std.mem.Allocator,
    installed: []const pacman_mod.InstalledPackage,
    aur_versions: *const std.StringHashMapUnmanaged([]const u8),
    flags: types.Flags,
) !AurComparison {
    var result: AurComparison = .{};
    errdefer result.deinit(allocator);
    for (installed) |pkg| {
        const aur_ver = aur_versions.get(pkg.name) orelse {
            try result.not_found.append(allocator, pkg.name);
            continue;
        };
        if (registry_mod.PackageRegistry.vercmp(pkg.version, aur_ver) < 0) {
            try result.entries.append(allocator, .{
                .name = pkg.name,
                .installed_version = pkg.version,
                .aur_version = aur_ver,
                .ignored = types.isIgnored(flags, pkg.name),
            });
            try result.outdated.put(allocator, pkg.name, {});
        }
    }
    return result;
}

/// The pkgbases of the VCS packages in `packages`, each once and in first-
/// seen order: split packages share a pkgbase and one version check.
/// `pkgbase_map` maps package names to pkgbases; a missing name is its own
/// pkgbase. Keys are borrowed. Caller deinits.
pub fn vcsPkgbases(
    allocator: std.mem.Allocator,
    packages: []const pacman_mod.InstalledPackage,
    pkgbase_map: *const std.StringHashMapUnmanaged([]const u8),
) !std.StringArrayHashMapUnmanaged(void) {
    var index: std.StringArrayHashMapUnmanaged(void) = .empty;
    errdefer index.deinit(allocator);
    for (packages) |pkg| {
        if (!devel.isVcsPackage(pkg.name)) continue;
        try index.put(allocator, pkgbase_map.get(pkg.name) orelse pkg.name, {});
    }
    return index;
}

/// Fold the VCS version computed for `pkg` into `entries`. If the AUR pass
/// already flagged `pkg` (it is in `already_outdated`), its entry shows
/// `version` instead of the AUR's stale one. Otherwise `pkg` is added
/// when `version` is newer than the installed one.
pub fn mergeDevelVersion(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(OutdatedEntry),
    already_outdated: *const std.StringHashMapUnmanaged(void),
    pkg: pacman_mod.InstalledPackage,
    version: []const u8,
    flags: types.Flags,
) !void {
    if (already_outdated.contains(pkg.name)) {
        for (entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, pkg.name)) {
                entry.aur_version = version;
                return;
            }
        }
    } else if (registry_mod.PackageRegistry.vercmp(pkg.version, version) < 0) {
        try entries.append(allocator, .{
            .name = pkg.name,
            .installed_version = pkg.version,
            .aur_version = version,
            .ignored = types.isIgnored(flags, pkg.name),
        });
    }
}
