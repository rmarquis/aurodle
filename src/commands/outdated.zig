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

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;
const Installed = pacman_mod.InstalledPackage;

fn versionMap(pairs: []const [2][]const u8) !std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    errdefer map.deinit(testing.allocator);
    for (pairs) |p| try map.put(testing.allocator, p[0], p[1]);
    return map;
}

fn expectNames(expected: []const []const u8, entries: []const OutdatedEntry) !void {
    try testing.expectEqual(expected.len, entries.len);
    for (expected, entries) |name, entry| try testing.expectEqualStrings(name, entry.name);
}

test "filterByName keeps named packages in installed order" {
    const installed = [_]Installed{
        .{ .name = "a", .version = "1-1" },
        .{ .name = "b", .version = "1-1" },
        .{ .name = "c", .version = "1-1" },
    };
    const got = try filterByName(testing.allocator, &installed, &.{ "c", "unknown", "a" });
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("a", got[0].name);
    try testing.expectEqualStrings("c", got[1].name);
}

test "filterByName returns nothing when no name matches" {
    const installed = [_]Installed{.{ .name = "a", .version = "1-1" }};
    const got = try filterByName(testing.allocator, &installed, &.{"z"});
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "compareWithAur flags only packages with a newer AUR version" {
    const installed = [_]Installed{
        .{ .name = "older", .version = "1.0-1" },
        .{ .name = "same", .version = "2.0-1" },
        .{ .name = "newer", .version = "3.1-1" },
        .{ .name = "pkgrel", .version = "1.0-1" },
    };
    var aur = try versionMap(&.{
        .{ "older", "1.1-1" },
        .{ "same", "2.0-1" },
        .{ "newer", "3.0-1" },
        .{ "pkgrel", "1.0-2" },
    });
    defer aur.deinit(testing.allocator);

    var cmp = try compareWithAur(testing.allocator, &installed, &aur, .{});
    defer cmp.deinit(testing.allocator);

    try expectNames(&.{ "older", "pkgrel" }, cmp.entries.items);
    try testing.expectEqualStrings("1.0-1", cmp.entries.items[0].installed_version);
    try testing.expectEqualStrings("1.1-1", cmp.entries.items[0].aur_version);
    try testing.expectEqual(@as(usize, 0), cmp.not_found.items.len);
}

test "compareWithAur honours epochs" {
    const installed = [_]Installed{
        .{ .name = "epoch-installed", .version = "1:1.0-1" },
        .{ .name = "epoch-aur", .version = "9.0-1" },
    };
    var aur = try versionMap(&.{
        .{ "epoch-installed", "2.0-1" },
        .{ "epoch-aur", "1:0.5-1" },
    });
    defer aur.deinit(testing.allocator);

    var cmp = try compareWithAur(testing.allocator, &installed, &aur, .{});
    defer cmp.deinit(testing.allocator);

    try expectNames(&.{"epoch-aur"}, cmp.entries.items);
}

test "compareWithAur lists packages the AUR does not know, in order" {
    const installed = [_]Installed{
        .{ .name = "local-b", .version = "1-1" },
        .{ .name = "known", .version = "1-1" },
        .{ .name = "local-a", .version = "1-1" },
    };
    var aur = try versionMap(&.{.{ "known", "2-1" }});
    defer aur.deinit(testing.allocator);

    var cmp = try compareWithAur(testing.allocator, &installed, &aur, .{});
    defer cmp.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), cmp.not_found.items.len);
    try testing.expectEqualStrings("local-b", cmp.not_found.items[0]);
    try testing.expectEqualStrings("local-a", cmp.not_found.items[1]);
    try expectNames(&.{"known"}, cmp.entries.items);
}

test "compareWithAur keeps ignored packages but flags them" {
    const installed = [_]Installed{
        .{ .name = "held", .version = "1-1" },
        .{ .name = "free", .version = "1-1" },
    };
    var aur = try versionMap(&.{ .{ "held", "2-1" }, .{ "free", "2-1" } });
    defer aur.deinit(testing.allocator);

    var cmp = try compareWithAur(testing.allocator, &installed, &aur, .{ .ignore = &.{"held"} });
    defer cmp.deinit(testing.allocator);

    try expectNames(&.{ "held", "free" }, cmp.entries.items);
    try testing.expect(cmp.entries.items[0].ignored);
    try testing.expect(!cmp.entries.items[1].ignored);
}

test "compareWithAur records every flagged name in outdated" {
    const installed = [_]Installed{
        .{ .name = "a", .version = "1-1" },
        .{ .name = "b", .version = "2-1" },
    };
    var aur = try versionMap(&.{ .{ "a", "2-1" }, .{ "b", "2-1" } });
    defer aur.deinit(testing.allocator);

    var cmp = try compareWithAur(testing.allocator, &installed, &aur, .{});
    defer cmp.deinit(testing.allocator);

    try testing.expect(cmp.outdated.contains("a"));
    try testing.expect(!cmp.outdated.contains("b"));
}

test "vcsPkgbases checks each split pkgbase once, in first-seen order" {
    const installed = [_]Installed{
        .{ .name = "tool-git", .version = "r1-1" },
        .{ .name = "plain", .version = "1-1" },
        .{ .name = "lib-git", .version = "r1-1" },
        .{ .name = "tool-docs-git", .version = "r1-1" },
        .{ .name = "solo-svn", .version = "r1-1" },
    };
    var pkgbases = try versionMap(&.{
        .{ "tool-git", "tool-git" },
        .{ "tool-docs-git", "tool-git" },
        .{ "lib-git", "lib-git" },
    });
    defer pkgbases.deinit(testing.allocator);

    var index = try vcsPkgbases(testing.allocator, &installed, &pkgbases);
    defer index.deinit(testing.allocator);

    const keys = index.keys();
    try testing.expectEqual(@as(usize, 3), keys.len);
    try testing.expectEqualStrings("tool-git", keys[0]);
    try testing.expectEqualStrings("lib-git", keys[1]);
    // Not in the map: its own pkgbase.
    try testing.expectEqualStrings("solo-svn", keys[2]);
}

test "mergeDevelVersion refines an entry the AUR pass flagged" {
    var entries: std.ArrayListUnmanaged(OutdatedEntry) = .empty;
    defer entries.deinit(testing.allocator);
    try entries.append(testing.allocator, .{ .name = "x-git", .installed_version = "r1-1", .aur_version = "r2-1" });
    var flagged: std.StringHashMapUnmanaged(void) = .empty;
    defer flagged.deinit(testing.allocator);
    try flagged.put(testing.allocator, "x-git", {});

    try mergeDevelVersion(testing.allocator, &entries, &flagged, .{ .name = "x-git", .version = "r1-1" }, "r9-1", .{});

    try testing.expectEqual(@as(usize, 1), entries.items.len);
    try testing.expectEqualStrings("r9-1", entries.items[0].aur_version);
}

test "mergeDevelVersion adds a VCS package with a newer upstream version" {
    var entries: std.ArrayListUnmanaged(OutdatedEntry) = .empty;
    defer entries.deinit(testing.allocator);
    const flagged: std.StringHashMapUnmanaged(void) = .empty;

    try mergeDevelVersion(testing.allocator, &entries, &flagged, .{ .name = "y-git", .version = "r1.abc-1" }, "r5.def-1", .{ .ignore = &.{"y-git"} });

    try testing.expectEqual(@as(usize, 1), entries.items.len);
    try testing.expectEqualStrings("y-git", entries.items[0].name);
    try testing.expectEqualStrings("r1.abc-1", entries.items[0].installed_version);
    try testing.expectEqualStrings("r5.def-1", entries.items[0].aur_version);
    try testing.expect(entries.items[0].ignored);
}

test "mergeDevelVersion skips a VCS package that is up to date" {
    var entries: std.ArrayListUnmanaged(OutdatedEntry) = .empty;
    defer entries.deinit(testing.allocator);
    const flagged: std.StringHashMapUnmanaged(void) = .empty;

    try mergeDevelVersion(testing.allocator, &entries, &flagged, .{ .name = "z-git", .version = "r5-1" }, "r5-1", .{});
    try mergeDevelVersion(testing.allocator, &entries, &flagged, .{ .name = "z-git", .version = "r6-1" }, "r5-1", .{});

    try testing.expectEqual(@as(usize, 0), entries.items.len);
}
