const std = @import("std");

/// How a frontend should present a message from the core.
pub const Level = enum {
    /// Progress (`:: creating chroot…`).
    info,
    warning,
    err,
    /// Output captured from a child process, shown verbatim.
    output,
};

/// Lets core modules tell the user something without knowing how it is
/// shown. Messages carry no styling and no level prefix (`error:`); the
/// frontend adds both. `ctx` is passed back to `report_fn` unchanged.
pub const Reporter = struct {
    ctx: ?*anyopaque = null,
    report_fn: *const fn (ctx: ?*anyopaque, level: Level, message: []const u8) void,

    /// Drops every message. For tests and callers that report errors
    /// some other way.
    pub const silent: Reporter = .{ .report_fn = discard };

    pub fn message(self: Reporter, level: Level, msg: []const u8) void {
        self.report_fn(self.ctx, level, msg);
    }

    /// Format and report a message. A message longer than the buffer is
    /// truncated rather than dropped.
    pub fn print(self: Reporter, level: Level, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print(fmt, args) catch {};
        self.message(level, w.buffered());
    }

    fn discard(_: ?*anyopaque, _: Level, _: []const u8) void {}
};

const testing = std.testing;

const Recorder = struct {
    level: Level = .info,
    buf: [2048]u8 = undefined,
    len: usize = 0,

    fn record(ctx: ?*anyopaque, level: Level, msg: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.level = level;
        @memcpy(self.buf[0..msg.len], msg);
        self.len = msg.len;
    }

    fn reporter(self: *Recorder) Reporter {
        return .{ .ctx = self, .report_fn = record };
    }
};

test "print formats the message and passes the level" {
    var r: Recorder = .{};
    r.reporter().print(.warning, "{s} not found", .{"foo"});
    try testing.expectEqual(Level.warning, r.level);
    try testing.expectEqualStrings("foo not found", r.buf[0..r.len]);
}

test "print truncates a message longer than its buffer" {
    var r: Recorder = .{};
    const long: [1500]u8 = @splat('x');
    r.reporter().print(.err, "{s}", .{&long});
    try testing.expectEqual(@as(usize, 1024), r.len);
}

test "silent drops messages" {
    Reporter.silent.print(.err, "{s}", .{"ignored"});
}
