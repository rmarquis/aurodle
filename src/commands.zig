const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("aur.zig");

pub const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
    build_failed = 3,
    signal_killed = 128,
};

pub const Flags = struct {
    help: bool = false,
    noconfirm: bool = false,
    noshow: bool = false,
    needed: bool = false,
    rebuild: bool = false,
    quiet: bool = false,
    raw: bool = false,
    asdeps: bool = false,
    asexplicit: bool = false,
    devel: bool = false,
    by: ?aur.SearchField = null,
    sort: ?SortField = null,
    rsort: ?SortField = null,
    format_str: ?[]const u8 = null,
};

pub const SortField = enum {
    name,
    votes,
    popularity,

    pub fn fromString(s: []const u8) ?SortField {
        const map = std.StaticStringMap(SortField).initComptime(.{
            .{ "name", .name },
            .{ "votes", .votes },
            .{ "popularity", .popularity },
        });
        return map.get(s);
    }
};

pub const Commands = struct {
    allocator: Allocator,
    aur_client: *aur.Client,
    flags: Flags,

    pub fn init(allocator: Allocator, aur_client: *aur.Client, flags: Flags) Commands {
        return .{
            .allocator = allocator,
            .aur_client = aur_client,
            .flags = flags,
        };
    }

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

        const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
        var any_missing = false;
        for (targets) |target| {
            if (!found_names.contains(target)) {
                const w = stderr.deprecatedWriter();
                w.print("error: package '{s}' was not found\n", .{target}) catch {};
                any_missing = true;
            }
        }

        for (packages) |pkg| {
            self.displayInfo(pkg);
        }

        return if (any_missing) .general_error else .success;
    }

    /// Search AUR and display matching packages.
    pub fn search(self: *Commands, query: []const u8) !ExitCode {
        const by_field = self.flags.by orelse .name_desc;
        const packages = self.aur_client.search(query, by_field) catch |err| {
            try printError(err);
            return .general_error;
        };
        defer self.allocator.free(packages);

        if (packages.len == 0) {
            return .success; // FR-3: exit 0 with no output
        }

        // Sort results
        const sorted = try self.sortPackages(packages);
        defer self.allocator.free(sorted);
        self.displaySearchResults(sorted);

        return .success;
    }

    fn sortPackages(self: *Commands, packages: []const *aur.Package) ![]const *aur.Package {
        // Make a mutable copy for sorting
        const sorted = try self.allocator.alloc(*aur.Package, packages.len);
        @memcpy(sorted, @as([]const *aur.Package, packages));

        if (self.flags.rsort) |field| {
            std.mem.sort(*aur.Package, sorted, SortContext{ .field = field, .reverse = true }, SortContext.lessThan);
        } else {
            const field = self.flags.sort orelse .popularity;
            const reverse = self.flags.sort == null; // default popularity is descending
            std.mem.sort(*aur.Package, sorted, SortContext{ .field = field, .reverse = reverse }, SortContext.lessThan);
        }

        return sorted;
    }

    const SortContext = struct {
        field: SortField,
        reverse: bool,

        fn lessThan(ctx: SortContext, a: *aur.Package, b: *aur.Package) bool {
            if (ctx.reverse) {
                // Reverse: swap a and b
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

    fn displayInfo(self: *Commands, pkg: *aur.Package) void {
        _ = self;
        const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
        const w = stdout.deprecatedWriter();

        const write = struct {
            fn field(writer: anytype, label: []const u8, value: []const u8) void {
                writer.print("{s:<18}: {s}\n", .{ label, value }) catch {};
            }

            fn optionalField(writer: anytype, label: []const u8, value: ?[]const u8) void {
                writer.print("{s:<18}: {s}\n", .{ label, value orelse "None" }) catch {};
            }

            fn sliceField(writer: anytype, label: []const u8, values: []const []const u8) void {
                if (values.len == 0) {
                    writer.print("{s:<18}: None\n", .{label}) catch {};
                } else {
                    for (values, 0..) |v, i| {
                        if (i == 0) {
                            writer.print("{s:<18}: {s}\n", .{ label, v }) catch {};
                        } else {
                            writer.print("{s:<18}  {s}\n", .{ "", v }) catch {};
                        }
                    }
                }
            }

            fn numField(writer: anytype, label: []const u8, value: anytype) void {
                writer.print("{s:<18}: {d}\n", .{ label, value }) catch {};
            }

            fn floatField(writer: anytype, label: []const u8, value: f64) void {
                writer.print("{s:<18}: {d:.2}\n", .{ label, value }) catch {};
            }
        };

        write.field(w, "Name", pkg.name);
        write.field(w, "Package Base", pkg.pkgbase);
        write.field(w, "Version", pkg.version);
        write.optionalField(w, "Description", pkg.description);
        write.optionalField(w, "URL", pkg.url);
        write.sliceField(w, "Licenses", pkg.licenses);
        write.sliceField(w, "Groups", pkg.groups);
        write.sliceField(w, "Provides", pkg.provides);
        write.sliceField(w, "Depends On", pkg.depends);
        write.sliceField(w, "Make Deps", pkg.makedepends);
        write.sliceField(w, "Check Deps", pkg.checkdepends);
        write.sliceField(w, "Optional Deps", pkg.optdepends);
        write.sliceField(w, "Conflicts With", pkg.conflicts);
        write.sliceField(w, "Replaces", pkg.replaces);
        write.sliceField(w, "Keywords", pkg.keywords);
        write.optionalField(w, "Maintainer", pkg.maintainer);
        write.optionalField(w, "Submitter", pkg.submitter);
        write.sliceField(w, "Co-Maintainers", pkg.comaintainers);
        write.numField(w, "Votes", pkg.votes);
        write.floatField(w, "Popularity", pkg.popularity);

        if (pkg.out_of_date) |_| {
            write.field(w, "Out Of Date", "Yes");
        } else {
            write.field(w, "Out Of Date", "No");
        }

        w.writeByte('\n') catch {};
    }

    fn displaySearchResults(self: *Commands, packages: []const *aur.Package) void {
        _ = self;
        const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
        const w = stdout.deprecatedWriter();

        for (packages) |pkg| {
            // Format: aur/name version (+votes popularity)
            w.print("aur/{s} {s} (+{d} {d:.2})", .{
                pkg.name,
                pkg.version,
                pkg.votes,
                pkg.popularity,
            }) catch {};

            if (pkg.out_of_date != null) {
                w.writeAll(" [out-of-date]") catch {};
            }

            w.writeByte('\n') catch {};

            // Indented description
            if (pkg.description) |desc| {
                w.print("    {s}\n", .{desc}) catch {};
            }
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

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
    var cmds = Commands.init(std.testing.allocator, undefined, .{});
    const sorted = try cmds.sortPackages(&packages);
    defer std.testing.allocator.free(sorted);

    // Default: popularity descending (5.0 > 3.0 > 1.0)
    try std.testing.expectEqualStrings("beta", sorted[0].name);
    try std.testing.expectEqualStrings("gamma", sorted[1].name);
    try std.testing.expectEqualStrings("alpha", sorted[2].name);
}

test "sortPackages: --sort name ascending" {
    var pkg_a = makeTestPackage("cherry", 10, 1.0);
    var pkg_b = makeTestPackage("apple", 20, 5.0);
    var pkg_c = makeTestPackage("banana", 15, 3.0);

    var packages = [_]*aur.Package{ &pkg_a, &pkg_b, &pkg_c };
    var cmds = Commands.init(std.testing.allocator, undefined, .{ .sort = .name });
    const sorted = try cmds.sortPackages(&packages);
    defer std.testing.allocator.free(sorted);

    try std.testing.expectEqualStrings("apple", sorted[0].name);
    try std.testing.expectEqualStrings("banana", sorted[1].name);
    try std.testing.expectEqualStrings("cherry", sorted[2].name);
}

test "sortPackages: --sort votes ascending" {
    var pkg_a = makeTestPackage("a", 30, 1.0);
    var pkg_b = makeTestPackage("b", 10, 5.0);
    var pkg_c = makeTestPackage("c", 20, 3.0);

    var packages = [_]*aur.Package{ &pkg_a, &pkg_b, &pkg_c };
    var cmds = Commands.init(std.testing.allocator, undefined, .{ .sort = .votes });
    const sorted = try cmds.sortPackages(&packages);
    defer std.testing.allocator.free(sorted);

    try std.testing.expectEqual(@as(u32, 10), sorted[0].votes);
    try std.testing.expectEqual(@as(u32, 20), sorted[1].votes);
    try std.testing.expectEqual(@as(u32, 30), sorted[2].votes);
}

test "sortPackages: --rsort popularity descending" {
    var pkg_a = makeTestPackage("a", 10, 1.0);
    var pkg_b = makeTestPackage("b", 20, 5.0);
    var pkg_c = makeTestPackage("c", 15, 3.0);

    var packages = [_]*aur.Package{ &pkg_a, &pkg_b, &pkg_c };
    var cmds = Commands.init(std.testing.allocator, undefined, .{ .rsort = .popularity });
    const sorted = try cmds.sortPackages(&packages);
    defer std.testing.allocator.free(sorted);

    try std.testing.expect(sorted[0].popularity > sorted[1].popularity);
    try std.testing.expect(sorted[1].popularity > sorted[2].popularity);
}

test "sortPackages: empty input returns empty slice" {
    const packages: []const *aur.Package = &.{};
    var cmds = Commands.init(std.testing.allocator, undefined, .{});
    const sorted = try cmds.sortPackages(packages);
    defer std.testing.allocator.free(sorted);

    try std.testing.expectEqual(@as(usize, 0), sorted.len);
}

test "SortField.fromString valid fields" {
    try std.testing.expectEqual(SortField.name, SortField.fromString("name").?);
    try std.testing.expectEqual(SortField.votes, SortField.fromString("votes").?);
    try std.testing.expectEqual(SortField.popularity, SortField.fromString("popularity").?);
}

test "SortField.fromString returns null for unknown" {
    try std.testing.expect(SortField.fromString("invalid") == null);
}

fn printError(err: anytype) !void {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    const w = stderr.deprecatedWriter();

    switch (err) {
        error.NetworkError => try w.writeAll("error: failed to connect to AUR\n"),
        error.RateLimited => try w.writeAll("error: AUR rate limit exceeded. Wait and retry.\n"),
        error.ApiError => try w.writeAll("error: AUR returned an error\n"),
        error.MalformedResponse => try w.writeAll("error: received malformed response from AUR\n"),
        else => try w.print("error: {}\n", .{err}),
    }
}
