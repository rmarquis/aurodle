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
