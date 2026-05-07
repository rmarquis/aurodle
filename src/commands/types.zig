const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("../aur.zig");
const color = @import("../color.zig");

// ── Exit Codes ───────────────────────────────────────────────────────────

pub const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
    build_failed = 3,
    signal_killed = 128,
};

// ── Flags ────────────────────────────────────────────────────────────────

pub const Flags = struct {
    help: bool = false,
    noconfirm: bool = false,
    noshow: bool = false,
    needed: bool = false,
    rebuild: bool = false,
    quiet: bool = false,
    asdeps: bool = false,
    asexplicit: bool = false,
    devel: bool = false,
    all: bool = false,
    recurse: bool = false,
    chroot: bool = false,
    by: ?aur.SearchField = null,
    sort: ?SortField = null,
    rsort: ?SortField = null,
    ignore: []const []const u8 = &.{},
    ignore_buf: [64][]const u8 = undefined,

    /// Re-anchor the ignore slice to point into our own ignore_buf.
    /// Must be called after any struct copy (Zig copies the slice pointer
    /// verbatim, leaving it pointing at the source struct's buffer).
    pub fn reanchorIgnore(self: *Flags) void {
        self.ignore = self.ignore_buf[0..self.ignore.len];
    }
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

// ── Build Result Types ───────────────────────────────────────────────────

pub const FailedBuild = struct {
    pkgbase: []const u8,
    exit_code: u32,
};

pub const BuildResult = struct {
    succeeded: []const []const u8,
    failed: []const FailedBuild,
    signal_aborted: bool,
    built_pkg_basenames: []const []const u8,

    pub fn deinit(self: BuildResult, allocator: Allocator) void {
        for (self.built_pkg_basenames) |b| allocator.free(b);
        allocator.free(self.built_pkg_basenames);
        allocator.free(self.succeeded);
        allocator.free(self.failed);
    }
};

// ── Outdated Types ───────────────────────────────────────────────────────

pub const OutdatedEntry = struct {
    name: []const u8,
    installed_version: []const u8,
    aur_version: []const u8,
    ignored: bool = false,
};

/// Result of `outdated.collectOutdated`.  Shared by `outdated` and `upgrade`.
///
/// `entries` contains one row per package that's behind its AUR (or devel)
/// version; each carries the `ignored` flag so callers can decide whether to
/// display, filter, or warn.  `devel_versions` owns the strings produced by
/// the --devel pass (borrowed from by `entries[i].aur_version` for VCS-only
/// entries and by `devel_version_hint` when populated).  `total_checked` is
/// the number of installed foreign packages compared against the AUR —
/// zero means "nothing to compare" (distinct from "compared but none outdated").
pub const OutdatedList = struct {
    entries: []OutdatedEntry,
    devel_versions: [][]const u8,
    total_checked: usize,

    pub fn deinit(self: OutdatedList, allocator: Allocator) void {
        allocator.free(self.entries);
        for (self.devel_versions) |v| allocator.free(v);
        allocator.free(self.devel_versions);
    }
};

// ── I/O Types ────────────────────────────────────────────────────────────

pub const ErrWriter = struct {
    discard: bool = false,

    pub fn print(self: ErrWriter, comptime fmt: []const u8, args: anytype) error{WriteFailed}!void {
        if (self.discard) return;
        std.debug.print(fmt, args);
    }
};

pub const StdWriter = struct {
    pub fn print(self: StdWriter, comptime fmt: []const u8, args: anytype) error{WriteFailed}!void {
        _ = self;
        var buf: [8192]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return error.WriteFailed;
        _ = std.os.linux.write(std.posix.STDOUT_FILENO, s.ptr, s.len);
    }

    pub fn writeAll(self: StdWriter, bytes: []const u8) error{WriteFailed}!void {
        _ = self;
        if (bytes.len == 0) return;
        _ = std.os.linux.write(std.posix.STDOUT_FILENO, bytes.ptr, bytes.len);
    }

    pub fn writeByte(self: StdWriter, byte: u8) error{WriteFailed}!void {
        _ = self;
        _ = std.os.linux.write(std.posix.STDOUT_FILENO, &.{byte}, 1);
    }

    pub fn writeByteNTimes(self: StdWriter, byte: u8, n: usize) error{WriteFailed}!void {
        _ = self;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            _ = std.os.linux.write(std.posix.STDOUT_FILENO, &.{byte}, 1);
        }
    }
};

// ── I/O Helpers ──────────────────────────────────────────────────────────

pub fn getStdout() StdWriter {
    return .{};
}

pub fn defaultErrWriter() ErrWriter {
    return .{};
}

pub const null_err_writer: ErrWriter = .{ .discard = true };

// ── Error Helpers ────────────────────────────────────────────────────────

pub fn handleResolveError(err: anyerror, err_writer: ErrWriter, ec: color.Style) ExitCode {
    if (err == error.CircularDependency) {
        err_writer.print("{s}error:{s} circular dependency detected\n", .{ ec.red, ec.reset }) catch {};
    } else if (err == error.UnresolvableDependency) {
        err_writer.print("{s}error:{s} unresolvable dependency\n", .{ ec.red, ec.reset }) catch {};
    } else if (err == error.IgnoredDependency) {
        err_writer.print("{s}error:{s} a required dependency is in the ignore list\n", .{ ec.red, ec.reset }) catch {};
    } else {
        err_writer.print("{s}error:{s} dependency resolution failed: {}\n", .{ ec.red, ec.reset, err }) catch {};
    }
    return .general_error;
}

pub fn printError(err: anytype, err_writer: ErrWriter, ec: color.Style) !void {
    switch (err) {
        error.NetworkError => try err_writer.print("{s}error:{s} failed to connect to AUR\n", .{ ec.red, ec.reset }),
        error.RateLimited => try err_writer.print("{s}error:{s} AUR rate limit exceeded. Wait and retry.\n", .{ ec.red, ec.reset }),
        error.ApiError => try err_writer.print("{s}error:{s} AUR returned an error\n", .{ ec.red, ec.reset }),
        error.MalformedResponse => try err_writer.print("{s}error:{s} received malformed response from AUR\n", .{ ec.red, ec.reset }),
        else => try err_writer.print("{s}error:{s} {}\n", .{ ec.red, ec.reset, err }),
    }
}

// ── Tests ────────────────────────────────────────────────────────────────

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

test "handleResolveError returns general_error for CircularDependency" {
    const result = handleResolveError(error.CircularDependency, null_err_writer, color.Style.disabled);
    try testing.expectEqual(ExitCode.general_error, result);
}

test "handleResolveError returns general_error for UnresolvableDependency" {
    const result = handleResolveError(error.UnresolvableDependency, null_err_writer, color.Style.disabled);
    try testing.expectEqual(ExitCode.general_error, result);
}

test "handleResolveError returns general_error for other errors" {
    const result = handleResolveError(error.OutOfMemory, null_err_writer, color.Style.disabled);
    try testing.expectEqual(ExitCode.general_error, result);
}
