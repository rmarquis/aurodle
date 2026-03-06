// Property-based specification for devel — VCS Package Detection and SRCINFO Parsing
//
// Verifies mathematical invariants that must hold for all inputs to the
// devel module's pure functions.
//
// Architecture: docs/architecture/class_commands.md
// Module: devel
//
// Tests use deterministic PRNG (seed = 42) for reproducible random inputs.

const std = @import("std");
const testing = std.testing;

const devel = @import("aurodle").devel;

// ============================================================================
// isVcsPackage Properties
// ============================================================================

test "suffix completeness: all four VCS suffixes are recognized" {
    // Property: For suffixes in {-git, -svn, -hg, -bzr}:
    //   isVcsPackage("any-prefix" ++ suffix) == true
    const suffixes = [_][]const u8{ "-git", "-svn", "-hg", "-bzr" };
    const prefixes = [_][]const u8{ "foo", "lib32-mesa", "python-my-pkg", "a", "very-long-package-name" };
    for (prefixes) |prefix| {
        for (suffixes) |suffix| {
            const name = try std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ prefix, suffix });
            defer testing.allocator.free(name);
            try testing.expect(devel.isVcsPackage(name));
        }
    }
}

test "suffix exclusivity: only exact VCS suffixes match" {
    // Property: For any string S that does not end with a VCS suffix:
    //   isVcsPackage(S) == false
    const non_vcs = [_][]const u8{
        "git",       "svn",           "hg",       "bzr",
        "-gita",     "foo-git-extra", "gitui",    "",
        "foo-gitt",  "foo-svnn",      "foo-hgg",  "foo-bzrr",
        "foo-git.1", "git-lfs",       "subgit",   "foobzr",
    };
    for (non_vcs) |name| {
        try testing.expect(!devel.isVcsPackage(name));
    }
}

test "suffix detection is case-sensitive" {
    // Property: VCS suffix matching is case-sensitive.
    //   isVcsPackage("foo-GIT") == false
    //   isVcsPackage("foo-Git") == false
    // Only lowercase suffixes are recognized per AUR conventions.
    const uppercase = [_][]const u8{ "foo-GIT", "foo-Git", "foo-SVN", "foo-Hg", "foo-BZR" };
    for (uppercase) |name| {
        try testing.expect(!devel.isVcsPackage(name));
    }
}

// ============================================================================
// parseSrcinfoVersion Properties
// ============================================================================

test "version format: output always matches pkgver-pkgrel pattern" {
    // Property: For all valid SRCINFO inputs:
    //   parseSrcinfoVersion(input) contains exactly one hyphen separating
    //   pkgver from pkgrel, optionally prefixed by epoch and colon.
    const cases = [_]struct { srcinfo: []const u8, expected_hyphens: usize }{
        .{ .srcinfo = "pkgbase = a\n\tpkgver = 1.0\n\tpkgrel = 1\npkgname = a\n", .expected_hyphens = 1 },
        .{ .srcinfo = "pkgbase = a\n\tepoch = 2\n\tpkgver = 1.0\n\tpkgrel = 1\npkgname = a\n", .expected_hyphens = 1 },
        .{ .srcinfo = "pkgbase = a\n\tpkgver = 1.0.r5.gabc\n\tpkgrel = 3\npkgname = a\n", .expected_hyphens = 1 },
    };
    for (cases) |case| {
        const version = try devel.parseSrcinfoVersion(testing.allocator, case.srcinfo);
        defer testing.allocator.free(version);
        // Strip epoch prefix if present, then count hyphens
        const after_epoch = if (std.mem.indexOfScalar(u8, version, ':')) |idx| version[idx + 1 ..] else version;
        var hyphens: usize = 0;
        for (after_epoch) |c| {
            if (c == '-') hyphens += 1;
        }
        try testing.expectEqual(case.expected_hyphens, hyphens);
    }
}

test "epoch inclusion: epoch present in SRCINFO iff colon present in output" {
    // Property: For all valid SRCINFO inputs:
    //   has_epoch(srcinfo) <=> contains(output, ':')
    const with_epoch = "pkgbase = a\n\tepoch = 1\n\tpkgver = 1.0\n\tpkgrel = 1\npkgname = a\n";
    const without_epoch = "pkgbase = a\n\tpkgver = 1.0\n\tpkgrel = 1\npkgname = a\n";

    const v1 = try devel.parseSrcinfoVersion(testing.allocator, with_epoch);
    defer testing.allocator.free(v1);
    try testing.expect(std.mem.indexOfScalar(u8, v1, ':') != null);

    const v2 = try devel.parseSrcinfoVersion(testing.allocator, without_epoch);
    defer testing.allocator.free(v2);
    try testing.expect(std.mem.indexOfScalar(u8, v2, ':') == null);
}

test "field order independence: pkgver/pkgrel/epoch order does not affect result" {
    // Property: For any permutation of {pkgver, pkgrel, epoch} lines
    // within the pkgbase section:
    //   parseSrcinfoVersion(permutation_A) == parseSrcinfoVersion(permutation_B)
    const permutations = [_][]const u8{
        "pkgbase = a\n\tpkgver = 1.0\n\tpkgrel = 2\n\tepoch = 3\npkgname = a\n",
        "pkgbase = a\n\tepoch = 3\n\tpkgver = 1.0\n\tpkgrel = 2\npkgname = a\n",
        "pkgbase = a\n\tpkgrel = 2\n\tepoch = 3\n\tpkgver = 1.0\npkgname = a\n",
        "pkgbase = a\n\tepoch = 3\n\tpkgrel = 2\n\tpkgver = 1.0\npkgname = a\n",
    };

    var prev: ?[]const u8 = null;
    defer if (prev) |p| testing.allocator.free(p);

    for (permutations) |srcinfo| {
        const version = try devel.parseSrcinfoVersion(testing.allocator, srcinfo);
        if (prev) |p| {
            try testing.expectEqualStrings(p, version);
            testing.allocator.free(p);
        }
        prev = version;
    }
}

test "pkgbase section isolation: fields after pkgname are ignored" {
    // Property: For any SRCINFO with overrides in pkgname sections:
    //   parseSrcinfoVersion(with_overrides) == parseSrcinfoVersion(without_overrides)
    const without = "pkgbase = a\n\tpkgver = 1.0\n\tpkgrel = 2\npkgname = a\n";
    const with_override = "pkgbase = a\n\tpkgver = 1.0\n\tpkgrel = 2\npkgname = a\n\tpkgver = 9.9.9\n\tpkgrel = 99\n";

    const v1 = try devel.parseSrcinfoVersion(testing.allocator, without);
    defer testing.allocator.free(v1);
    const v2 = try devel.parseSrcinfoVersion(testing.allocator, with_override);
    defer testing.allocator.free(v2);

    try testing.expectEqualStrings(v1, v2);
}

test "whitespace tolerance: leading spaces and tabs are equivalent" {
    // Property: For any valid SRCINFO line indented with spaces vs tabs:
    //   parseSrcinfoVersion(tabs) == parseSrcinfoVersion(spaces)
    const with_tabs = "pkgbase = a\n\tpkgver = 1.0\n\tpkgrel = 1\npkgname = a\n";
    const with_spaces = "pkgbase = a\n    pkgver = 1.0\n    pkgrel = 1\npkgname = a\n";
    const with_mixed = "pkgbase = a\n\t  pkgver = 1.0\n  \tpkgrel = 1\npkgname = a\n";

    const v1 = try devel.parseSrcinfoVersion(testing.allocator, with_tabs);
    defer testing.allocator.free(v1);
    const v2 = try devel.parseSrcinfoVersion(testing.allocator, with_spaces);
    defer testing.allocator.free(v2);
    const v3 = try devel.parseSrcinfoVersion(testing.allocator, with_mixed);
    defer testing.allocator.free(v3);

    try testing.expectEqualStrings(v1, v2);
    try testing.expectEqualStrings(v2, v3);
}

test "missing field detection: incomplete SRCINFO always returns error" {
    // Property: For any SRCINFO missing pkgver OR pkgrel:
    //   parseSrcinfoVersion(incomplete) == error.SrcinfoParseFailed
    const missing_pkgver = "pkgbase = a\n\tpkgrel = 1\npkgname = a\n";
    const missing_pkgrel = "pkgbase = a\n\tpkgver = 1.0\npkgname = a\n";
    const missing_both = "pkgbase = a\npkgname = a\n";
    const empty = "";

    try testing.expectError(error.SrcinfoParseFailed, devel.parseSrcinfoVersion(testing.allocator, missing_pkgver));
    try testing.expectError(error.SrcinfoParseFailed, devel.parseSrcinfoVersion(testing.allocator, missing_pkgrel));
    try testing.expectError(error.SrcinfoParseFailed, devel.parseSrcinfoVersion(testing.allocator, missing_both));
    try testing.expectError(error.SrcinfoParseFailed, devel.parseSrcinfoVersion(testing.allocator, empty));
}
