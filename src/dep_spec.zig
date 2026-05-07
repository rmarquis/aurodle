const std = @import("std");
const version = @import("version.zig");

/// Parsed dependency spec: name + optional version constraint.
pub const DepSpec = struct {
    name: []const u8,
    constraint: ?version.VersionConstraint = null,
};

/// Parse a dependency string like "pkg>=1.0" into name + constraint.
/// Handles: >=, <=, =, >, <
/// Pure function — no state, no errors.
pub fn parseDep(dep_string: []const u8) DepSpec {
    // Order matters: check two-char operators before single-char
    const operators = [_]struct { str: []const u8, op: version.CmpOp }{
        .{ .str = ">=", .op = .ge },
        .{ .str = "<=", .op = .le },
        .{ .str = "=", .op = .eq },
        .{ .str = ">", .op = .gt },
        .{ .str = "<", .op = .lt },
    };

    for (operators) |entry| {
        if (std.mem.indexOf(u8, dep_string, entry.str)) |pos| {
            return .{
                .name = dep_string[0..pos],
                .constraint = .{
                    .op = entry.op,
                    .version = dep_string[pos + entry.str.len ..],
                },
            };
        }
    }

    return .{ .name = dep_string };
}

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

test "parseDep: bare package name" {
    const spec = parseDep("zlib");
    try testing.expectEqualStrings("zlib", spec.name);
    try testing.expect(spec.constraint == null);
}

test "parseDep: >= constraint" {
    const spec = parseDep("zlib>=1.3");
    try testing.expectEqualStrings("zlib", spec.name);
    try testing.expectEqual(version.CmpOp.ge, spec.constraint.?.op);
    try testing.expectEqualStrings("1.3", spec.constraint.?.version);
}

test "parseDep: <= constraint" {
    const spec = parseDep("pkg<=2.0");
    try testing.expectEqualStrings("pkg", spec.name);
    try testing.expectEqual(version.CmpOp.le, spec.constraint.?.op);
    try testing.expectEqualStrings("2.0", spec.constraint.?.version);
}

test "parseDep: = constraint" {
    const spec = parseDep("pkg=1.0");
    try testing.expectEqualStrings("pkg", spec.name);
    try testing.expectEqual(version.CmpOp.eq, spec.constraint.?.op);
    try testing.expectEqualStrings("1.0", spec.constraint.?.version);
}

test "parseDep: > constraint" {
    const spec = parseDep("pkg>1.0");
    try testing.expectEqualStrings("pkg", spec.name);
    try testing.expectEqual(version.CmpOp.gt, spec.constraint.?.op);
    try testing.expectEqualStrings("1.0", spec.constraint.?.version);
}

test "parseDep: < constraint" {
    const spec = parseDep("pkg<1.0");
    try testing.expectEqualStrings("pkg", spec.name);
    try testing.expectEqual(version.CmpOp.lt, spec.constraint.?.op);
    try testing.expectEqualStrings("1.0", spec.constraint.?.version);
}

test "parseDep: epoch version" {
    const spec = parseDep("glibc>=2.39-1");
    try testing.expectEqualStrings("glibc", spec.name);
    try testing.expectEqualStrings("2.39-1", spec.constraint.?.version);
}

test "parseDep: VCS version with hyphen" {
    const spec = parseDep("linux>=6.7.arch1-1");
    try testing.expectEqualStrings("linux", spec.name);
    try testing.expectEqualStrings("6.7.arch1-1", spec.constraint.?.version);
}
