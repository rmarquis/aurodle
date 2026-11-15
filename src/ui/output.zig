//! Terminal output shared by the frontends: never-failing stdout and
//! stderr writers, and the stderr Reporter for core messages.

const std = @import("std");
const core = @import("core");
const utils = core.utils;
const report = core.report;
const color = @import("color.zig");

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

/// A core Reporter that prints to stderr with pacman-style prefixes
/// colored with `style`. `style` must outlive the reporter.
pub fn stderrReporter(style: *const color.Style) report.Reporter {
    return .{ .ctx = @constCast(style), .report_fn = reportToStderr };
}

fn reportToStderr(ctx: ?*anyopaque, level: report.Level, msg: []const u8) void {
    const ec: *const color.Style = @ptrCast(@alignCast(ctx.?));
    const w = defaultErrWriter();
    switch (level) {
        .info => w.print("{s}::{s} {s}\n", .{ ec.blue, ec.reset, msg }),
        .warning => w.print("{s}warning:{s} {s}\n", .{ ec.yellow, ec.reset, msg }),
        .err => w.print("{s}error:{s} {s}\n", .{ ec.red, ec.reset, msg }),
        .output => w.print("{s}", .{msg}),
    }
}

test {
    std.testing.refAllDecls(@This());
}
