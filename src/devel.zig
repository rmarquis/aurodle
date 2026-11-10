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
pub const VersionCheck = struct {
    /// Full version string (epoch:pkgver-pkgrel). Owned by the caller.
    version: []const u8,
    /// Set when `makepkg --nobuild` completed: src/ then holds fetched,
    /// extracted and prepared sources for `version`, so a build can reuse
    /// them with `--noextract`. The value is sourceStamp() taken right
    /// after; a different stamp later means the build files changed.
    prepared_stamp: ?i96,
};

/// Clone an AUR package if needed, run `makepkg --nobuild` to execute pkgver(),
/// then run `makepkg --printsrcinfo` to get the resulting version string.
///
/// Returns null on failure. Caller owns the returned version string.
pub fn checkVersion(
    allocator: Allocator,
    cache_root: []const u8,
    pkgbase: []const u8,
) !?VersionCheck {
    // Check the version the user last accepted: AUR changes are fetched
    // and reviewed by the build pipeline, not applied here, since makepkg
    // runs the PKGBUILD's code. Only a missing clone is created (there is
    // nothing older to run).
    _ = git.clone(allocator, cache_root, pkgbase) catch {
        return null;
    };

    const clone_dir = try git.cloneDir(allocator, cache_root, pkgbase);
    defer allocator.free(clone_dir);

    // Run makepkg --nobuild to fetch/update VCS sources and execute pkgver().
    // --noextract must NOT be used here: it skips the VCS fetch (git pull),
    // causing pkgver() to report the stale version already on disk.
    // --nodeps is required: makepkg checks dependencies before fetching
    // sources, so missing makedepends would make it exit before pkgver()
    // runs. pkgver() runs before prepare(), so a later failure (e.g. in
    // prepare()) is tolerated: the PKGBUILD's pkgver is already updated.
    const nobuild_result = try utils.runCommandIn(
        allocator,
        &.{ "makepkg", "--nobuild", "--nodeps", "--noconfirm" },
        clone_dir,
    );
    defer nobuild_result.deinit(allocator);

    const version = try srcinfoVersion(allocator, clone_dir) orelse return null;
    const stamp: ?i96 = if (nobuild_result.success())
        sourceStamp(allocator, clone_dir) catch null
    else
        null;
    return .{ .version = version, .prepared_stamp = stamp };
}

/// Fingerprint of the build files in clone_dir: the newest modification
/// time among the files git tracks there (PKGBUILD, patches, install
/// scripts). It changes when a pull or an edit during review touches any
/// of them. Sources fetched or extracted by makepkg are untracked and
/// ignored.
pub fn sourceStamp(allocator: Allocator, clone_dir: []const u8) !i96 {
    const result = try utils.runCommandIn(allocator, &.{ "git", "ls-files", "-z" }, clone_dir);
    defer result.deinit(allocator);
    if (!result.success()) return error.InvalidRepository;

    const io = utils.currentIo();
    const dir = try std.Io.Dir.cwd().openDir(io, clone_dir, .{});
    defer dir.close(io);

    var newest: ?i96 = null;
    var names = std.mem.splitScalar(u8, result.stdout, 0);
    while (names.next()) |name| {
        if (name.len == 0) continue;
        const stat = try dir.statFile(io, name, .{});
        const mtime = stat.mtime.nanoseconds;
        if (newest == null or mtime > newest.?) newest = mtime;
    }
    return newest orelse error.NoTrackedFiles;
}

/// Run `makepkg --printsrcinfo` in clone_dir and return the full version
/// string (epoch:pkgver-pkgrel). For VCS packages this reflects pkgver()
/// only after a prior makepkg run has rewritten the PKGBUILD.
/// Returns null on failure. Caller owns the returned string.
pub fn srcinfoVersion(allocator: Allocator, clone_dir: []const u8) !?[]const u8 {
    const result = try utils.runCommandIn(
        allocator,
        &.{ "makepkg", "--printsrcinfo" },
        clone_dir,
    );
    defer result.deinit(allocator);

    if (!result.success()) return null;
    return parseSrcinfoVersion(allocator, result.stdout) catch null;
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
        const trimmed = std.mem.trimStart(u8, line, " \t");

        if (parseField(trimmed, "pkgver")) |val| {
            pkgver = val;
        } else if (parseField(trimmed, "pkgrel")) |val| {
            pkgrel = val;
        } else if (parseField(trimmed, "epoch")) |val| {
            epoch = val;
        }

        // epoch follows pkgver and pkgrel, so read the whole pkgbase section.
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

test "parseSrcinfoVersion reads epoch written after pkgrel" {
    // makepkg --printsrcinfo emits pkgver, pkgrel, epoch in that order.
    const srcinfo =
        "pkgbase = mesa-git\n" ++
        "\tpkgver = 24.1.0.r1234.g1a2b3c4\n" ++
        "\tpkgrel = 1\n" ++
        "\tepoch = 2\n" ++
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

fn setMtime(dir: std.Io.Dir, name: []const u8, ns: i96) !void {
    const file = try dir.openFile(testing.io, name, .{ .mode = .read_write });
    defer file.close(testing.io);
    try file.setTimestamps(testing.io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = ns } } });
}

test "sourceStamp tracks changes to tracked build files only" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);
    const repo_dir = try git.createTestGitRepo(testing.allocator, tmp_path, "pkg-git");
    defer testing.allocator.free(repo_dir);

    const dir = try std.Io.Dir.cwd().openDir(testing.io, repo_dir, .{});
    defer dir.close(testing.io);

    const before = try sourceStamp(testing.allocator, repo_dir);
    try testing.expectEqual(before, try sourceStamp(testing.allocator, repo_dir));

    // Downloaded sources are untracked and must not change the stamp.
    try dir.writeFile(testing.io, .{ .sub_path = "source.tar.gz", .data = "x" });
    try setMtime(dir, "source.tar.gz", before + 60 * std.time.ns_per_s);
    try testing.expectEqual(before, try sourceStamp(testing.allocator, repo_dir));

    // An edit to the PKGBUILD (pull or review) changes it.
    const later = before + 10 * std.time.ns_per_s;
    try setMtime(dir, "PKGBUILD", later);
    try testing.expectEqual(later, try sourceStamp(testing.allocator, repo_dir));
}
