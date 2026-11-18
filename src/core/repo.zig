const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const Reporter = @import("report.zig").Reporter;
const makepkg = @import("makepkg.zig");
const repo_conf = @import("repo_conf.zig");

pub const DEFAULT_REPO_NAME = repo_conf.DEFAULT_REPO_NAME;
pub const MakepkgConfig = makepkg.MakepkgConfig;

// ── Types ────────────────────────────────────────────────────────────────

pub const RepoPackage = struct {
    name: []const u8,
    version: []const u8,
    filename: []const u8,
};

// ── Repository ───────────────────────────────────────────────────────────

/// Result of Repository.packageVersions.
pub const PackageVersions = struct {
    arena: std.heap.ArenaAllocator,
    set: std.HashMapUnmanaged(Key, void, KeyContext, std.hash_map.default_max_load_percentage) = .empty,

    const Key = struct { name: []const u8, version: []const u8 };
    const KeyContext = struct {
        pub fn hash(_: KeyContext, k: Key) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(k.name);
            h.update(&.{0});
            h.update(k.version);
            return h.final();
        }
        pub fn eql(_: KeyContext, a: Key, b: Key) bool {
            return std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.version, b.version);
        }
    };

    /// Is there a package file for `name` at exactly `version`?
    pub fn contains(self: *const PackageVersions, name: []const u8, version: []const u8) bool {
        return self.set.contains(.{ .name = name, .version = version });
    }

    pub fn deinit(self: *PackageVersions) void {
        self.arena.deinit();
    }
};

pub const Repository = struct {
    allocator: Allocator,
    io: std.Io,
    repo_name: []const u8,
    repo_dir: []const u8,
    db_path: []const u8,
    cache_dir: []const u8,
    makepkg_conf: MakepkgConfig,
    skip_repo_add: bool,
    owns_repo_name: bool,
    /// Shows repo-add's error output. Set by the frontend.
    reporter: Reporter = .silent,

    /// Create a Repository using paths derived from makepkg.conf:
    /// - repo_dir: PKGDEST from makepkg.conf (required)
    /// - cache_dir: `cache_root`, the clone cache shared with git.zig
    ///   ($AURDEST, $XDG_CACHE_HOME/aurodle or ~/.cache/aurodle; see git.defaultCacheRoot)
    /// - repo_name: derived from pacman.conf by matching PKGDEST to a Server directive
    /// Parses makepkg.conf for PKGDEST and PKGEXT.
    pub fn init(allocator: Allocator, io: std.Io, cache_root: []const u8) !Repository {
        const cache_dir = try allocator.dupe(u8, cache_root);
        errdefer allocator.free(cache_dir);

        const conf = makepkg.parseMakepkgConf(allocator) catch MakepkgConfig{};
        errdefer conf.deinit(allocator);

        const repo_dir = try allocator.dupe(u8, conf.pkgdest orelse return error.PkgdestNotSet);
        errdefer allocator.free(repo_dir);

        // Derive the repo name from pacman.conf by finding which section
        // has a Server = file:// URL pointing to PKGDEST.
        const derived_name = try repo_conf.deriveRepoNameFromPacmanConf(allocator, repo_dir) orelse
            return error.RepoNotInPacmanConf;

        return initFromParts(allocator, io, cache_dir, repo_dir, conf, derived_name);
    }

    /// Create a Repository with an explicit cache root (for testing).
    /// Both repo_dir and cache_dir are under cache_root.
    /// Does NOT parse system makepkg.conf.
    pub fn initWithRoot(allocator: Allocator, io: std.Io, cache_root: []const u8) !Repository {
        const cache_dir = try allocator.dupe(u8, cache_root);
        errdefer allocator.free(cache_dir);

        const repo_dir = try std.fs.path.join(allocator, &.{ cache_root, DEFAULT_REPO_NAME });

        return initFromParts(allocator, io, cache_dir, repo_dir, .{}, null);
    }

    fn initFromParts(allocator: Allocator, io: std.Io, cache_dir: []const u8, repo_dir: []const u8, conf: MakepkgConfig, derived_name: ?[]const u8) !Repository {
        const repo_name = derived_name orelse DEFAULT_REPO_NAME;
        const owns_name = derived_name != null;

        const db_path = try std.fmt.allocPrint(allocator, "{s}/{s}.db.tar.xz", .{ repo_dir, repo_name });
        errdefer allocator.free(db_path);

        return .{
            .allocator = allocator,
            .io = io,
            .repo_name = repo_name,
            .cache_dir = cache_dir,
            .repo_dir = repo_dir,
            .db_path = db_path,
            .makepkg_conf = conf,
            .skip_repo_add = false,
            .owns_repo_name = owns_name,
        };
    }

    pub fn deinit(self: *Repository) void {
        self.makepkg_conf.deinit(self.allocator);
        if (self.owns_repo_name) self.allocator.free(self.repo_name);
        self.allocator.free(self.db_path);
        self.allocator.free(self.repo_dir);
        self.allocator.free(self.cache_dir);
    }

    // ── Directory Management ─────────────────────────────────────────────

    /// Create repository and log directories if they don't exist.
    /// Idempotent — safe to call multiple times.
    pub fn ensureExists(self: *const Repository) !void {
        try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), self.io, self.repo_dir);
    }

    // ── Package Addition ─────────────────────────────────────────────────

    /// Find built packages in the repository directory (placed there by
    /// makepkg via PKGDEST) and update the database.
    /// Returns filenames of added packages.
    ///
    /// Handles split packages: one PKGBUILD may produce multiple .pkg.tar.* files.
    pub fn addBuiltPackages(self: *const Repository) ![]const []const u8 {
        const pkg_files = try self.findBuiltPackages(self.repo_dir);
        errdefer {
            for (pkg_files) |p| self.allocator.free(p);
            self.allocator.free(pkg_files);
        }

        if (pkg_files.len == 0) return error.PackageNotFound;

        // Update database
        try self.runRepoAdd(pkg_files);

        return pkg_files;
    }

    /// Add a specific set of package files (by path) to the repository database.
    /// Use this instead of addBuiltPackages when the exact output paths are known
    /// (e.g. from `makepkg --packagelist`) to avoid passing stale old-version files
    /// that are still sitting in PKGDEST alongside newly-built ones.
    /// Returns a caller-owned copy of the provided paths.
    pub fn addPackageFiles(self: *const Repository, pkg_files: []const []const u8) ![]const []const u8 {
        if (pkg_files.len == 0) return error.PackageNotFound;

        try self.runRepoAdd(pkg_files);

        var owned = try self.allocator.alloc([]const u8, pkg_files.len);
        var n: usize = 0;
        errdefer {
            for (owned[0..n]) |p| self.allocator.free(p);
            self.allocator.free(owned);
        }
        for (pkg_files) |path| {
            owned[n] = try self.allocator.dupe(u8, path);
            n += 1;
        }
        return owned;
    }

    /// Find .pkg.tar.* files in a directory matching PKGEXT.
    pub fn findBuiltPackages(self: *const Repository, dir_path: []const u8) ![]const []const u8 {
        var results: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (results.items) |p| self.allocator.free(p);
            results.deinit(self.allocator);
        }

        var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), self.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return results.toOwnedSlice(self.allocator),
            else => return err,
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.endsWith(u8, entry.name, self.makepkg_conf.pkgext)) {
                const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
                try results.append(self.allocator, full_path);
            }
        }

        return results.toOwnedSlice(self.allocator);
    }

    /// Run `repo-add -R <db_path> <pkg1> <pkg2> ...`
    /// -R removes old package versions from disk automatically.
    fn runRepoAdd(self: *const Repository, pkg_paths: []const []const u8) !void {
        if (self.skip_repo_add) return;

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.ensureTotalCapacity(self.allocator, pkg_paths.len + 3);

        argv.appendAssumeCapacity("repo-add");
        argv.appendAssumeCapacity("-R");
        argv.appendAssumeCapacity(self.db_path);
        argv.appendSliceAssumeCapacity(pkg_paths);

        const result = try utils.runCommand(self.allocator, argv.items);
        defer result.deinit(self.allocator);

        if (!result.success()) {
            if (result.stderr.len > 0) self.reporter.message(.output, result.stderr);
            return error.RepoAddFailed;
        }
    }

    // ── Package Listing ──────────────────────────────────────────────────

    /// List all packages in the repository directory by scanning for .pkg.tar.* files.
    pub fn listPackages(self: *const Repository) ![]RepoPackage {
        var packages: std.ArrayList(RepoPackage) = .empty;
        errdefer {
            for (packages.items) |pkg| {
                self.allocator.free(pkg.name);
                self.allocator.free(pkg.version);
                self.allocator.free(pkg.filename);
            }
            packages.deinit(self.allocator);
        }

        var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), self.io, self.repo_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return packages.toOwnedSlice(self.allocator),
            else => return err,
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            // Skip non-package files
            if (std.mem.indexOf(u8, entry.name, ".pkg.tar.") == null) continue;
            // Skip database files (e.g., reponame.db.tar.xz, reponame.files.tar.xz)
            if (self.isDbFile(entry.name)) continue;

            if (parsePackageFilename(entry.name)) |parsed| {
                try packages.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, parsed.name),
                    .version = try self.allocator.dupe(u8, parsed.version),
                    .filename = try self.allocator.dupe(u8, entry.name),
                });
            }
        }

        return packages.toOwnedSlice(self.allocator);
    }

    /// Snapshot of the package files in the repository directory, by name
    /// and version. Used to skip VCS rebuilds when the devel-computed
    /// version is already in the local repo, with one directory listing
    /// for any number of lookups. It does not see later changes (a build,
    /// repo-add -R): take a new one after those. Caller deinits.
    pub fn packageVersions(self: *const Repository) !PackageVersions {
        var result: PackageVersions = .{ .arena = .init(self.allocator) };
        errdefer result.deinit();
        const arena = result.arena.allocator();

        var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), self.io, self.repo_dir, .{ .iterate = true });
        defer dir.close(self.io);
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.indexOf(u8, entry.name, ".pkg.tar.") == null) continue;
            if (self.isDbFile(entry.name)) continue;
            const parsed = parsePackageFilename(entry.name) orelse continue;
            // entry.name is only valid until the next iteration.
            try result.set.put(arena, .{
                .name = try arena.dupe(u8, parsed.name),
                .version = try arena.dupe(u8, parsed.version),
            }, {});
        }
        return result;
    }

    // ── Configuration Check ──────────────────────────────────────────────

    /// Check if the local AUR repository is configured in pacman.conf.
    pub fn isConfigured(self: *const Repository) !bool {
        return repo_conf.isConfiguredFromPathWithName("/etc/pacman.conf", self.repo_name);
    }

    /// Copy-pasteable pacman.conf configuration for the local AUR repository.
    pub fn configInstructions() []const u8 {
        return
        \\Add the following to /etc/pacman.conf (name can be customized):
        \\
        \\[aur]
        \\SigLevel = Optional TrustAll
        \\Server = file:///var/lib/aurodle/aur
        \\
        \\Set PKGDEST in /etc/makepkg.conf to match the Server path:
        \\
        \\PKGDEST=/var/lib/aurodle/aur
        \\
        \\Then run:
        \\  sudo install -d -o $USER /var/lib/aurodle/aur
        \\  sudo pacman -Syu
        ;
    }

    /// Check if a filename is a database file (e.g., reponame.db.tar.xz, reponame.files.tar.xz).
    pub fn isDbFile(self: *const Repository, filename: []const u8) bool {
        if (filename.len <= self.repo_name.len) return false;
        if (!std.mem.startsWith(u8, filename, self.repo_name)) return false;
        return filename[self.repo_name.len] == '.';
    }
};

// ── Standalone Functions ─────────────────────────────────────────────────

/// Parse "pkgname-pkgver-pkgrel-arch.pkg.tar.ext" into name and version.
///
/// Package names can contain hyphens, so parsing is done right-to-left:
///   yay-bin-12.3.5-1-x86_64.pkg.tar.zst
///   ├─────┘ name = "yay-bin"
///   │       ├─────┘ version = "12.3.5-1"
///   │       │       └──────┘ arch = "x86_64"
pub fn parsePackageFilename(filename: []const u8) ?struct { name: []const u8, version: []const u8 } {
    // Strip .pkg.tar.* suffix
    const pkg_idx = std.mem.indexOf(u8, filename, ".pkg.tar.") orelse return null;
    const stem = filename[0..pkg_idx];

    // From the right: arch, then pkgrel, then pkgver; rest is pkgname
    const arch_sep = std.mem.lastIndexOfScalar(u8, stem, '-') orelse return null;
    const before_arch = stem[0..arch_sep];

    const rel_sep = std.mem.lastIndexOfScalar(u8, before_arch, '-') orelse return null;
    const before_rel = before_arch[0..rel_sep];

    const ver_sep = std.mem.lastIndexOfScalar(u8, before_rel, '-') orelse return null;

    return .{
        .name = stem[0..ver_sep],
        .version = stem[ver_sep + 1 .. arch_sep], // "pkgver-pkgrel"
    };
}

/// Check if [repo_name] is configured in a pacman.conf file.
/// Check if [name] is configured in a pacman.conf file.
/// Derive the local AUR repository name from pacman.conf by finding a section
/// whose `Server = file://` URL matches the given PKGDEST path.
///
/// For example, if PKGDEST is `/var/lib/aurodle/mypkgs` and pacman.conf contains:
///   [mypkgs]
///   Server = file:///var/lib/aurodle/mypkgs
///
/// This returns "mypkgs".
const dirExists = utils.dirExists;

/// Copy the local AUR repo DB to pacman's sync cache so that subsequent
/// makepkg -s calls (which spawn their own pacman) see just-built packages.
/// Only touches the local AUR repo entry — official repo DBs are left untouched.
pub fn refreshAurpkgsSyncDb(allocator: std.mem.Allocator, repository: *Repository, auth: anytype) !void {
    const sync_db_path = try std.fmt.allocPrint(allocator, "/var/lib/pacman/sync/{s}.db", .{repository.repo_name});
    defer allocator.free(sync_db_path);
    const result = try auth.runCaptured(&.{ "cp", repository.db_path, sync_db_path });
    defer result.deinit(allocator);
    if (!result.success()) return error.SyncDbRefreshFailed;
}
