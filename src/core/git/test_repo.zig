//! Test support: a local git repository standing in for an AUR clone.
const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("../utils.zig");

pub fn createTestGitRepo(allocator: Allocator, base_dir: []const u8, name: []const u8) ![]u8 {
    const repo_dir = try std.fs.path.join(allocator, &.{ base_dir, name });
    errdefer allocator.free(repo_dir);

    std.Io.Dir.createDirPath(std.Io.Dir.cwd(), std.testing.io, repo_dir) catch {};

    // git init
    const init_result = try utils.runCommandIn(allocator, &.{ "git", "init" }, repo_dir);
    init_result.deinit(allocator);

    // Configure git user for commits
    const cfg1 = try utils.runCommandIn(allocator, &.{ "git", "config", "user.email", "test@test.com" }, repo_dir);
    cfg1.deinit(allocator);
    const cfg2 = try utils.runCommandIn(allocator, &.{ "git", "config", "user.name", "Test" }, repo_dir);
    cfg2.deinit(allocator);

    // Create a PKGBUILD and commit
    const pkgbuild_path = try std.fs.path.join(allocator, &.{ repo_dir, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);

    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), std.testing.io, .{ .sub_path = pkgbuild_path, .data = "pkgname=test\npkgver=1.0\npkgrel=1\n" });

    const add_result = try utils.runCommandIn(allocator, &.{ "git", "add", "." }, repo_dir);
    add_result.deinit(allocator);
    const commit_result = try utils.runCommandIn(allocator, &.{ "git", "commit", "-m", "initial" }, repo_dir);
    commit_result.deinit(allocator);

    return repo_dir;
}
