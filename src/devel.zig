const std = @import("std");
const Allocator = std.mem.Allocator;
const git = @import("git.zig");
const utils = @import("utils.zig");

/// VCS package suffixes that indicate development/version-controlled packages.
const vcs_suffixes: []const []const u8 = &.{ "-git", "-svn", "-hg", "-bzr" };

/// Check if a package name ends with a VCS suffix (-git, -svn, -hg, -bzr).
pub fn isVcsPackage(name: []const u8) bool {
    for (vcs_suffixes) |suffix| {
        if (std.mem.endsWith(u8, name, suffix)) return true;
    }
    return false;
}

/// Result of a VCS version check.
pub const VcsVersionResult = struct {
    version: []const u8,
    allocator: Allocator,

    pub fn deinit(self: VcsVersionResult) void {
        self.allocator.free(self.version);
    }
};

pub const VcsCheckError = error{
    CloneFailed,
    NoBuildFailed,
    SrcinfoParseFailed,
};

/// Clone/update an AUR package, run `makepkg --nobuild` to execute pkgver(),
/// then run `makepkg --printsrcinfo` to get the resulting version string.
///
/// Returns the full version string (epoch:pkgver-pkgrel) or null on failure.
pub fn checkVersion(
    allocator: Allocator,
    cache_root: []const u8,
    pkgbase: []const u8,
) !?VcsVersionResult {
    // Ensure clone exists and is up to date
    _ = git.cloneOrUpdate(allocator, cache_root, pkgbase) catch {
        return null;
    };

    const clone_dir = try git.cloneDir(allocator, cache_root, pkgbase);
    defer allocator.free(clone_dir);

    // Run makepkg --nobuild to fetch sources and execute pkgver()
    const nobuild_result = try utils.runCommandIn(
        allocator,
        &.{ "makepkg", "--nobuild", "--noconfirm", "--noextract" },
        clone_dir,
    );
    defer nobuild_result.deinit(allocator);

    // --nobuild may exit non-zero (e.g. missing deps), but pkgver() still ran
    // if sources were already extracted. We try --printsrcinfo regardless,
    // but if it fails too, we try without --noextract.
    if (nobuild_result.exit_code != 0) {
        // Retry without --noextract to allow full source preparation
        const retry_result = try utils.runCommandIn(
            allocator,
            &.{ "makepkg", "--nobuild", "--noconfirm" },
            clone_dir,
        );
        defer retry_result.deinit(allocator);
        // Still proceed to printsrcinfo even if this fails
    }

    // Run makepkg --printsrcinfo to get the updated version
    const srcinfo_result = try utils.runCommandIn(
        allocator,
        &.{ "makepkg", "--printsrcinfo" },
        clone_dir,
    );
    defer srcinfo_result.deinit(allocator);

    if (srcinfo_result.exit_code != 0) return null;

    // Parse the version from SRCINFO output
    const version = parseSrcinfoVersion(allocator, srcinfo_result.stdout) catch {
        return null;
    };

    return .{
        .version = version,
        .allocator = allocator,
    };
}

/// Parse a full version string (epoch:pkgver-pkgrel) from SRCINFO content.
///
/// SRCINFO format:
///   pkgbase = name
///   \tpkgver = 1.2.3.r45.gabcdef
///   \tpkgrel = 1
///   \tepoch = 2
///
/// Returns "epoch:pkgver-pkgrel" or "pkgver-pkgrel" if no epoch.
pub fn parseSrcinfoVersion(allocator: Allocator, srcinfo: []const u8) ![]const u8 {
    var pkgver: ?[]const u8 = null;
    var pkgrel: ?[]const u8 = null;
    var epoch: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, srcinfo, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        if (parseField(trimmed, "pkgver")) |val| {
            pkgver = val;
        } else if (parseField(trimmed, "pkgrel")) |val| {
            pkgrel = val;
        } else if (parseField(trimmed, "epoch")) |val| {
            epoch = val;
        }

        // Stop at the first pkgname section (fields after that are per-package overrides)
        if (std.mem.startsWith(u8, trimmed, "pkgname")) break;
    }

    const ver = pkgver orelse return error.SrcinfoParseFailed;
    const rel = pkgrel orelse return error.SrcinfoParseFailed;

    if (epoch) |e| {
        return std.fmt.allocPrint(allocator, "{s}:{s}-{s}", .{ e, ver, rel });
    } else {
        return std.fmt.allocPrint(allocator, "{s}-{s}", .{ ver, rel });
    }
}

/// Parse "key = value" from a trimmed SRCINFO line.
fn parseField(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    const rest = line[key.len..];
    // Expect " = " after key name
    if (!std.mem.startsWith(u8, rest, " = ")) return null;
    return rest[3..];
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "isVcsPackage detects -git suffix" {
    try testing.expect(isVcsPackage("neovim-git"));
    try testing.expect(isVcsPackage("linux-git"));
}

test "isVcsPackage detects -svn, -hg, -bzr suffixes" {
    try testing.expect(isVcsPackage("wine-svn"));
    try testing.expect(isVcsPackage("mercurial-tool-hg"));
    try testing.expect(isVcsPackage("launchpad-client-bzr"));
}

test "isVcsPackage rejects non-VCS packages" {
    try testing.expect(!isVcsPackage("neovim"));
    try testing.expect(!isVcsPackage("git"));
    try testing.expect(!isVcsPackage("git-lfs"));
    try testing.expect(!isVcsPackage("gitui"));
    try testing.expect(!isVcsPackage("python-pygit2"));
}

test "parseSrcinfoVersion basic version" {
    const srcinfo =
        "pkgbase = neovim-git\n" ++
        "\tpkgver = 0.10.0.r123.gabcdef1\n" ++
        "\tpkgrel = 1\n" ++
        "\tpkgdesc = Fork of Vim\n" ++
        "\turl = https://neovim.io\n" ++
        "pkgname = neovim-git\n";

    const version = try parseSrcinfoVersion(testing.allocator, srcinfo);
    defer testing.allocator.free(version);
    try testing.expectEqualStrings("0.10.0.r123.gabcdef1-1", version);
}

test "parseSrcinfoVersion with epoch" {
    const srcinfo =
        "pkgbase = mesa-git\n" ++
        "\tepoch = 2\n" ++
        "\tpkgver = 24.1.0.r1234.g1a2b3c4\n" ++
        "\tpkgrel = 1\n" ++
        "pkgname = mesa-git\n";

    const version = try parseSrcinfoVersion(testing.allocator, srcinfo);
    defer testing.allocator.free(version);
    try testing.expectEqualStrings("2:24.1.0.r1234.g1a2b3c4-1", version);
}

test "parseSrcinfoVersion fails on missing pkgver" {
    const srcinfo =
        "pkgbase = broken\n" ++
        "\tpkgrel = 1\n" ++
        "pkgname = broken\n";
    try testing.expectError(error.SrcinfoParseFailed, parseSrcinfoVersion(testing.allocator, srcinfo));
}

test "parseSrcinfoVersion fails on missing pkgrel" {
    const srcinfo =
        "pkgbase = broken\n" ++
        "\tpkgver = 1.0\n" ++
        "pkgname = broken\n";
    try testing.expectError(error.SrcinfoParseFailed, parseSrcinfoVersion(testing.allocator, srcinfo));
}

test "parseSrcinfoVersion only reads pkgbase section" {
    const srcinfo =
        "pkgbase = split-pkg-git\n" ++
        "\tpkgver = 1.0.r5.gabc\n" ++
        "\tpkgrel = 2\n" ++
        "pkgname = split-pkg-git\n" ++
        "\tpkgver = 9.9.9\n";
    // The pkgver=9.9.9 in the pkgname section should be ignored
    const version = try parseSrcinfoVersion(testing.allocator, srcinfo);
    defer testing.allocator.free(version);
    try testing.expectEqualStrings("1.0.r5.gabc-2", version);
}

test "parseField matches key-value pairs" {
    try testing.expectEqualStrings("1.0", parseField("pkgver = 1.0", "pkgver").?);
    try testing.expectEqualStrings("2", parseField("epoch = 2", "epoch").?);
    try testing.expect(parseField("pkgver = 1.0", "pkgrel") == null);
    try testing.expect(parseField("pkgversion = 1.0", "pkgver") == null);
}
