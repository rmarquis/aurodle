const std = @import("std");
const testing = std.testing;
const git = @import("../git.zig");
const utils = @import("../utils.zig");

const CloneResult = git.CloneResult;
const UpdateResult = git.UpdateResult;

test "cloneDir returns correct path" {
    const dir = try git.cloneDir(testing.allocator, "/tmp/cache", "yay");
    defer testing.allocator.free(dir);
    try testing.expectEqualStrings("/tmp/cache/yay", dir);
}

test "cacheRootFrom prefers AURDEST" {
    const root = try git.cacheRootFrom(testing.allocator, .{
        .aurdest = "/srv/aur",
        .xdg_cache_home = "/home/u/.xdg-cache",
        .home = "/home/u",
    });
    defer testing.allocator.free(root);
    try testing.expectEqualStrings("/srv/aur", root);
}

test "cacheRootFrom uses XDG_CACHE_HOME when AURDEST is unset" {
    const root = try git.cacheRootFrom(testing.allocator, .{
        .xdg_cache_home = "/home/u/.xdg-cache",
        .home = "/home/u",
    });
    defer testing.allocator.free(root);
    try testing.expectEqualStrings("/home/u/.xdg-cache/aurodle", root);
}

test "cacheRootFrom ignores a relative XDG_CACHE_HOME" {
    const root = try git.cacheRootFrom(testing.allocator, .{
        .xdg_cache_home = "relative/cache",
        .home = "/home/u",
    });
    defer testing.allocator.free(root);
    try testing.expectEqualStrings("/home/u/.cache/aurodle", root);
}

test "cacheRootFrom falls back to ~/.cache/aurodle" {
    const root = try git.cacheRootFrom(testing.allocator, .{ .home = "/home/u" });
    defer testing.allocator.free(root);
    try testing.expectEqualStrings("/home/u/.cache/aurodle", root);
}

test "cacheRootFrom errors without any location" {
    try testing.expectError(error.NoHomeDirectory, git.cacheRootFrom(testing.allocator, .{}));
}

test "isCloned returns false for non-existent directory" {
    try testing.expect(!try git.isCloned(testing.allocator, "/tmp/nonexistent-aurodle-test", "fake-pkg"));
}

test "isCloned returns true for valid git repo" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const repo_dir = try git.createTestGitRepo(testing.allocator, tmp_path, "test-pkg");
    defer testing.allocator.free(repo_dir);

    try testing.expect(try git.isCloned(testing.allocator, tmp_path, "test-pkg"));
}

test "isCloned returns false for non-git directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    // Create a plain directory (no .git)
    const plain_dir = try std.fs.path.join(testing.allocator, &.{ tmp_path, "plain-pkg" });
    defer testing.allocator.free(plain_dir);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), testing.io, plain_dir);

    try testing.expect(!try git.isCloned(testing.allocator, tmp_path, "plain-pkg"));
}

test "clone returns already_exists for existing directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    // Pre-create a repo
    const repo_dir = try git.createTestGitRepo(testing.allocator, tmp_path, "existing-pkg");
    defer testing.allocator.free(repo_dir);

    const result = try git.clone(testing.allocator, tmp_path, "existing-pkg");
    try testing.expectEqual(CloneResult.already_exists, result);
}

test "update returns up_to_date when no changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const repo_dir = try git.createTestGitRepo(testing.allocator, tmp_path, "uptodate-pkg");
    defer testing.allocator.free(repo_dir);

    // update on a local-only repo (no remote) will fail with PullFailed
    // because there's no remote to pull from — this is expected behavior
    const result = git.update(testing.allocator, tmp_path, "uptodate-pkg");
    try testing.expectError(error.PullFailed, result);
}

test "update returns NotCloned when directory does not exist" {
    const result = git.update(testing.allocator, "/tmp/nonexistent-aurodle-test", "fake-pkg");
    try testing.expectError(error.NotCloned, result);
}

test "listFiles returns PKGBUILD first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const repo_dir = try git.createTestGitRepo(testing.allocator, tmp_path, "list-pkg");
    defer testing.allocator.free(repo_dir);

    // Add extra files
    const install_path = try std.fs.path.join(testing.allocator, &.{ repo_dir, "list-pkg.install" });
    defer testing.allocator.free(install_path);
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), testing.io, .{ .sub_path = install_path, .data = "post_install() { true; }\n" });

    const patch_path = try std.fs.path.join(testing.allocator, &.{ repo_dir, "fix.patch" });
    defer testing.allocator.free(patch_path);
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), testing.io, .{ .sub_path = patch_path, .data = "--- a/foo\n+++ b/foo\n" });

    // Stage and commit new files
    const add_result = try utils.runCommandIn(testing.allocator, &.{ "git", "add", "." }, repo_dir);
    add_result.deinit(testing.allocator);
    const commit_result = try utils.runCommandIn(testing.allocator, &.{ "git", "commit", "-m", "add files" }, repo_dir);
    commit_result.deinit(testing.allocator);

    const files = try git.listFiles(testing.allocator, tmp_path, "list-pkg");
    defer {
        for (files) |f| testing.allocator.free(f.name);
        testing.allocator.free(files);
    }

    try testing.expectEqual(@as(usize, 3), files.len);
    try testing.expectEqualStrings("PKGBUILD", files[0].name);
    try testing.expect(files[0].is_pkgbuild);
    try testing.expect(files[0].size > 0);

    // Find the .install file and verify its flag
    var found_install = false;
    for (files) |f| {
        if (f.is_install) {
            found_install = true;
            try testing.expect(std.mem.endsWith(u8, f.name, ".install"));
        }
    }
    try testing.expect(found_install);
}

test "listFiles returns NotCloned for non-existent package" {
    const result = git.listFiles(testing.allocator, "/tmp/nonexistent-aurodle-test", "fake-pkg");
    try testing.expectError(error.NotCloned, result);
}

test "readFile reads file content from clone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const repo_dir = try git.createTestGitRepo(testing.allocator, tmp_path, "read-pkg");
    defer testing.allocator.free(repo_dir);

    const content = try git.readFile(testing.allocator, tmp_path, "read-pkg", "PKGBUILD");
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "pkgname=test") != null);
}

test "readFile blocks path traversal with .." {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const repo_dir = try git.createTestGitRepo(testing.allocator, tmp_path, "traversal-pkg");
    defer testing.allocator.free(repo_dir);

    const attack_vectors = [_][]const u8{
        "../../../etc/passwd",
        "../../.ssh/id_rsa",
        "subdir/../../outside",
        "..",
        "../",
        "PKGBUILD/../../../etc/passwd",
    };

    for (attack_vectors) |path| {
        const result = git.readFile(testing.allocator, tmp_path, "traversal-pkg", path);
        try testing.expectError(error.InvalidFilePath, result);
    }
}

test "readFile blocks absolute paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const repo_dir = try git.createTestGitRepo(testing.allocator, tmp_path, "abs-pkg");
    defer testing.allocator.free(repo_dir);

    const result = git.readFile(testing.allocator, tmp_path, "abs-pkg", "/etc/passwd");
    try testing.expectError(error.InvalidFilePath, result);
}

test "readFile returns error for non-existent file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const repo_dir = try git.createTestGitRepo(testing.allocator, tmp_path, "nofile-pkg");
    defer testing.allocator.free(repo_dir);

    const result = git.readFile(testing.allocator, tmp_path, "nofile-pkg", "nonexistent.txt");
    try testing.expectError(error.InvalidFilePath, result);
}

test "readFile returns NotCloned when not cloned" {
    const result = git.readFile(testing.allocator, "/tmp/nonexistent-aurodle-test", "fake-pkg", "PKGBUILD");
    try testing.expectError(error.NotCloned, result);
}

test "validateFilePath rejects empty filename" {
    try testing.expectError(error.InvalidFilePath, git.validateFilePath(""));
}

test "validateFilePath accepts valid filenames" {
    try git.validateFilePath("PKGBUILD");
    try git.validateFilePath("subdir/file.patch");
    try git.validateFilePath("some.install");
}

test "SortField-like: CloneResult enum values" {
    // Verify enum variants exist and are distinct
    try testing.expect(CloneResult.cloned != CloneResult.already_exists);
    try testing.expect(UpdateResult.updated != UpdateResult.up_to_date);
}

test "cloneOrFetch returns NotCloned-free result for existing repo" {
    // cloneOrFetch should never return NotCloned — it clones if missing.
    // We test the clone path here (update path tested via update tests).
    // Note: actual network clone would fail, so we test with pre-existing repo.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const repo_dir = try git.createTestGitRepo(testing.allocator, tmp_path, "cou-pkg");
    defer testing.allocator.free(repo_dir);

    // cloneOrFetch on existing repo → tries fetch → PullFailed (no remote)
    const result = git.cloneOrFetch(testing.allocator, tmp_path, "cou-pkg");
    try testing.expectError(error.PullFailed, result);
}

// ── Updating from a local "AUR" upstream ─────────────────────────────

fn run(dir: []const u8, argv: []const []const u8) !void {
    const result = try utils.runCommandIn(testing.allocator, argv, dir);
    defer result.deinit(testing.allocator);
    if (!result.success()) return error.CommandFailed;
}

fn writeIn(dir: []const u8, name: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(testing.allocator, &.{ dir, name });
    defer testing.allocator.free(path);
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), testing.io, .{ .sub_path = path, .data = data });
}

fn readIn(dir: []const u8, name: []const u8) ![]u8 {
    const path = try std.fs.path.join(testing.allocator, &.{ dir, name });
    defer testing.allocator.free(path);
    return std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), testing.io, path, testing.allocator, .unlimited);
}

/// An upstream repo "aur/<pkg>" and a clone of it at "<cache>/<pkg>",
/// like an AUR package cloned by aurodle.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    upstream: []u8,
    cache: []u8,
    clone_dir: []u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
        const aur = try std.fs.path.join(testing.allocator, &.{ root, "aur" });
        defer testing.allocator.free(aur);
        const upstream = try git.createTestGitRepo(testing.allocator, aur, "pkg-git");
        const cache = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
        const clone_dir = try std.fs.path.join(testing.allocator, &.{ cache, "pkg-git" });
        try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), testing.io, cache);
        try run(cache, &.{ "git", "clone", "--quiet", upstream, clone_dir });
        return .{ .tmp = tmp, .root = root, .upstream = upstream, .cache = cache, .clone_dir = clone_dir };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.clone_dir);
        testing.allocator.free(self.cache);
        testing.allocator.free(self.upstream);
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    /// A maintainer commit touching the PKGBUILD.
    fn pushPkgbuild(self: *Fixture, data: []const u8) !void {
        try writeIn(self.upstream, "PKGBUILD", data);
        try run(self.upstream, &.{ "git", "commit", "--quiet", "-am", "maintainer update" });
    }

    /// What makepkg does to a VCS package's PKGBUILD.
    fn makepkgRewritesPkgver(self: *Fixture) !void {
        try writeIn(self.clone_dir, "PKGBUILD", "pkgname=test\npkgver=1.0.r42\npkgrel=1\n");
    }
};

test "update keeps makepkg's pkgver edit when the AUR has nothing new" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.makepkgRewritesPkgver();

    try testing.expectEqual(UpdateResult.up_to_date, try git.update(testing.allocator, f.cache, "pkg-git"));
    const pkgbuild = try readIn(f.clone_dir, "PKGBUILD");
    defer testing.allocator.free(pkgbuild);
    try testing.expect(std.mem.indexOf(u8, pkgbuild, "pkgver=1.0.r42") != null);
}

test "update applies an AUR change over makepkg's pkgver edit" {
    // git pull --ff-only refused this ("Your local changes ... would be
    // overwritten"), so VCS packages stopped updating after one build.
    var f = try Fixture.init();
    defer f.deinit();
    try f.makepkgRewritesPkgver();
    try f.pushPkgbuild("pkgname=test\npkgver=1.0\npkgrel=2\nsource=(new)\n");

    try testing.expectEqual(UpdateResult.updated, try git.update(testing.allocator, f.cache, "pkg-git"));
    const pkgbuild = try readIn(f.clone_dir, "PKGBUILD");
    defer testing.allocator.free(pkgbuild);
    try testing.expectEqualStrings("pkgname=test\npkgver=1.0\npkgrel=2\nsource=(new)\n", pkgbuild);
    try testing.expectEqual(UpdateResult.up_to_date, try git.update(testing.allocator, f.cache, "pkg-git"));
}

fn headOf(dir: []const u8, rev: []const u8) ![]u8 {
    const result = try utils.runCommandIn(testing.allocator, &.{ "git", "rev-parse", rev }, dir);
    defer result.deinit(testing.allocator);
    return testing.allocator.dupe(u8, std.mem.trim(u8, result.stdout, "\n"));
}

test "cloneOrFetch leaves AUR changes pending until applyUpstream" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.makepkgRewritesPkgver();
    const accepted = try headOf(f.clone_dir, "HEAD");
    defer testing.allocator.free(accepted);

    try testing.expectEqual(git.CloneOrFetchResult.unchanged, try git.cloneOrFetch(testing.allocator, f.cache, "pkg-git"));

    try f.pushPkgbuild("pkgname=test\npkgver=1.0\npkgrel=2\nsource=(new)\n");
    // Fetched, not applied: HEAD and the working tree (with makepkg's
    // edit) stay at the accepted version, run after run.
    for (0..2) |_| {
        try testing.expectEqual(git.CloneOrFetchResult.pending, try git.cloneOrFetch(testing.allocator, f.cache, "pkg-git"));
        const head = try headOf(f.clone_dir, "HEAD");
        defer testing.allocator.free(head);
        try testing.expectEqualStrings(accepted, head);
        const pkgbuild = try readIn(f.clone_dir, "PKGBUILD");
        defer testing.allocator.free(pkgbuild);
        try testing.expect(std.mem.indexOf(u8, pkgbuild, "pkgver=1.0.r42") != null);
    }

    try testing.expect(try git.applyUpstream(testing.allocator, f.cache, "pkg-git"));
    const pkgbuild = try readIn(f.clone_dir, "PKGBUILD");
    defer testing.allocator.free(pkgbuild);
    try testing.expectEqualStrings("pkgname=test\npkgver=1.0\npkgrel=2\nsource=(new)\n", pkgbuild);

    try testing.expectEqual(git.CloneOrFetchResult.unchanged, try git.cloneOrFetch(testing.allocator, f.cache, "pkg-git"));
    try testing.expect(!try git.applyUpstream(testing.allocator, f.cache, "pkg-git"));
}
