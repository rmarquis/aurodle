const std = @import("std");
const alpm = @import("alpm.zig");

/// Version constraint operator.
pub const CmpOp = enum {
    eq,
    ge,
    le,
    gt,
    lt,
};

/// A version constraint: operator + version string.
pub const VersionConstraint = struct {
    op: CmpOp,
    version: []const u8,
};

/// Check if `version` satisfies `constraint` using libalpm's vercmp.
pub fn checkVersion(version: []const u8, constraint: VersionConstraint) bool {
    const cmp = alpm.vercmp(version, constraint.version);
    return switch (constraint.op) {
        .eq => cmp == 0,
        .ge => cmp >= 0,
        .le => cmp <= 0,
        .gt => cmp > 0,
        .lt => cmp < 0,
    };
}

test {
    std.testing.refAllDecls(@This());
}

// ── Pure Logic Tests (no system dependencies) ────────────────────────────

test "checkVersion: eq operator" {
    try std.testing.expect(checkVersion("1.0.0", .{ .op = .eq, .version = "1.0.0" }));
    try std.testing.expect(!checkVersion("1.0.0", .{ .op = .eq, .version = "2.0.0" }));
}

test "checkVersion: ge operator" {
    try std.testing.expect(checkVersion("2.0.0", .{ .op = .ge, .version = "1.0.0" }));
    try std.testing.expect(checkVersion("1.0.0", .{ .op = .ge, .version = "1.0.0" }));
    try std.testing.expect(!checkVersion("0.9.0", .{ .op = .ge, .version = "1.0.0" }));
}

test "checkVersion: le operator" {
    try std.testing.expect(checkVersion("1.0.0", .{ .op = .le, .version = "2.0.0" }));
    try std.testing.expect(checkVersion("1.0.0", .{ .op = .le, .version = "1.0.0" }));
    try std.testing.expect(!checkVersion("2.0.0", .{ .op = .le, .version = "1.0.0" }));
}

test "checkVersion: gt operator" {
    try std.testing.expect(checkVersion("2.0.0", .{ .op = .gt, .version = "1.0.0" }));
    try std.testing.expect(!checkVersion("1.0.0", .{ .op = .gt, .version = "1.0.0" }));
}

test "checkVersion: lt operator" {
    try std.testing.expect(checkVersion("1.0.0", .{ .op = .lt, .version = "2.0.0" }));
    try std.testing.expect(!checkVersion("1.0.0", .{ .op = .lt, .version = "1.0.0" }));
}

test "checkVersion: with epochs and pkgrel" {
    try std.testing.expect(checkVersion("1:1.0", .{ .op = .gt, .version = "2.0" }));
    try std.testing.expect(checkVersion("1.0-2", .{ .op = .gt, .version = "1.0-1" }));
    try std.testing.expect(!checkVersion("1.0-1", .{ .op = .ge, .version = "2.0-1" }));
}
