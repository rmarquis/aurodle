//! Cleaning the local repository: stale clone directories, package files
//! and database entries. Planning (findStale, findAll) and deletion
//! (execute) are separate so the frontend can confirm in between.

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("../utils.zig");
const repo = @import("../repo.zig");
const Repository = repo.Repository;

// ── Types ────────────────────────────────────────────────────────────────

pub const CleanResult = struct {
    removed_clones: []const []const u8,
    removed_packages: []const []const u8,
    /// Package files on disk that the repository database doesn't reference.
    /// Only the files are deleted: their package name may still have a live
    /// database entry for a newer version.
    unreferenced_packages: []const []const u8,
    /// Package names whose database entry points at a file that no longer exists.
    dangling_entries: []const []const u8,
    bytes_freed: u64,
};

/// One package entry from the repository database.
/// Slices point into the text given to parseDbDescs().
pub const DbEntry = struct {
    filename: []const u8,
    name: []const u8,
};

/// Contents of the repository database, read at the start of a clean.
const DbSnapshot = struct {
    output: utils.ProcessResult,
    entries: []const DbEntry,
    filenames: std.StringHashMapUnmanaged(void),

    fn deinit(self: *DbSnapshot, allocator: Allocator) void {
        self.filenames.deinit(allocator);
        allocator.free(self.entries);
        self.output.deinit(allocator);
    }

    /// A detached signature counts as referenced when its package is.
    fn references(self: *const DbSnapshot, filename: []const u8) bool {
        const package_file = if (std.mem.endsWith(u8, filename, ".sig"))
            filename[0 .. filename.len - ".sig".len]
        else
            filename;
        return self.filenames.contains(package_file);
    }
};

// ── Planning and Deletion ────────────────────────────────────────────────

/// Identify stale artifacts for removal given package names from the
/// aurpkgs database that are no longer installed locally, plus package
/// files the repository database doesn't reference (e.g. old versions).
/// Returns a plan — actual deletion is done by execute().
pub fn findStale(repository: *const Repository, uninstalled_names: []const []const u8) !CleanResult {
    // Build set of uninstalled names for O(1) lookup
    var uninstalled: std.StringHashMapUnmanaged(void) = .empty;
    defer uninstalled.deinit(repository.allocator);
    for (uninstalled_names) |name| {
        try uninstalled.put(repository.allocator, name, {});
    }

    return collect(repository, &uninstalled);
}

/// Identify ALL artifacts for removal — every clone dir and package file.
/// Returns a plan — actual deletion is done by execute().
pub fn findAll(repository: *const Repository) !CleanResult {
    return collect(repository, null);
}

/// Shared implementation for findStale/findAll. When `filter` is non-null,
/// only collects entries whose names are in the set, plus unreferenced
/// package files; otherwise collects all. If the database can't be read,
/// nothing is treated as unreferenced or dangling.
fn collect(repository: *const Repository, filter: ?*const std.StringHashMapUnmanaged(void)) !CleanResult {
    var clones: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (clones.items) |s| repository.allocator.free(s);
        clones.deinit(repository.allocator);
    }

    if (std.Io.Dir.openDir(std.Io.Dir.cwd(), repository.io, repository.cache_dir, .{ .iterate = true })) |dir_handle| {
        var cache = dir_handle;
        defer cache.close(repository.io);

        var it = cache.iterate();
        while (try it.next(repository.io)) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.eql(u8, entry.name, repository.repo_name)) continue;
            if (filter) |f| {
                if (!f.contains(entry.name)) continue;
            }
            try clones.append(repository.allocator, try repository.allocator.dupe(u8, entry.name));
        }
    } else |_| {}

    var db = try readDb(repository);
    defer if (db) |*snapshot| snapshot.deinit(repository.allocator);

    var packages: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (packages.items) |s| repository.allocator.free(s);
        packages.deinit(repository.allocator);
    }

    var unreferenced: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (unreferenced.items) |s| repository.allocator.free(s);
        unreferenced.deinit(repository.allocator);
    }

    if (std.Io.Dir.openDir(std.Io.Dir.cwd(), repository.io, repository.repo_dir, .{ .iterate = true })) |dir_handle| {
        var repo_dir = dir_handle;
        defer repo_dir.close(repository.io);

        var it = repo_dir.iterate();
        while (try it.next(repository.io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.indexOf(u8, entry.name, ".pkg.tar.") == null) continue;
            if (repository.isDbFile(entry.name)) continue;
            if (filter) |f| {
                const parsed = repo.parsePackageFilename(entry.name) orelse continue;
                if (!f.contains(parsed.name)) {
                    if (db) |*snapshot| {
                        if (!snapshot.references(entry.name)) {
                            try unreferenced.append(repository.allocator, try repository.allocator.dupe(u8, entry.name));
                        }
                    }
                    continue;
                }
            }
            try packages.append(repository.allocator, try repository.allocator.dupe(u8, entry.name));
        }
    } else |_| {}

    var dangling: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (dangling.items) |s| repository.allocator.free(s);
        dangling.deinit(repository.allocator);
    }

    if (db) |*snapshot| {
        for (snapshot.entries) |entry| {
            if (filter) |f| {
                if (!f.contains(entry.name)) continue;
            }
            const path = try std.fs.path.join(repository.allocator, &.{ repository.repo_dir, entry.filename });
            defer repository.allocator.free(path);
            std.Io.Dir.access(std.Io.Dir.cwd(), repository.io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => try dangling.append(repository.allocator, try repository.allocator.dupe(u8, entry.name)),
                else => {},
            };
        }
    }

    return .{
        .removed_clones = try clones.toOwnedSlice(repository.allocator),
        .removed_packages = try packages.toOwnedSlice(repository.allocator),
        .unreferenced_packages = try unreferenced.toOwnedSlice(repository.allocator),
        .dangling_entries = try dangling.toOwnedSlice(repository.allocator),
        .bytes_freed = 0,
    };
}

/// Read the repository database. Returns null if it is missing or
/// unreadable, so callers can avoid acting on an unknown file list.
fn readDb(repository: *const Repository) !?DbSnapshot {
    var output = utils.runCommand(repository.allocator, &.{ "bsdtar", "-xOf", repository.db_path }) catch return null;
    errdefer output.deinit(repository.allocator);

    if (!output.success()) {
        output.deinit(repository.allocator);
        return null;
    }

    const entries = try parseDbDescs(repository.allocator, output.stdout);
    errdefer repository.allocator.free(entries);

    var filenames: std.StringHashMapUnmanaged(void) = .empty;
    errdefer filenames.deinit(repository.allocator);
    for (entries) |entry| {
        try filenames.put(repository.allocator, entry.filename, {});
    }

    return .{ .output = output, .entries = entries, .filenames = filenames };
}

/// Execute the actual deletion after user confirmation.
pub fn execute(repository: *const Repository, plan: CleanResult) void {
    // Remove stale clone directories
    for (plan.removed_clones) |name| {
        const path = std.fs.path.join(repository.allocator, &.{ repository.cache_dir, name }) catch continue;
        defer repository.allocator.free(path);
        std.Io.Dir.deleteTree(std.Io.Dir.cwd(), repository.io, path) catch {};
    }

    // Unreferenced files have no database entry of their own to remove.
    for (plan.unreferenced_packages) |filename| {
        const path = std.fs.path.join(repository.allocator, &.{ repository.repo_dir, filename }) catch continue;
        defer repository.allocator.free(path);
        std.Io.Dir.deleteFile(std.Io.Dir.cwd(), repository.io, path) catch {};
    }

    // Remove stale package files and their database entries
    if (plan.removed_packages.len > 0 or plan.dangling_entries.len > 0) {
        // Collect unique package names for repo-remove
        var pkg_names: std.StringHashMapUnmanaged(void) = .empty;
        defer pkg_names.deinit(repository.allocator);

        for (plan.dangling_entries) |name| {
            pkg_names.put(repository.allocator, name, {}) catch {};
        }

        for (plan.removed_packages) |filename| {
            // Delete the package file from disk
            const path = std.fs.path.join(repository.allocator, &.{ repository.repo_dir, filename }) catch continue;
            defer repository.allocator.free(path);
            std.Io.Dir.deleteFile(std.Io.Dir.cwd(), repository.io, path) catch {};

            // Collect the package name for repo-remove
            if (repo.parsePackageFilename(filename)) |parsed| {
                pkg_names.put(repository.allocator, parsed.name, {}) catch {};
            }
        }

        // Run repo-remove for each unique package name
        runRepoRemove(repository, pkg_names) catch {};
    }
}

/// Run `repo-remove <db_path> <pkg1> <pkg2> ...`
fn runRepoRemove(repository: *const Repository, names: std.StringHashMapUnmanaged(void)) !void {
    if (repository.skip_repo_add) return;
    if (names.count() == 0) return;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(repository.allocator);
    try argv.ensureTotalCapacity(repository.allocator, names.count() + 2);

    argv.appendAssumeCapacity("repo-remove");
    argv.appendAssumeCapacity(repository.db_path);

    var it = names.keyIterator();
    while (it.next()) |key| {
        argv.appendAssumeCapacity(key.*);
    }

    const result = try utils.runCommand(repository.allocator, argv.items);
    defer result.deinit(repository.allocator);
    // Best-effort: don't fail the whole clean if repo-remove errors
}

/// Free a CleanResult's allocated slices.
pub fn freeResult(repository: *const Repository, result: CleanResult) void {
    for (result.removed_clones) |s| repository.allocator.free(s);
    repository.allocator.free(result.removed_clones);
    for (result.removed_packages) |s| repository.allocator.free(s);
    repository.allocator.free(result.removed_packages);
    for (result.unreferenced_packages) |s| repository.allocator.free(s);
    repository.allocator.free(result.unreferenced_packages);
    for (result.dangling_entries) |s| repository.allocator.free(s);
    repository.allocator.free(result.dangling_entries);
}

// ── Database Parsing ─────────────────────────────────────────────────────

/// Extract package entries from concatenated `desc` files of a repository
/// database. Field names are only recognized after a blank line, so a field
/// value such as a package description can't be mistaken for one.
/// Caller owns the returned slice; its strings point into `text`.
pub fn parseDbDescs(allocator: Allocator, text: []const u8) ![]const DbEntry {
    var entries: std.ArrayList(DbEntry) = .empty;
    errdefer entries.deinit(allocator);

    var filename: ?[]const u8 = null;
    var at_field = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            at_field = true;
            continue;
        }
        if (!at_field) continue;
        at_field = false;

        const value = lines.peek() orelse break;
        if (std.mem.eql(u8, line, "%FILENAME%")) {
            filename = value;
        } else if (std.mem.eql(u8, line, "%NAME%")) {
            if (filename) |f| {
                try entries.append(allocator, .{ .filename = f, .name = value });
                filename = null;
            }
        }
    }

    return entries.toOwnedSlice(allocator);
}
