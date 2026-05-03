const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("../aur.zig");
const registry_mod = @import("../registry.zig");
const devel = @import("../devel.zig");
const pacman_mod = @import("../pacman.zig");
const cmds = @import("context.zig");
const outdated_mod = @import("outdated.zig");
const color = @import("../color.zig");

const Commands = cmds.Commands;
const ExitCode = cmds.ExitCode;
const Flags = cmds.Flags;
const SortField = cmds.SortField;
const OutdatedEntry = cmds.OutdatedEntry;
const OutdatedList = cmds.OutdatedList;
const getStdout = cmds.getStdout;
const printError = cmds.printError;

pub const collectOutdated = outdated_mod.collectOutdated;
pub const checkDevelPackages = outdated_mod.checkDevelPackages;

// ── Info Command ─────────────────────────────────────────────────────

/// Display detailed info for AUR packages.
pub fn info(self: *Commands, targets: []const []const u8) !ExitCode {
    const packages = self.aur_client.multiInfo(targets) catch |err| {
        try printError(err, self.err_writer, self.stderr_color);
        return .general_error;
    };
    defer self.allocator.free(packages);

    // Check for missing packages
    var found_names: std.StringHashMapUnmanaged(void) = .empty;
    defer found_names.deinit(self.allocator);
    for (packages) |pkg| {
        try found_names.put(self.allocator, pkg.name, {});
    }

    const ec = self.stderr_color;
    var any_missing = false;
    for (targets) |target| {
        if (!found_names.contains(target)) {
            self.err_writer.print("{s}error:{s} package '{s}' was not found\n", .{ ec.red, ec.reset, target }) catch {};
            any_missing = true;
        }
    }

    const c = self.stdout_color;
    for (packages) |pkg| {
        const installed_version = if (self.pacman) |pm| pm.installedVersion(pkg.name) else null;
        displayInfo(pkg, installed_version, c);
    }

    return if (any_missing) .general_error else .success;
}

// ── Search Command ───────────────────────────────────────────────────

/// Search AUR and display matching packages.
/// When multiple terms are given, the AUR is queried with the first term and
/// remaining terms are filtered client-side (intersection / AND semantics).
pub fn search(self: *Commands, terms: []const []const u8) !ExitCode {
    const by_field = self.flags.by orelse .name_desc;
    const packages = self.aur_client.search(terms[0], by_field) catch |err| {
        try printError(err, self.err_writer, self.stderr_color);
        return .general_error;
    };
    defer self.allocator.free(packages);

    // Filter client-side so every additional term must appear in name or description.
    var filtered: std.ArrayList(*aur.Package) = .empty;
    defer filtered.deinit(self.allocator);
    outer: for (packages) |pkg| {
        for (terms[1..]) |term| {
            const in_name = std.ascii.indexOfIgnoreCase(pkg.name, term) != null;
            const in_desc = if (pkg.description) |d| std.ascii.indexOfIgnoreCase(d, term) != null else false;
            if (!in_name and !in_desc) continue :outer;
        }
        try filtered.append(self.allocator, pkg);
    }

    if (filtered.items.len == 0) {
        return .success; // FR-3: exit 0 with no output
    }

    // Sort results
    const sorted = try sortPackages(self.allocator, self.flags, filtered.items);
    defer self.allocator.free(sorted);

    displaySearchResults(sorted, self.stdout_color, self.pacman, self.flags.quiet);

    return .success;
}

// ── Outdated Command ─────────────────────────────────────────────────

/// List installed AUR packages with newer versions available.
pub fn outdated(self: *Commands, filter: []const []const u8) !ExitCode {
    const result = (try outdated_mod.collectOutdated(self, filter, false)) orelse return .general_error;
    defer result.deinit(self.allocator);

    // Preserve historical exit semantics:
    // - nothing to check (no foreign pkgs matched) → success
    // - checked but none outdated → general_error
    if (result.total_checked == 0) return .success;
    if (result.entries.len == 0) return .general_error;

    formatOutdated(result.entries, self.stdout_color, self.flags.quiet);
    return .success;
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

fn displayInfo(pkg: *aur.Package, installed_version: ?[]const u8, c: color.Style) void {
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

    stdout.print("{s:<16}: {s}aur{s}\n", .{ "Repository", c.magenta, c.reset }) catch {};
    write.field(stdout, "Name", pkg.name);
    if (!std.mem.eql(u8, pkg.name, pkg.pkgbase)) {
        write.field(stdout, "Package Base", pkg.pkgbase);
    }
    const is_ood = pkg.out_of_date != null;
    const ver_color = if (is_ood) c.red else c.green;
    if (installed_version) |iv| {
        if (std.mem.eql(u8, iv, pkg.version)) {
            stdout.print("{s:<16}: {s}{s}{s} [installed]\n", .{ "Version", ver_color, pkg.version, c.reset }) catch {};
        } else {
            stdout.print("{s:<16}: {s}{s}{s} [installed: {s}{s}{s}]\n", .{ "Version", ver_color, pkg.version, c.reset, c.green, iv, c.reset }) catch {};
        }
    } else {
        stdout.print("{s:<16}: {s}{s}{s}\n", .{ "Version", ver_color, pkg.version, c.reset }) catch {};
    }
    write.optionalField(stdout, "Description", pkg.description);
    if (pkg.url) |url| {
        stdout.print("{s:<16}: {s}{s}{s}\n", .{ "URL", c.cyan, url, c.reset }) catch {};
    }
    stdout.print("{s:<16}: {s}https://aur.archlinux.org/packages/{s}{s}\n", .{ "AUR Page", c.cyan, pkg.name, c.reset }) catch {};
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
        stdout.print("{s:<16}: {s}Yes{s}\n", .{ "Out Of Date", c.red, c.reset }) catch {};
    } else {
        write.field(stdout, "Out Of Date", "No");
    }

    stdout.writeByte('\n') catch {};
}

fn displaySearchResults(packages: []const *aur.Package, c: color.Style, pm: ?*pacman_mod.Pacman, quiet: bool) void {
    const stdout = getStdout();

    for (packages) |pkg| {
        if (quiet) {
            stdout.print("{s}\n", .{pkg.name}) catch {};
            continue;
        }

        const ver_color = if (pkg.out_of_date != null) c.red else c.green;
        stdout.print("{s}aur/{s}{s} {s}{s}{s} (+{d}, {d:.2})", .{
            c.magenta,
            c.reset,
            pkg.name,
            ver_color,
            pkg.version,
            c.reset,
            pkg.votes,
            pkg.popularity,
        }) catch {};

        if (pm) |pacman| {
            if (pacman.installedVersion(pkg.name)) |iv| {
                if (std.mem.eql(u8, iv, pkg.version)) {
                    stdout.writeAll(" [installed]") catch {};
                } else {
                    stdout.print(" [installed: {s}{s}{s}]", .{ c.green, iv, c.reset }) catch {};
                }
            }
        }

        stdout.writeByte('\n') catch {};

        if (pkg.description) |desc| {
            stdout.print("    {s}\n", .{desc}) catch {};
        }
    }
}

pub fn formatOutdated(entries: []const OutdatedEntry, c: color.Style, quiet: bool) void {
    const stdout = getStdout();
    for (entries) |entry| {
        if (quiet) {
            stdout.print("{s}\n", .{entry.name}) catch {};
        } else if (entry.ignored) {
            stdout.print("{s} {s}{s}{s} -> {s}{s}{s} [ignored]\n", .{
                entry.name,
                c.red,
                entry.installed_version,
                c.reset,
                c.green,
                entry.aur_version,
                c.reset,
            }) catch {};
        } else {
            stdout.print("{s} {s}{s}{s} -> {s}{s}{s}\n", .{
                entry.name,
                c.red,
                entry.installed_version,
                c.reset,
                c.green,
                entry.aur_version,
                c.reset,
            }) catch {};
        }
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
    cmds2.err_writer = std.io.null_writer.any();
    cmds2.stderr_color = color.Style.disabled;
    const result = try outdated(&cmds2, &.{});
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
