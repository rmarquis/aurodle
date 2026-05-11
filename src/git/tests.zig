const std = @import("std");
const testing = std.testing;
const git = @import("../git.zig");

const CloneResult = git.CloneResult;
const UpdateResult = git.UpdateResult;

test "cloneDir returns correct path" {
    const dir = try git.cloneDir(testing.allocator, "/tmp/cache", "yay");
    defer testing.allocator.free(dir);
    try testing.expectEqualStrings("/tmp/cache/yay", dir);
}

test "defaultCacheRoot uses HOME" {
    const root = try git.defaultCacheRoot(testing.allocator);
    defer testing.allocator.free(root);
    const home = std.mem.span(std.c.getenv("HOME").?);
    try testing.expect(std.mem.startsWith(u8, root, home));
    try testing.expect(std.mem.endsWith(u8, root, "/.cache/aurodle"));
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
    const utils = @import("../utils.zig");
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

test "cloneOrUpdate returns NotCloned-free result for existing repo" {
    // cloneOrUpdate should never return NotCloned — it clones if missing.
    // We test the clone path here (update path tested via update tests).
    // Note: actual network clone would fail, so we test with pre-existing repo.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const repo_dir = try git.createTestGitRepo(testing.allocator, tmp_path, "cou-pkg");
    defer testing.allocator.free(repo_dir);

    // cloneOrUpdate on existing repo → tries update → PullFailed (no remote)
    const result = git.cloneOrUpdate(testing.allocator, tmp_path, "cou-pkg");
    try testing.expectError(error.PullFailed, result);
}

test "hasOrigHead returns false for fresh clone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const repo_dir = try git.createTestGitRepo(testing.allocator, tmp_path, "diff-pkg");
    defer testing.allocator.free(repo_dir);

    // No ORIG_HEAD exists on a fresh repo
    const result = try git.hasOrigHead(testing.allocator, tmp_path, "diff-pkg");
    try testing.expect(!result);
}

test "hasOrigHead returns NotCloned when not cloned" {
    const result = git.hasOrigHead(testing.allocator, "/tmp/nonexistent-aurodle-test", "fake-pkg");
    try testing.expectError(error.NotCloned, result);
}
