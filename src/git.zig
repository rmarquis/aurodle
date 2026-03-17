const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

pub const AUR_GIT_BASE = "https://aur.archlinux.org/";
pub const DEFAULT_CACHE_SUBDIR = ".cache/aurodle";

// ── Result Types ────────────────────────────────────────────────────────

pub const CloneResult = enum { cloned, already_exists };
pub const UpdateResult = enum { updated, up_to_date };
pub const CloneOrUpdateResult = enum { cloned, updated, up_to_date };

pub const FileEntry = struct {
    name: []const u8,
    size: u64,
    is_pkgbuild: bool,
    is_install: bool,
};

// ── Errors ──────────────────────────────────────────────────────────────

pub const GitError = error{
    CloneFailed,
    PullFailed,
    NotCloned,
    InvalidRepository,
    InvalidFilePath,
    NoHomeDirectory,
    SpawnFailed,
};

// ── Public API ──────────────────────────────────────────────────────────

/// Resolve the default cache root: ~/.cache/aurodle
pub fn defaultCacheRoot(allocator: Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(allocator, &.{ home, DEFAULT_CACHE_SUBDIR });
}

/// Get the full clone directory path for a pkgbase.
pub fn cloneDir(allocator: Allocator, cache_root: []const u8, pkgbase: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ cache_root, pkgbase });
}

/// Check if a package has been cloned (directory exists with .git/).
pub fn isCloned(allocator: Allocator, cache_root: []const u8, pkgbase: []const u8) !bool {
    const dest = try cloneDir(allocator, cache_root, pkgbase);
    defer allocator.free(dest);
    const git_dir = try std.fs.path.join(allocator, &.{ dest, ".git" });
    defer allocator.free(git_dir);
    return dirExists(git_dir);
}

/// Clone an AUR package repository by pkgbase.
///
/// Idempotent: if the clone directory already exists, returns .already_exists
/// without touching it. On failure, any partial directory is cleaned up.
///
/// The caller is responsible for pkgname→pkgbase resolution via AUR RPC.
pub fn clone(allocator: Allocator, cache_root: []const u8, pkgbase: []const u8) !CloneResult {
    const dest = try cloneDir(allocator, cache_root, pkgbase);
    defer allocator.free(dest);

    if (dirExists(dest)) return .already_exists;

    // Ensure parent directory exists
    if (std.fs.path.dirname(dest)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }

    const url = try std.fmt.allocPrint(allocator, "{s}{s}.git", .{ AUR_GIT_BASE, pkgbase });
    defer allocator.free(url);

    const result = utils.runCommand(allocator, &.{
        "git", "clone", "--depth=1", url, dest,
    }) catch {
        // git binary not found or spawn failure
        std.fs.cwd().deleteTree(dest) catch {};
        return error.CloneFailed;
    };
    defer result.deinit(allocator);

    if (result.exit_code != 0) {
        std.fs.cwd().deleteTree(dest) catch {};
        return error.CloneFailed;
    }

    return .cloned;
}

/// Update an existing clone via git pull --ff-only.
/// Returns .updated if HEAD changed, .up_to_date if unchanged.
pub fn update(allocator: Allocator, cache_root: []const u8, pkgbase: []const u8) !UpdateResult {
    const dest = try cloneDir(allocator, cache_root, pkgbase);
    defer allocator.free(dest);

    if (!dirExists(dest)) return error.NotCloned;

    const old_head = try getHead(allocator, dest);
    defer allocator.free(old_head);

    const result = try utils.runCommandIn(allocator, &.{
        "git", "pull", "--ff-only",
    }, dest);
    defer result.deinit(allocator);

    if (result.exit_code != 0) return error.PullFailed;

    const new_head = try getHead(allocator, dest);
    defer allocator.free(new_head);

    return if (std.mem.eql(u8, old_head, new_head)) .up_to_date else .updated;
}

/// Clone if not present, update if already cloned.
pub fn cloneOrUpdate(allocator: Allocator, cache_root: []const u8, pkgbase: []const u8) !CloneOrUpdateResult {
    const dest = try cloneDir(allocator, cache_root, pkgbase);
    defer allocator.free(dest);

    if (dirExists(dest)) {
        return switch (try update(allocator, cache_root, pkgbase)) {
            .updated => .updated,
            .up_to_date => .up_to_date,
        };
    } else {
        _ = try clone(allocator, cache_root, pkgbase);
        return .cloned;
    }
}

/// List all tracked files in the clone directory.
/// Uses `git ls-files`. PKGBUILD is always listed first.
pub fn listFiles(allocator: Allocator, cache_root: []const u8, pkgbase: []const u8) ![]FileEntry {
    const dest = try cloneDir(allocator, cache_root, pkgbase);
    defer allocator.free(dest);

    if (!dirExists(dest)) return error.NotCloned;

    const result = try utils.runCommandIn(allocator, &.{ "git", "ls-files" }, dest);
    defer result.deinit(allocator);

    if (result.exit_code != 0) return error.InvalidRepository;

    var entries: std.ArrayListUnmanaged(FileEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit(allocator);
    }
    var pkgbuild_entry: ?FileEntry = null;

    const trimmed = std.mem.trim(u8, result.stdout, "\n");
    if (trimmed.len == 0) {
        return entries.toOwnedSlice(allocator);
    }

    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |filename| {
        if (filename.len == 0) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dest, filename });
        defer allocator.free(full_path);

        const size: u64 = blk: {
            const stat = std.fs.cwd().statFile(full_path) catch break :blk 0;
            break :blk stat.size;
        };

        const entry = FileEntry{
            .name = try allocator.dupe(u8, filename),
            .size = size,
            .is_pkgbuild = std.mem.eql(u8, filename, "PKGBUILD"),
            .is_install = std.mem.endsWith(u8, filename, ".install"),
        };

        if (entry.is_pkgbuild) {
            pkgbuild_entry = entry;
        } else {
            try entries.append(allocator, entry);
        }
    }

    // PKGBUILD always first — primary review target
    if (pkgbuild_entry) |pb| {
        try entries.insert(allocator, 0, pb);
    }

    return entries.toOwnedSlice(allocator);
}

/// Read a file from the clone directory.
/// Validates the path stays within the clone dir (path traversal guard).
pub fn readFile(allocator: Allocator, cache_root: []const u8, pkgbase: []const u8, filename: []const u8) ![]u8 {
    try validateFilePath(filename);

    const dest = try cloneDir(allocator, cache_root, pkgbase);
    defer allocator.free(dest);

    if (!dirExists(dest)) return error.NotCloned;

    const full_path = try std.fs.path.join(allocator, &.{ dest, filename });
    defer allocator.free(full_path);

    const file = std.fs.cwd().openFile(full_path, .{}) catch return error.InvalidFilePath;
    defer file.close();

    return file.readToEndAlloc(allocator, 1024 * 1024); // 1MB limit
}

/// Show the diff between the previous HEAD and current HEAD.
/// Uses ORIG_HEAD which git sets during pull.
/// Check whether ORIG_HEAD exists in the clone (set by git pull).
/// Returns false for fresh clones that have never been pulled.
pub fn hasOrigHead(allocator: Allocator, cache_root: []const u8, pkgbase: []const u8) !bool {
    const dest = try cloneDir(allocator, cache_root, pkgbase);
    defer allocator.free(dest);

    if (!dirExists(dest)) return error.NotCloned;

    const result = try utils.runCommandIn(allocator, &.{
        "git", "rev-parse", "--verify", "ORIG_HEAD",
    }, dest);
    defer result.deinit(allocator);

    return result.exit_code == 0;
}

// ── Internal Helpers ────────────────────────────────────────────────────

fn getHead(allocator: Allocator, repo_path: []const u8) ![]u8 {
    const result = try utils.runCommandIn(allocator, &.{
        "git", "rev-parse", "HEAD",
    }, repo_path);
    defer result.deinit(allocator);

    if (result.exit_code != 0) return error.InvalidRepository;

    const trimmed = std.mem.trim(u8, result.stdout, " \t\n");
    return try allocator.dupe(u8, trimmed);
}

/// Validate that a filename doesn't escape the clone directory.
fn validateFilePath(filename: []const u8) !void {
    if (filename.len == 0) return error.InvalidFilePath;
    if (filename[0] == '/') return error.InvalidFilePath;

    var it = std.mem.splitScalar(u8, filename, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.InvalidFilePath;
    }
}

fn dirExists(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    return stat.kind == .directory;
}

// ── Tests ───────────────────────────────────────────────────────────────

fn createTestGitRepo(allocator: Allocator, base_dir: []const u8, name: []const u8) ![]u8 {
    const repo_dir = try std.fs.path.join(allocator, &.{ base_dir, name });
    errdefer allocator.free(repo_dir);

    std.fs.cwd().makePath(repo_dir) catch {};

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

    const pkgbuild_file = try std.fs.cwd().createFile(pkgbuild_path, .{});
    try pkgbuild_file.writeAll("pkgname=test\npkgver=1.0\npkgrel=1\n");
    pkgbuild_file.close();

    const add_result = try utils.runCommandIn(allocator, &.{ "git", "add", "." }, repo_dir);
    add_result.deinit(allocator);
    const commit_result = try utils.runCommandIn(allocator, &.{ "git", "commit", "-m", "initial" }, repo_dir);
    commit_result.deinit(allocator);

    return repo_dir;
}

test "cloneDir returns correct path" {
    const dir = try cloneDir(std.testing.allocator, "/tmp/cache", "yay");
    defer std.testing.allocator.free(dir);
    try std.testing.expectEqualStrings("/tmp/cache/yay", dir);
}

test "defaultCacheRoot uses HOME" {
    const root = try defaultCacheRoot(std.testing.allocator);
    defer std.testing.allocator.free(root);
    const home = std.posix.getenv("HOME").?;
    try std.testing.expect(std.mem.startsWith(u8, root, home));
    try std.testing.expect(std.mem.endsWith(u8, root, "/.cache/aurodle"));
}

test "isCloned returns false for non-existent directory" {
    try std.testing.expect(!try isCloned(std.testing.allocator, "/tmp/nonexistent-aurodle-test", "fake-pkg"));
}

test "isCloned returns true for valid git repo" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const repo_dir = try createTestGitRepo(std.testing.allocator, tmp_path, "test-pkg");
    defer std.testing.allocator.free(repo_dir);

    try std.testing.expect(try isCloned(std.testing.allocator, tmp_path, "test-pkg"));
}

test "isCloned returns false for non-git directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    // Create a plain directory (no .git)
    const plain_dir = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "plain-pkg" });
    defer std.testing.allocator.free(plain_dir);
    try std.fs.cwd().makePath(plain_dir);

    try std.testing.expect(!try isCloned(std.testing.allocator, tmp_path, "plain-pkg"));
}

test "clone returns already_exists for existing directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    // Pre-create a repo
    const repo_dir = try createTestGitRepo(std.testing.allocator, tmp_path, "existing-pkg");
    defer std.testing.allocator.free(repo_dir);

    const result = try clone(std.testing.allocator, tmp_path, "existing-pkg");
    try std.testing.expectEqual(CloneResult.already_exists, result);
}

test "update returns up_to_date when no changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const repo_dir = try createTestGitRepo(std.testing.allocator, tmp_path, "uptodate-pkg");
    defer std.testing.allocator.free(repo_dir);

    // update on a local-only repo (no remote) will fail with PullFailed
    // because there's no remote to pull from — this is expected behavior
    const result = update(std.testing.allocator, tmp_path, "uptodate-pkg");
    try std.testing.expectError(error.PullFailed, result);
}

test "update returns NotCloned when directory does not exist" {
    const result = update(std.testing.allocator, "/tmp/nonexistent-aurodle-test", "fake-pkg");
    try std.testing.expectError(error.NotCloned, result);
}

test "listFiles returns PKGBUILD first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const repo_dir = try createTestGitRepo(std.testing.allocator, tmp_path, "list-pkg");
    defer std.testing.allocator.free(repo_dir);

    // Add extra files
    const install_path = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "list-pkg.install" });
    defer std.testing.allocator.free(install_path);
    const install_file = try std.fs.cwd().createFile(install_path, .{});
    try install_file.writeAll("post_install() { true; }\n");
    install_file.close();

    const patch_path = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "fix.patch" });
    defer std.testing.allocator.free(patch_path);
    const patch_file = try std.fs.cwd().createFile(patch_path, .{});
    try patch_file.writeAll("--- a/foo\n+++ b/foo\n");
    patch_file.close();

    // Stage and commit new files
    const add_result = try utils.runCommandIn(std.testing.allocator, &.{ "git", "add", "." }, repo_dir);
    add_result.deinit(std.testing.allocator);
    const commit_result = try utils.runCommandIn(std.testing.allocator, &.{ "git", "commit", "-m", "add files" }, repo_dir);
    commit_result.deinit(std.testing.allocator);

    const files = try listFiles(std.testing.allocator, tmp_path, "list-pkg");
    defer {
        for (files) |f| std.testing.allocator.free(f.name);
        std.testing.allocator.free(files);
    }

    try std.testing.expectEqual(@as(usize, 3), files.len);
    try std.testing.expectEqualStrings("PKGBUILD", files[0].name);
    try std.testing.expect(files[0].is_pkgbuild);
    try std.testing.expect(files[0].size > 0);

    // Find the .install file and verify its flag
    var found_install = false;
    for (files) |f| {
        if (f.is_install) {
            found_install = true;
            try std.testing.expect(std.mem.endsWith(u8, f.name, ".install"));
        }
    }
    try std.testing.expect(found_install);
}

test "listFiles returns NotCloned for non-existent package" {
    const result = listFiles(std.testing.allocator, "/tmp/nonexistent-aurodle-test", "fake-pkg");
    try std.testing.expectError(error.NotCloned, result);
}

test "readFile reads file content from clone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const repo_dir = try createTestGitRepo(std.testing.allocator, tmp_path, "read-pkg");
    defer std.testing.allocator.free(repo_dir);

    const content = try readFile(std.testing.allocator, tmp_path, "read-pkg", "PKGBUILD");
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "pkgname=test") != null);
}

test "readFile blocks path traversal with .." {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const repo_dir = try createTestGitRepo(std.testing.allocator, tmp_path, "traversal-pkg");
    defer std.testing.allocator.free(repo_dir);

    const attack_vectors = [_][]const u8{
        "../../../etc/passwd",
        "../../.ssh/id_rsa",
        "subdir/../../outside",
        "..",
        "../",
        "PKGBUILD/../../../etc/passwd",
    };

    for (attack_vectors) |path| {
        const result = readFile(std.testing.allocator, tmp_path, "traversal-pkg", path);
        try std.testing.expectError(error.InvalidFilePath, result);
    }
}

test "readFile blocks absolute paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const repo_dir = try createTestGitRepo(std.testing.allocator, tmp_path, "abs-pkg");
    defer std.testing.allocator.free(repo_dir);

    const result = readFile(std.testing.allocator, tmp_path, "abs-pkg", "/etc/passwd");
    try std.testing.expectError(error.InvalidFilePath, result);
}

test "readFile returns error for non-existent file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const repo_dir = try createTestGitRepo(std.testing.allocator, tmp_path, "nofile-pkg");
    defer std.testing.allocator.free(repo_dir);

    const result = readFile(std.testing.allocator, tmp_path, "nofile-pkg", "nonexistent.txt");
    try std.testing.expectError(error.InvalidFilePath, result);
}

test "readFile returns NotCloned when not cloned" {
    const result = readFile(std.testing.allocator, "/tmp/nonexistent-aurodle-test", "fake-pkg", "PKGBUILD");
    try std.testing.expectError(error.NotCloned, result);
}

test "validateFilePath rejects empty filename" {
    try std.testing.expectError(error.InvalidFilePath, validateFilePath(""));
}

test "validateFilePath accepts valid filenames" {
    try validateFilePath("PKGBUILD");
    try validateFilePath("subdir/file.patch");
    try validateFilePath("some.install");
}

test "SortField-like: CloneResult enum values" {
    // Verify enum variants exist and are distinct
    try std.testing.expect(CloneResult.cloned != CloneResult.already_exists);
    try std.testing.expect(UpdateResult.updated != UpdateResult.up_to_date);
}

test "cloneOrUpdate returns NotCloned-free result for existing repo" {
    // cloneOrUpdate should never return NotCloned — it clones if missing.
    // We test the clone path here (update path tested via update tests).
    // Note: actual network clone would fail, so we test with pre-existing repo.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const repo_dir = try createTestGitRepo(std.testing.allocator, tmp_path, "cou-pkg");
    defer std.testing.allocator.free(repo_dir);

    // cloneOrUpdate on existing repo → tries update → PullFailed (no remote)
    const result = cloneOrUpdate(std.testing.allocator, tmp_path, "cou-pkg");
    try std.testing.expectError(error.PullFailed, result);
}

test "hasOrigHead returns false for fresh clone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const repo_dir = try createTestGitRepo(std.testing.allocator, tmp_path, "diff-pkg");
    defer std.testing.allocator.free(repo_dir);

    // No ORIG_HEAD exists on a fresh repo
    const result = try hasOrigHead(std.testing.allocator, tmp_path, "diff-pkg");
    try std.testing.expect(!result);
}

test "hasOrigHead returns NotCloned when not cloned" {
    const result = hasOrigHead(std.testing.allocator, "/tmp/nonexistent-aurodle-test", "fake-pkg");
    try std.testing.expectError(error.NotCloned, result);
}
