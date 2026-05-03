const std = @import("std");
const registry_mod = @import("../registry.zig");
const devel = @import("../devel.zig");
const pacman_mod = @import("../pacman.zig");
const git = @import("../git.zig");
const cmds = @import("context.zig");

const Commands = cmds.Commands;
const OutdatedEntry = cmds.OutdatedEntry;
const OutdatedList = cmds.OutdatedList;
const printError = cmds.printError;

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
pub fn collectOutdated(self: *Commands, filter: []const []const u8, populate_hint: bool) !?OutdatedList {
    const ec = self.stderr_color;
    const pm = self.pacman orelse {
        self.err_writer.print("{s}error:{s} pacman not initialized\n", .{ ec.red, ec.reset }) catch {};
        return null;
    };

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

    // Build lookup map
    var aur_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer aur_map.deinit(self.allocator);
    for (aur_pkgs) |pkg| try aur_map.put(self.allocator, pkg.name, pkg.version);

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
                    .ignored = self.isIgnored(pkg.name),
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
        try checkDevelPackages(self, to_check, &already_outdated, &entries, &devel_versions, populate_hint);
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
pub fn checkDevelPackages(
    self: *Commands,
    packages: []const pacman_mod.InstalledPackage,
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

    for (packages) |pkg| {
        if (!devel.isVcsPackage(pkg.name)) continue;

        const vcs_result = devel.checkVersion(self.allocator, c_root, pkg.name) catch {
            self.err_writer.print("{s}warning:{s} failed to check VCS version for {s}\n", .{ ec2.yellow, ec2.reset, pkg.name }) catch {};
            continue;
        };

        const version = vcs_result orelse continue;
        try devel_versions.append(self.allocator, version);
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
                .ignored = self.isIgnored(pkg.name),
            });
        }
    }
}
