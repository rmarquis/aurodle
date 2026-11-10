const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("../aur.zig");
const color = @import("../color.zig");
const utils = @import("../utils.zig");
const plan_mod = @import("../plan.zig");

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
    /// Packages to skip. Borrowed: main.run owns the storage, which
    /// outlives every command, so Flags can be copied freely.
    ignore: []const []const u8 = &.{},
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
    /// Not built because an AUR dependency failed; exit_code is meaningless.
    skipped: bool = false,
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

/// Output policy: writing to the terminal never fails a command. A closed
/// pipe or a full disk must not abort a build or an install halfway, so
/// both writers drop output they cannot write instead of returning an
/// error.
pub const ErrWriter = struct {
    discard: bool = false,

    pub fn print(self: ErrWriter, comptime fmt: []const u8, args: anytype) void {
        if (self.discard) return;
        // Keep stderr messages in order with buffered stdout.
        utils.flushStdout();
        std.debug.print(fmt, args);
    }
};

/// Handle to the process-wide buffered stdout (utils.stdout()). See
/// ErrWriter for the error policy.
pub const StdWriter = struct {
    pub fn print(_: StdWriter, comptime fmt: []const u8, args: anytype) void {
        utils.stdout().print(fmt, args) catch {};
    }

    pub fn writeAll(_: StdWriter, bytes: []const u8) void {
        utils.stdout().writeAll(bytes) catch {};
    }

    pub fn writeByte(_: StdWriter, byte: u8) void {
        utils.stdout().writeByte(byte) catch {};
    }

    pub fn writeByteNTimes(_: StdWriter, byte: u8, n: usize) void {
        utils.stdout().splatByteAll(byte, n) catch {};
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

/// `unresolved` is the solver's explanation for UnresolvableDependency.
pub fn handleResolveError(err: anyerror, unresolved: ?plan_mod.Unresolved, err_writer: ErrWriter, ec: color.Style) ExitCode {
    if (err == error.CircularDependency) {
        err_writer.print("{s}error:{s} circular dependency detected\n", .{ ec.red, ec.reset });
    } else if (err == error.UnresolvableDependency) {
        printUnresolved(unresolved, err_writer, ec);
    } else if (err == error.IgnoredDependency) {
        err_writer.print("{s}error:{s} a required dependency is in the ignore list\n", .{ ec.red, ec.reset });
    } else if (err == error.NetworkError or err == error.RateLimited or
        err == error.ApiError or err == error.MalformedResponse)
    {
        printError(err, err_writer, ec);
    } else {
        err_writer.print("{s}error:{s} dependency resolution failed: {}\n", .{ ec.red, ec.reset, err });
    }
    return .general_error;
}

fn printUnresolved(unresolved: ?plan_mod.Unresolved, err_writer: ErrWriter, ec: color.Style) void {
    const u = unresolved orelse {
        err_writer.print("{s}error:{s} unresolvable dependency\n", .{ ec.red, ec.reset });
        return;
    };
    const parent = u.required_by orelse {
        err_writer.print("{s}error:{s} target not found: {s}\n", .{ ec.red, ec.reset, u.dep });
        return;
    };
    if (u.found_version) |v| {
        err_writer.print("{s}error:{s} unable to satisfy dependency '{s}' required by {s} (found {s})\n", .{ ec.red, ec.reset, u.dep, parent, v });
    } else {
        err_writer.print("{s}error:{s} unable to satisfy dependency '{s}' required by {s}\n", .{ ec.red, ec.reset, u.dep, parent });
    }
}

pub fn printError(err: anytype, err_writer: ErrWriter, ec: color.Style) void {
    switch (err) {
        error.NetworkError => err_writer.print("{s}error:{s} failed to connect to AUR\n", .{ ec.red, ec.reset }),
        error.RateLimited => err_writer.print("{s}error:{s} AUR rate limit exceeded. Wait and retry.\n", .{ ec.red, ec.reset }),
        error.ApiError => err_writer.print("{s}error:{s} AUR returned an error\n", .{ ec.red, ec.reset }),
        error.MalformedResponse => err_writer.print("{s}error:{s} received malformed response from AUR\n", .{ ec.red, ec.reset }),
        else => err_writer.print("{s}error:{s} {}\n", .{ ec.red, ec.reset, err }),
    }
}

// ── Target Filtering ─────────────────────────────────────────────────────

pub fn isIgnored(flags: Flags, name: []const u8) bool {
    for (flags.ignore) |ignored| {
        if (std.mem.eql(u8, ignored, name)) return true;
    }
    return false;
}

pub fn filterIgnored(
    stdout_color: color.Style,
    stderr_color: color.Style,
    err_writer: ErrWriter,
    flags: Flags,
    targets: []const []const u8,
    buf: [][]const u8,
) []const []const u8 {
    if (flags.ignore.len == 0) return targets;

    const ec = stderr_color;
    var count: usize = 0;
    for (targets) |target| {
        if (isIgnored(flags, target)) {
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "{s} is in IgnorePkg. Install anyway?", .{target}) catch target;
            const install = utils.promptYesNoStyled(stdout_color, msg) catch false;
            if (install) {
                buf[count] = target;
                count += 1;
            } else {
                err_writer.print(
                    "{s}warning:{s} skipping target: {s}\n",
                    .{ ec.yellow, ec.reset, target },
                );
            }
        } else {
            buf[count] = target;
            count += 1;
        }
    }
    return buf[0..count];
}

// ── Tests ────────────────────────────────────────────────────────────────

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

test "handleResolveError returns general_error for CircularDependency" {
    const result = handleResolveError(error.CircularDependency, null, null_err_writer, color.Style.disabled);
    try testing.expectEqual(ExitCode.general_error, result);
}

test "handleResolveError returns general_error for UnresolvableDependency" {
    const result = handleResolveError(error.UnresolvableDependency, null, null_err_writer, color.Style.disabled);
    try testing.expectEqual(ExitCode.general_error, result);
}

test "handleResolveError returns general_error for other errors" {
    const result = handleResolveError(error.OutOfMemory, null, null_err_writer, color.Style.disabled);
    try testing.expectEqual(ExitCode.general_error, result);
}
