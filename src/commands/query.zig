const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("../aur.zig");
const alpm = @import("../alpm.zig");
const git = @import("../git.zig");
const devel = @import("../devel.zig");
const pacman_mod = @import("../pacman.zig");
const cmds = @import("../commands.zig");

const Commands = cmds.Commands;
const ExitCode = cmds.ExitCode;
const Flags = cmds.Flags;
const SortField = cmds.SortField;
const OutdatedEntry = cmds.OutdatedEntry;
const getStdout = cmds.getStdout;
const getStderr = cmds.getStderr;
const printError = cmds.printError;
const printErr = cmds.printErr;

// ── Info Command ─────────────────────────────────────────────────────

/// Display detailed info for AUR packages.
pub fn info(self: *Commands, targets: []const []const u8) !ExitCode {
    const packages = self.aur_client.multiInfo(targets) catch |err| {
        try printError(err);
        return .general_error;
    };
    defer self.allocator.free(packages);

    // Check for missing packages
    var found_names: std.StringHashMapUnmanaged(void) = .empty;
    defer found_names.deinit(self.allocator);
    for (packages) |pkg| {
        try found_names.put(self.allocator, pkg.name, {});
    }

    var any_missing = false;
    for (targets) |target| {
        if (!found_names.contains(target)) {
            const stderr = getStderr();
            stderr.print("error: package '{s}' was not found\n", .{target}) catch {};
            any_missing = true;
        }
    }

    const alpm_handle = alpm.Handle.init("/", "/var/lib/pacman/") catch null;
    defer if (alpm_handle) |h| h.deinit();
    const local_db = if (alpm_handle) |h| h.getLocalDb() else null;
    for (packages) |pkg| {
        const installed_version = if (local_db) |db| blk: {
            break :blk if (db.getPackage(pkg.name)) |p| p.getVersion() else null;
        } else null;
        displayInfo(pkg, installed_version);
    }

    return if (any_missing) .general_error else .success;
}

// ── Search Command ───────────────────────────────────────────────────

/// Search AUR and display matching packages.
pub fn search(self: *Commands, query_str: []const u8) !ExitCode {
    const by_field = self.flags.by orelse .name_desc;
    const packages = self.aur_client.search(query_str, by_field) catch |err| {
        try printError(err);
        return .general_error;
    };
    defer self.allocator.free(packages);

    if (packages.len == 0) {
        return .success; // FR-3: exit 0 with no output
    }

    // Sort results
    const sorted = try sortPackages(self.allocator, self.flags, packages);
    defer self.allocator.free(sorted);
    displaySearchResults(sorted);

    return .success;
}

// ── Outdated Command ─────────────────────────────────────────────────

/// List installed AUR packages with newer versions available.
pub fn outdated(self: *Commands, filter: []const []const u8) !ExitCode {
    const pm = self.pacman orelse {
        printErr("error: pacman not initialized\n");
        return .general_error;
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

    if (to_check.len == 0) return .success;

    // Batch query AUR for all foreign package names
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(self.allocator);
    for (to_check) |pkg| try names.append(self.allocator, pkg.name);

    const aur_pkgs = self.aur_client.multiInfo(names.items) catch |err| {
        try printError(err);
        return .general_error;
    };
    defer self.allocator.free(aur_pkgs);

    // Build lookup map
    var aur_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer aur_map.deinit(self.allocator);
    for (aur_pkgs) |pkg| try aur_map.put(self.allocator, pkg.name, pkg.version);

    // Compare versions
    var outdated_list: std.ArrayListUnmanaged(OutdatedEntry) = .empty;
    defer outdated_list.deinit(self.allocator);

    // Track which packages were already flagged as outdated by AUR version
    var already_outdated: std.StringHashMapUnmanaged(void) = .empty;
    defer already_outdated.deinit(self.allocator);

    for (to_check) |pkg| {
        if (aur_map.get(pkg.name)) |aur_ver| {
            if (alpm.vercmp(pkg.version, aur_ver) < 0) {
                try outdated_list.append(self.allocator, .{
                    .name = pkg.name,
                    .installed_version = pkg.version,
                    .aur_version = aur_ver,
                });
                try already_outdated.put(self.allocator, pkg.name, {});
            }
        }
        // Packages not in AUR are silently skipped (might be custom local packages)
    }

    // --devel: check VCS packages via makepkg --nobuild + --printsrcinfo
    if (self.flags.devel) {
        try checkDevelPackages(self, to_check, &already_outdated, &outdated_list);
    }

    if (outdated_list.items.len == 0) {
        if (!self.flags.quiet) {
            getStdout().writeAll("all AUR packages are up to date\n") catch {};
        }
        return .success;
    }

    formatOutdated(outdated_list.items);
    return .success;
}

// ── Devel Check ─────────────────────────────────────────────────────

/// Check VCS packages for upstream updates via makepkg --nobuild.
/// Only checks packages not already flagged as outdated by normal AUR comparison.
fn checkDevelPackages(
    self: *Commands,
    packages: []const pacman_mod.InstalledPackage,
    already_outdated: *std.StringHashMapUnmanaged(void),
    outdated_list: *std.ArrayListUnmanaged(OutdatedEntry),
) !void {
    const c_root = self.cache_root orelse blk: {
        break :blk git.defaultCacheRoot(self.allocator) catch {
            getStderr().writeAll("warning: could not determine cache directory for --devel check\n") catch {};
            return;
        };
    };
    const owns_root = self.cache_root == null;
    defer if (owns_root) self.allocator.free(c_root);

    // Collect allocated version strings for cleanup
    var devel_versions: std.ArrayListUnmanaged(devel.VcsVersionResult) = .empty;
    defer {
        for (devel_versions.items) |v| v.deinit();
        devel_versions.deinit(self.allocator);
    }

    for (packages) |pkg| {
        if (!devel.isVcsPackage(pkg.name)) continue;
        if (already_outdated.contains(pkg.name)) continue;

        if (!self.flags.quiet) {
            getStderr().print(":: checking {s}...\n", .{pkg.name}) catch {};
        }

        const vcs_result = devel.checkVersion(self.allocator, c_root, pkg.name) catch {
            getStderr().print("warning: failed to check VCS version for {s}\n", .{pkg.name}) catch {};
            continue;
        };

        const result = vcs_result orelse continue;
        try devel_versions.append(self.allocator, result);

        if (alpm.vercmp(pkg.version, result.version) < 0) {
            try outdated_list.append(self.allocator, .{
                .name = pkg.name,
                .installed_version = pkg.version,
                .aur_version = result.version,
            });
        }
    }
}

// ── Sorting ──────────────────────────────────────────────────────────

pub fn sortPackages(allocator: Allocator, flags: Flags, packages: []const *aur.Package) ![]const *aur.Package {
    const sorted = try allocator.alloc(*aur.Package, packages.len);
    @memcpy(sorted, @as([]const *aur.Package, packages));

    if (flags.rsort) |field| {
        std.mem.sort(*aur.Package, sorted, SortContext{ .field = field, .reverse = true }, SortContext.lessThan);
    } else {
        const field = flags.sort orelse .popularity;
        const reverse = flags.sort == null; // default popularity is descending
        std.mem.sort(*aur.Package, sorted, SortContext{ .field = field, .reverse = reverse }, SortContext.lessThan);
    }

    return sorted;
}

const SortContext = struct {
    field: SortField,
    reverse: bool,

    fn lessThan(ctx: SortContext, a: *aur.Package, b: *aur.Package) bool {
        if (ctx.reverse) {
            return switch (ctx.field) {
                .name => std.mem.order(u8, b.name, a.name) == .lt,
                .votes => b.votes < a.votes,
                .popularity => b.popularity < a.popularity,
            };
        } else {
            return switch (ctx.field) {
                .name => std.mem.order(u8, a.name, b.name) == .lt,
                .votes => a.votes < b.votes,
                .popularity => a.popularity < b.popularity,
            };
        }
    }
};

// ── Display Helpers ──────────────────────────────────────────────────

fn displayInfo(pkg: *aur.Package, installed_version: ?[]const u8) void {
    const stdout = getStdout();

    const write = struct {
        fn field(writer: anytype, label: []const u8, value: []const u8) void {
            writer.print("{s:<16}: {s}\n", .{ label, value }) catch {};
        }

        fn optionalField(writer: anytype, label: []const u8, value: ?[]const u8) void {
            const v = value orelse return;
            writer.print("{s:<16}: {s}\n", .{ label, v }) catch {};
        }

        fn sliceField(writer: anytype, label: []const u8, values: []const []const u8) void {
            if (values.len == 0) {
                return;
            } else {
                writer.print("{s:<16}:", .{label}) catch {};
                for (values, 0..) |v, i| {
                    if (i > 0) {
                        writer.writeAll("  ") catch {};
                    } else {
                        writer.writeAll(" ") catch {};
                    }
                    writer.writeAll(v) catch {};
                }
                writer.writeAll("\n") catch {};
            }
        }

        fn numField(writer: anytype, label: []const u8, value: anytype) void {
            writer.print("{s:<16}: {d}\n", .{ label, value }) catch {};
        }

        fn floatField(writer: anytype, label: []const u8, value: f64) void {
            writer.print("{s:<16}: {d:.2}\n", .{ label, value }) catch {};
        }

        fn timestampField(writer: anytype, label: []const u8, timestamp: i64) void {
            if (timestamp == 0) return;
            const epoch = std.time.epoch;
            const es = epoch.EpochSeconds{ .secs = @intCast(@as(u64, @intCast(timestamp))) };
            const epoch_day = es.getEpochDay();
            const year_day = epoch_day.calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            const day_secs = es.getDaySeconds();
            writer.print("{s:<16}: {d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\n", .{
                label,
                year_day.year,
                month_day.month.numeric(),
                @as(u6, month_day.day_index) + 1,
                day_secs.getHoursIntoDay(),
                day_secs.getMinutesIntoHour(),
                day_secs.getSecondsIntoMinute(),
            }) catch {};
        }
    };

    write.field(stdout, "Name", pkg.name);
    if (!std.mem.eql(u8, pkg.name, pkg.pkgbase)) {
        write.field(stdout, "Package Base", pkg.pkgbase);
    }
    if (installed_version) |iv| {
        stdout.print("{s:<16}: {s} [installed: {s}]\n", .{ "Version", pkg.version, iv }) catch {};
    } else {
        write.field(stdout, "Version", pkg.version);
    }
    write.optionalField(stdout, "Description", pkg.description);
    write.optionalField(stdout, "URL", pkg.url);
    write.sliceField(stdout, "Licenses", pkg.licenses);
    write.sliceField(stdout, "Groups", pkg.groups);
    write.sliceField(stdout, "Provides", pkg.provides);
    write.sliceField(stdout, "Depends On", pkg.depends);
    write.sliceField(stdout, "Make Deps", pkg.makedepends);
    write.sliceField(stdout, "Check Deps", pkg.checkdepends);
    write.sliceField(stdout, "Optional Deps", pkg.optdepends);
    write.sliceField(stdout, "Conflicts With", pkg.conflicts);
    write.sliceField(stdout, "Replaces", pkg.replaces);
    write.sliceField(stdout, "Keywords", pkg.keywords);
    write.optionalField(stdout, "Maintainer", pkg.maintainer);
    write.optionalField(stdout, "Submitter", pkg.submitter);
    write.sliceField(stdout, "Co-Maintainers", pkg.comaintainers);
    write.numField(stdout, "Votes", pkg.votes);
    write.floatField(stdout, "Popularity", pkg.popularity);
    write.timestampField(stdout, "Submitted", pkg.first_submitted);
    write.timestampField(stdout, "Last Modified", pkg.last_modified);

    if (pkg.out_of_date) |_| {
        write.field(stdout, "Out Of Date", "Yes");
    } else {
        write.field(stdout, "Out Of Date", "No");
    }

    stdout.writeByte('\n') catch {};
}

fn displaySearchResults(packages: []const *aur.Package) void {
    const stdout = getStdout();

    for (packages) |pkg| {
        stdout.print("aur/{s} {s} (+{d} {d:.2})", .{
            pkg.name,
            pkg.version,
            pkg.votes,
            pkg.popularity,
        }) catch {};

        if (pkg.out_of_date != null) {
            stdout.writeAll(" [out-of-date]") catch {};
        }

        stdout.writeByte('\n') catch {};

        if (pkg.description) |desc| {
            stdout.print("    {s}\n", .{desc}) catch {};
        }
    }
}

pub fn formatOutdated(entries: []const OutdatedEntry) void {
    const stdout = getStdout();
    for (entries) |entry| {
        stdout.print("{s} {s} -> {s}\n", .{
            entry.name,
            entry.installed_version,
            entry.aur_version,
        }) catch {};
    }
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeTestPackage(name: []const u8, votes: u32, popularity: f64) aur.Package {
    return .{
        .id = 0,
        .name = name,
        .pkgbase = name,
        .pkgbase_id = 0,
        .version = "1.0-1",
        .description = null,
        .url = null,
        .url_path = null,
        .maintainer = null,
        .submitter = null,
        .votes = votes,
        .popularity = popularity,
        .first_submitted = 0,
        .last_modified = 0,
        .out_of_date = null,
        .depends = &.{},
        .makedepends = &.{},
        .checkdepends = &.{},
        .optdepends = &.{},
        .provides = &.{},
        .conflicts = &.{},
        .replaces = &.{},
        .groups = &.{},
        .keywords = &.{},
        .licenses = &.{},
        .comaintainers = &.{},
    };
}

test "sortPackages: default sort is popularity descending" {
    var pkg_a = makeTestPackage("alpha", 10, 1.0);
    var pkg_b = makeTestPackage("beta", 20, 5.0);
    var pkg_c = makeTestPackage("gamma", 15, 3.0);

    var packages = [_]*aur.Package{ &pkg_a, &pkg_b, &pkg_c };
    const sorted = try sortPackages(testing.allocator, .{}, &packages);
    defer testing.allocator.free(sorted);

    try testing.expectEqualStrings("beta", sorted[0].name);
    try testing.expectEqualStrings("gamma", sorted[1].name);
    try testing.expectEqualStrings("alpha", sorted[2].name);
}

test "sortPackages: --sort name ascending" {
    var pkg_a = makeTestPackage("cherry", 10, 1.0);
    var pkg_b = makeTestPackage("apple", 20, 5.0);
    var pkg_c = makeTestPackage("banana", 15, 3.0);

    var packages = [_]*aur.Package{ &pkg_a, &pkg_b, &pkg_c };
    const sorted = try sortPackages(testing.allocator, .{ .sort = .name }, &packages);
    defer testing.allocator.free(sorted);

    try testing.expectEqualStrings("apple", sorted[0].name);
    try testing.expectEqualStrings("banana", sorted[1].name);
    try testing.expectEqualStrings("cherry", sorted[2].name);
}

test "sortPackages: --sort votes ascending" {
    var pkg_a = makeTestPackage("a", 30, 1.0);
    var pkg_b = makeTestPackage("b", 10, 5.0);
    var pkg_c = makeTestPackage("c", 20, 3.0);

    var packages = [_]*aur.Package{ &pkg_a, &pkg_b, &pkg_c };
    const sorted = try sortPackages(testing.allocator, .{ .sort = .votes }, &packages);
    defer testing.allocator.free(sorted);

    try testing.expectEqual(@as(u32, 10), sorted[0].votes);
    try testing.expectEqual(@as(u32, 20), sorted[1].votes);
    try testing.expectEqual(@as(u32, 30), sorted[2].votes);
}

test "sortPackages: --rsort popularity descending" {
    var pkg_a = makeTestPackage("a", 10, 1.0);
    var pkg_b = makeTestPackage("b", 20, 5.0);
    var pkg_c = makeTestPackage("c", 15, 3.0);

    var packages = [_]*aur.Package{ &pkg_a, &pkg_b, &pkg_c };
    const sorted = try sortPackages(testing.allocator, .{ .rsort = .popularity }, &packages);
    defer testing.allocator.free(sorted);

    try testing.expect(sorted[0].popularity > sorted[1].popularity);
    try testing.expect(sorted[1].popularity > sorted[2].popularity);
}

test "sortPackages: empty input returns empty slice" {
    const packages: []const *aur.Package = &.{};
    const sorted = try sortPackages(testing.allocator, .{}, packages);
    defer testing.allocator.free(sorted);

    try testing.expectEqual(@as(usize, 0), sorted.len);
}

test "SortField.fromString valid fields" {
    try testing.expectEqual(SortField.name, SortField.fromString("name").?);
    try testing.expectEqual(SortField.votes, SortField.fromString("votes").?);
    try testing.expectEqual(SortField.popularity, SortField.fromString("popularity").?);
}

test "SortField.fromString returns null for unknown" {
    try testing.expect(SortField.fromString("invalid") == null);
}

test "outdated returns general_error when pacman not initialized" {
    var cmds2 = Commands.init(testing.allocator, undefined, .{});
    const result = try cmds2.outdated(&.{});
    try testing.expectEqual(ExitCode.general_error, result);
}

test "OutdatedEntry struct has required fields" {
    const entry = OutdatedEntry{
        .name = "foo",
        .installed_version = "1.0-1",
        .aur_version = "2.0-1",
    };
    try testing.expectEqualStrings("foo", entry.name);
    try testing.expectEqualStrings("1.0-1", entry.installed_version);
    try testing.expectEqualStrings("2.0-1", entry.aur_version);
}
