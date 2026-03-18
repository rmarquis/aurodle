const std = @import("std");

/// Terminal color styling — provides ANSI escape codes when output is a TTY,
/// empty strings otherwise. Respects NO_COLOR and TERM=dumb.
pub const Style = struct {
    red: []const u8,
    green: []const u8,
    yellow: []const u8,
    blue: []const u8,
    magenta: []const u8,
    bold: []const u8,
    reset: []const u8,

    pub const enabled: Style = .{
        .red = "\x1b[1;31m",
        .green = "\x1b[1;32m",
        .yellow = "\x1b[1;33m",
        .blue = "\x1b[1;34m",
        .magenta = "\x1b[1;35m",
        .bold = "\x1b[1m",
        .reset = "\x1b[0m",
    };

    pub const disabled: Style = .{
        .red = "",
        .green = "",
        .yellow = "",
        .blue = "",
        .magenta = "",
        .bold = "",
        .reset = "",
    };

    pub fn detect(fd: std.posix.fd_t) Style {
        if (std.posix.getenv("NO_COLOR")) |_| return disabled;
        if (std.posix.getenv("TERM")) |term| {
            if (std.mem.eql(u8, term, "dumb")) return disabled;
        }
        return if (std.posix.isatty(fd)) enabled else disabled;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "enabled style has non-empty escape codes" {
    const s = Style.enabled;
    try testing.expect(s.red.len > 0);
    try testing.expect(s.green.len > 0);
    try testing.expect(s.yellow.len > 0);
    try testing.expect(s.blue.len > 0);
    try testing.expect(s.bold.len > 0);
    try testing.expect(s.reset.len > 0);
}

test "disabled style has empty strings" {
    const s = Style.disabled;
    try testing.expectEqualStrings("", s.red);
    try testing.expectEqualStrings("", s.green);
    try testing.expectEqualStrings("", s.yellow);
    try testing.expectEqualStrings("", s.blue);
    try testing.expectEqualStrings("", s.bold);
    try testing.expectEqualStrings("", s.reset);
}

test "detect returns disabled for non-TTY fd" {
    // In the test runner, fds are piped (not TTYs)
    const s = Style.detect(std.posix.STDOUT_FILENO);
    try testing.expectEqualStrings("", s.red);
}
