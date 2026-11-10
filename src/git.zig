const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

pub const AUR_GIT_BASE = "https://aur.archlinux.org/";
pub const DEFAULT_CACHE_SUBDIR = ".cache/aurodle";

// ── Result Types ────────────────────────────────────────────────────────

pub const CloneResult = enum { cloned, already_exists };
pub const UpdateResult = enum { updated, up_to_date };
pub const CloneOrUpdateResult = enum { cloned, updated, up_to_date, reCloned };

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

pub const CacheRoot = struct { path: []const u8, owned: bool };

/// Resolve cache root: use the configured value, or fall back to
/// defaultCacheRoot(). Caller must pass the result to freeCacheRoot when done.
pub fn resolveCacheRoot(cache_root: ?[]const u8, allocator: Allocator) !CacheRoot {
    if (cache_root) |c| return .{ .path = c, .owned = false };
    return .{ .path = try defaultCacheRoot(allocator), .owned = true };
}

pub fn freeCacheRoot(root: CacheRoot, allocator: Allocator) void {
    if (root.owned) allocator.free(root.path);
}

/// Environment values that decide where clones live.
pub const CacheEnv = struct {
    aurdest: ?[]const u8 = null,
    xdg_cache_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
};

/// Resolve the cache root from the process environment.
/// See cacheRootFrom for the lookup order. Caller owns the result.
pub fn defaultCacheRoot(allocator: Allocator) ![]u8 {
    return cacheRootFrom(allocator, .{
        .aurdest = nonEmptyEnv("AURDEST"),
        .xdg_cache_home = nonEmptyEnv("XDG_CACHE_HOME"),
        .home = nonEmptyEnv("HOME"),
    });
}

/// Resolve the cache root: $AURDEST if set, otherwise
/// $XDG_CACHE_HOME/aurodle, otherwise ~/.cache/aurodle. Empty values count
/// as unset, and a relative XDG_CACHE_HOME is ignored as the XDG Base
/// Directory spec requires. Caller owns the result.
pub fn cacheRootFrom(allocator: Allocator, env: CacheEnv) ![]u8 {
    if (env.aurdest) |dir| return allocator.dupe(u8, dir);
    if (env.xdg_cache_home) |dir| {
        if (std.fs.path.isAbsolute(dir)) return std.fs.path.join(allocator, &.{ dir, "aurodle" });
    }
    const home = env.home orelse return error.NoHomeDirectory;
    return std.fs.path.join(allocator, &.{ home, DEFAULT_CACHE_SUBDIR });
}

fn nonEmptyEnv(name: [*:0]const u8) ?[]const u8 {
    const value = std.mem.span(std.c.getenv(name) orelse return null);
    return if (value.len > 0) value else null;
}

/// Get the full clone directory path for a pkgbase.
pub fn cloneDir(allocator: Allocator, cache_root: []const u8, pkgbase: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ cache_root, pkgbase });
}

/// Check if a package has been cloned (directory exists with .git/).
pub fn isCloned(allocator: Allocator, cache_root: []const u8, pkgbase: []const u8) !bool {
    const git_dir = try std.fs.path.join(allocator, &.{ cache_root, pkgbase, ".git" });
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
        std.Io.Dir.createDirPath(std.Io.Dir.cwd(), std.Options.debug_io, parent) catch {};
    }

    const url = try std.fmt.allocPrint(allocator, "{s}{s}.git", .{ AUR_GIT_BASE, pkgbase });
    defer allocator.free(url);

    const result = utils.runCommand(allocator, &.{
        "git", "clone", "--depth=1", url, dest,
    }) catch {
        // git binary not found or spawn failure
        std.Io.Dir.deleteTree(std.Io.Dir.cwd(), std.Options.debug_io, dest) catch {};
        return error.CloneFailed;
    };
    defer result.deinit(allocator);

    if (!result.success()) {
        std.Io.Dir.deleteTree(std.Io.Dir.cwd(), std.Options.debug_io, dest) catch {};
        return error.CloneFailed;
    }

    return .cloned;
}

/// Update an existing clone to the AUR's current state (fetch, then reset
/// to the upstream branch if it moved). Local edits are kept when nothing
/// changed and discarded otherwise.
/// Returns .updated if HEAD changed, .up_to_date if unchanged.
pub fn update(allocator: Allocator, cache_root: []const u8, pkgbase: []const u8) !UpdateResult {
    const dest = try cloneDir(allocator, cache_root, pkgbase);
    defer allocator.free(dest);

    if (!dirExists(dest)) return error.NotCloned;
    return updateIn(allocator, dest);
}

/// Clone if not present, update if already cloned.
/// If the existing directory is a corrupt/invalid repository, it is deleted and re-cloned.
pub fn cloneOrUpdate(allocator: Allocator, cache_root: []const u8, pkgbase: []const u8) !CloneOrUpdateResult {
    const dest = try cloneDir(allocator, cache_root, pkgbase);
    defer allocator.free(dest);

    if (dirExists(dest)) {
        if (updateIn(allocator, dest)) |result| {
            return switch (result) {
                .updated => .updated,
                .up_to_date => .up_to_date,
            };
        } else |err| switch (err) {
            error.InvalidRepository => {
                std.Io.Dir.deleteTree(std.Io.Dir.cwd(), std.Options.debug_io, dest) catch {};
                _ = try clone(allocator, cache_root, pkgbase);
                return .reCloned;
            },
            else => return err,
        }
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

    if (!result.success()) return error.InvalidRepository;

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
            const stat = std.Io.Dir.statFile(std.Io.Dir.cwd(), std.Options.debug_io, full_path, .{}) catch break :blk 0;
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

    return std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), std.Options.debug_io, full_path, allocator, .limited(1024 * 1024)) catch error.InvalidFilePath;
}

// ── Internal Helpers ────────────────────────────────────────────────────

fn updateIn(allocator: Allocator, dest: []const u8) !UpdateResult {
    const fetch = try utils.runCommandIn(allocator, &.{ "git", "fetch", "--quiet" }, dest);
    defer fetch.deinit(allocator);
    if (!fetch.success()) return error.PullFailed;

    const head = try getHead(allocator, dest);
    defer allocator.free(head);
    const upstream = getUpstream(allocator, dest) catch return error.PullFailed;
    defer allocator.free(upstream);

    // Nothing new: leave the working tree alone. makepkg rewrites pkgver
    // in the PKGBUILD of VCS packages, and later --holdver/--noextract
    // builds rely on that edit.
    if (std.mem.eql(u8, head, upstream)) return .up_to_date;

    // Move to the AUR's version. `git pull --ff-only` refuses to when a
    // file it updates was modified locally, which is always the case for
    // a VCS package's PKGBUILD after a build. reset also sets ORIG_HEAD
    // to the previous HEAD, as pull did.
    const reset = try utils.runCommandIn(allocator, &.{ "git", "reset", "--hard", "--quiet", "@{upstream}" }, dest);
    defer reset.deinit(allocator);
    if (!reset.success()) return error.PullFailed;
    return .updated;
}

/// Commit id of the branch's upstream (the fetched AUR state).
fn getUpstream(allocator: Allocator, repo_path: []const u8) ![]u8 {
    const result = try utils.runCommandIn(allocator, &.{ "git", "rev-parse", "@{upstream}" }, repo_path);
    defer result.deinit(allocator);
    if (!result.success()) return error.NoUpstream;
    return try allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\n"));
}

fn getHead(allocator: Allocator, repo_path: []const u8) ![]u8 {
    const result = try utils.runCommandIn(allocator, &.{
        "git", "rev-parse", "HEAD",
    }, repo_path);
    defer result.deinit(allocator);

    if (!result.success()) return error.InvalidRepository;

    const trimmed = std.mem.trim(u8, result.stdout, " \t\n");
    return try allocator.dupe(u8, trimmed);
}

/// Validate that a filename doesn't escape the clone directory.
pub fn validateFilePath(filename: []const u8) !void {
    if (filename.len == 0) return error.InvalidFilePath;
    if (filename[0] == '/') return error.InvalidFilePath;

    var it = std.mem.splitScalar(u8, filename, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.InvalidFilePath;
    }
}

const dirExists = utils.dirExists;

// ── Tests ───────────────────────────────────────────────────────────────

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
