// Property-based specification for alpm.zig — Version Comparison
//
// Verifies mathematical invariants of version comparison that must
// hold for ALL inputs. These properties can never be violated regardless
// of the version strings involved.
//
// Architecture: docs/architecture/class_alpm_pacman.md
// Module: alpm.vercmp
//
// Uses deterministic PRNG with fixed seed for reproducibility.

const std = @import("std");
const testing = std.testing;

const alpm = @import("aurodle").alpm;

// ============================================================================
// Generators
// ============================================================================

/// Generates random version strings following Arch Linux version format:
/// [epoch:]upstream_version[-pkgrel]
/// Returns a stack buffer with the generated string and its length.
const VersionBuf = struct {
    buf: [64]u8,
    len: usize,

    fn slice(self: *const VersionBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

fn randomVersion(random: std.Random) VersionBuf {
    var result: VersionBuf = .{ .buf = undefined, .len = 0 };
    var pos: usize = 0;

    // Optional epoch (20% chance)
    if (random.intRangeAtMost(u8, 0, 4) == 0) {
        const epoch = random.intRangeAtMost(u8, 1, 9);
        result.buf[pos] = '0' + epoch;
        pos += 1;
        result.buf[pos] = ':';
        pos += 1;
    }

    // Major.minor.patch version (1-3 parts)
    const parts = random.intRangeAtMost(u8, 1, 3);
    var i: u8 = 0;
    while (i < parts) : (i += 1) {
        if (i > 0) {
            result.buf[pos] = '.';
            pos += 1;
        }
        const num = random.intRangeAtMost(u16, 0, 999);
        const written = std.fmt.bufPrint(result.buf[pos..], "{d}", .{num}) catch break;
        pos += written.len;
    }

    // Optional pkgrel (60% chance)
    if (random.intRangeAtMost(u8, 0, 4) < 3) {
        result.buf[pos] = '-';
        pos += 1;
        const rel = random.intRangeAtMost(u8, 1, 20);
        const written = std.fmt.bufPrint(result.buf[pos..], "{d}", .{rel}) catch {
            result.len = pos;
            return result;
        };
        pos += written.len;
    }

    result.len = pos;
    return result;
}

// ============================================================================
// Antisymmetry Property
// ============================================================================

test "antisymmetry: vercmp(a,b) and vercmp(b,a) have opposite signs" {
    // Property: For all versions a, b:
    //   sign(vercmp(a, b)) == -sign(vercmp(b, a))
    //
    // If a < b, then b > a. If a == b, then b == a.
    // This is a fundamental property of any valid comparison function.

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    for (0..100) |_| {
        const a = randomVersion(random);
        const b = randomVersion(random);

        const ab = alpm.vercmp(a.slice(), b.slice());
        const ba = alpm.vercmp(b.slice(), a.slice());

        if (ab > 0) {
            try testing.expect(ba < 0);
        } else if (ab < 0) {
            try testing.expect(ba > 0);
        } else {
            try testing.expectEqual(@as(i32, 0), ba);
        }
    }
}

// ============================================================================
// Reflexivity Property
// ============================================================================

test "reflexivity: vercmp(a, a) == 0 for all versions" {
    // Property: For all versions a:
    //   vercmp(a, a) == 0
    //
    // Every version is equal to itself.

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    for (0..100) |_| {
        const a = randomVersion(random);
        const result = alpm.vercmp(a.slice(), a.slice());
        try testing.expectEqual(@as(i32, 0), result);
    }
}

// ============================================================================
// Transitivity Property
// ============================================================================

test "transitivity: if a < b and b < c then a < c" {
    // Property: For all versions a, b, c:
    //   if vercmp(a, b) < 0 and vercmp(b, c) < 0
    //   then vercmp(a, c) < 0
    //
    // The ordering is transitive — a fundamental requirement for
    // topological sorting to produce correct results.

    const triples = [_][3][]const u8{
        .{ "1.0", "2.0", "3.0" },
        .{ "1.0-1", "1.0-2", "1.0-3" },
        .{ "1:1.0", "1:2.0", "2:0.1" },
        .{ "0.9", "1.0", "1.0.1" },
        .{ "1.0alpha", "1.0beta", "1.0" },
    };

    for (triples) |t| {
        const ab = alpm.vercmp(t[0], t[1]);
        const bc = alpm.vercmp(t[1], t[2]);
        const ac = alpm.vercmp(t[0], t[2]);
        try testing.expect(ab < 0);
        try testing.expect(bc < 0);
        try testing.expect(ac < 0);
    }
}

// ============================================================================
// Epoch Dominance Property
// ============================================================================

test "epoch dominance: higher epoch always wins regardless of version" {
    // Property: For all upstream versions v1, v2:
    //   vercmp("2:v1", "1:v2") > 0
    //
    // Epoch completely overrides version comparison.

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    for (0..100) |_| {
        // Generate versions without epoch
        var v1 = randomVersion(random);
        var v2 = randomVersion(random);

        // Strip any epoch that randomVersion may have added
        const v1_str = if (std.mem.indexOfScalar(u8, v1.slice(), ':')) |idx| v1.slice()[idx + 1 ..] else v1.slice();
        const v2_str = if (std.mem.indexOfScalar(u8, v2.slice(), ':')) |idx| v2.slice()[idx + 1 ..] else v2.slice();

        // Build "2:v1" and "1:v2"
        var high_buf: [68]u8 = undefined;
        var low_buf: [68]u8 = undefined;
        const high = std.fmt.bufPrint(&high_buf, "2:{s}", .{v1_str}) catch continue;
        const low = std.fmt.bufPrint(&low_buf, "1:{s}", .{v2_str}) catch continue;

        _ = &v1;
        _ = &v2;

        const result = alpm.vercmp(high, low);
        try testing.expect(result > 0);
    }
}

// ============================================================================
// Pkgrel Secondary Property
// ============================================================================

test "pkgrel is secondary to upstream version" {
    // Property: For all pkgrel values r1, r2:
    //   vercmp("1.0-r1", "2.0-r2") < 0
    //
    // Upstream version always takes priority over pkgrel.

    const pairs = [_][2][]const u8{
        .{ "1.0-999", "2.0-1" },
        .{ "1.99-100", "2.0-1" },
        .{ "0.1-50", "1.0-1" },
    };
    for (pairs) |p| {
        try testing.expect(alpm.vercmp(p[0], p[1]) < 0);
    }
}

// ============================================================================
// Determinism Property
// ============================================================================

test "determinism: vercmp returns same result for same inputs" {
    // Property: For all versions a, b:
    //   vercmp(a, b) called N times always returns the same value
    //
    // Version comparison must be a pure function.

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    for (0..50) |_| {
        const a = randomVersion(random);
        const b = randomVersion(random);

        const first = alpm.vercmp(a.slice(), b.slice());
        const second = alpm.vercmp(a.slice(), b.slice());
        const third = alpm.vercmp(a.slice(), b.slice());
        try testing.expectEqual(first, second);
        try testing.expectEqual(second, third);
    }
}
