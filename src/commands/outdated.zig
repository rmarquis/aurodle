const std = @import("std");
const registry_mod = @import("../registry.zig");
const devel = @import("../devel.zig");
const pacman_mod = @import("../pacman.zig");
const git = @import("../git.zig");
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

    // Apply name filter if provided
    const to_check = if (filter.len > 0) blk: {
        var name_set: std.StringHashMapUnmanaged(void) = .empty;
        defer name_set.deinit(self.allocator);
        for (filter) |n| try name_set.put(self.allocator, n, {});

        var filtered: std.ArrayListUnmanaged(pacman_mod.InstalledPackage) = .empty;
        for (foreign) |pkg| {
            if (name_set.contains(pkg.name)) try filtered.append(self.allocator, pkg);
        }
        break :blk try filtered.toOwnedSlice(self.allocator);
    } else foreign;
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
        try printError(err, self.err_writer, ec);
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

    // Compare versions
    var entries: std.ArrayListUnmanaged(OutdatedEntry) = .empty;
    errdefer entries.deinit(self.allocator);

    // Track packages already flagged outdated via AUR RPC so the devel pass
    // can refine their aur_version instead of duplicating them.
    var already_outdated: std.StringHashMapUnmanaged(void) = .empty;
    defer already_outdated.deinit(self.allocator);

    for (to_check) |pkg| {
        if (aur_map.get(pkg.name)) |aur_ver| {
            if (registry_mod.PackageRegistry.vercmp(pkg.version, aur_ver) < 0) {
                try entries.append(self.allocator, .{
                    .name = pkg.name,
                    .installed_version = pkg.version,
                    .aur_version = aur_ver,
                    .ignored = types.isIgnored(self.flags, pkg.name),
                });
                try already_outdated.put(self.allocator, pkg.name, {});
            }
        } else if (!self.flags.quiet) {
            self.err_writer.print("{s}warning:{s} {s} not found in AUR\n", .{ ec.yellow, ec.reset, pkg.name }) catch {};
        }
    }

    // --devel: VCS packages via makepkg --nobuild + --printsrcinfo
    var devel_versions: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (devel_versions.items) |v| self.allocator.free(v);
        devel_versions.deinit(self.allocator);
    }
    if (self.flags.devel) {
        try checkDevelPackages(self, to_check, &pkgbase_map, &already_outdated, &entries, &devel_versions, populate_hint);
    }

    return .{
        .entries = try entries.toOwnedSlice(self.allocator),
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
pub fn checkDevelPackages(
    self: *BuildContext,
    packages: []const pacman_mod.InstalledPackage,
    pkgbase_map: *const std.StringHashMapUnmanaged([]const u8),
    already_outdated: *std.StringHashMapUnmanaged(void),
    entries: *std.ArrayListUnmanaged(OutdatedEntry),
    devel_versions: *std.ArrayListUnmanaged([]const u8),
    populate_hint: bool,
) !void {
    const ec2 = self.stderr_color;
    const cache = git.resolveCacheRoot(self.cache_root, self.allocator) catch {
        self.err_writer.print("{s}warning:{s} could not determine cache directory for --devel check\n", .{ ec2.yellow, ec2.reset }) catch {};
        return;
    };
    const c_root = cache.path;
    defer git.freeCacheRoot(cache, self.allocator);

    const has_vcs = for (packages) |pkg| {
        if (devel.isVcsPackage(pkg.name)) break true;
    } else false;
    if (has_vcs and !self.flags.quiet) {
        self.err_writer.print("{s}::{s} checking VCS package(s)...\n", .{ ec2.blue, ec2.reset }) catch {};
    }

    // pkgbase -> computed version (null when the check failed), so split
    // packages sharing a pkgbase run the check only once. Versions are owned
    // by `devel_versions`.
    var checked: std.StringHashMapUnmanaged(?[]const u8) = .empty;
    defer checked.deinit(self.allocator);

    for (packages) |pkg| {
        if (!devel.isVcsPackage(pkg.name)) continue;

        const pkgbase = pkgbase_map.get(pkg.name) orelse pkg.name;
        const gop = try checked.getOrPut(self.allocator, pkgbase);
        if (!gop.found_existing) {
            gop.value_ptr.* = null;
            const vcs_result = devel.checkVersion(self.allocator, c_root, pkgbase) catch {
                self.err_writer.print("{s}warning:{s} failed to check VCS version for {s}\n", .{ ec2.yellow, ec2.reset, pkgbase }) catch {};
                continue;
            };
            if (vcs_result) |v| {
                devel_versions.append(self.allocator, v) catch |err| {
                    self.allocator.free(v);
                    return err;
                };
                gop.value_ptr.* = v;
            }
        }

        const version = gop.value_ptr.* orelse continue;
        if (populate_hint) {
            try self.devel_version_hint.put(self.allocator, pkg.name, version);
        }

        if (already_outdated.contains(pkg.name)) {
            for (entries.items) |*entry| {
                if (std.mem.eql(u8, entry.name, pkg.name)) {
                    entry.aur_version = version;
                    break;
                }
            }
        } else if (registry_mod.PackageRegistry.vercmp(pkg.version, version) < 0) {
            try entries.append(self.allocator, .{
                .name = pkg.name,
                .installed_version = pkg.version,
                .aur_version = version,
                .ignored = types.isIgnored(self.flags, pkg.name),
            });
        }
    }
}
