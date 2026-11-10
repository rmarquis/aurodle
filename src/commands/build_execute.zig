/// Build phase: invoke makepkg or makechrootpkg per plan entry, add built
/// packages to the local repo, and propagate failures to downstream entries.
const std = @import("std");
const Allocator = std.mem.Allocator;
const git = @import("../git.zig");
const devel = @import("../devel.zig");
const plan_mod = @import("../plan.zig");
const repo_mod = @import("../repo.zig");
const utils = @import("../utils.zig");
const auth_mod = @import("../auth.zig");
const color = @import("../color.zig");
const types = @import("types.zig");
const build_ctx = @import("build_context.zig");

const BuildContext = build_ctx.BuildContext;
const BuildResult = types.BuildResult;
const FailedBuild = types.FailedBuild;

const DEFAULT_CHROOT_DIR = "/var/lib/aurodle/chroot";

fn chrootDir() []const u8 {
    return if (std.c.getenv("CHROOT_DIR")) |p| std.mem.span(p) else DEFAULT_CHROOT_DIR;
}

/// Ensure a clean chroot exists, creating it with mkarchroot if needed.
fn ensureChroot(allocator: Allocator, auth: *auth_mod.Auth, err_writer: anytype, ec: color.Style) !bool {
    if (!utils.findOnPath("makechrootpkg")) {
        err_writer.print("{s}error:{s} makechrootpkg not found -- install devtools: pacman -S devtools\n", .{ ec.red, ec.reset });
        return false;
    }

    const chroot_path = chrootDir();
    const root_path = std.fmt.allocPrint(allocator, "{s}/root", .{chroot_path}) catch return false;
    defer allocator.free(root_path);

    std.Io.Dir.accessAbsolute(utils.currentIo(), root_path, .{}) catch {
        err_writer.print("{s}::{s} creating chroot at {s}...\n", .{ ec.blue, ec.reset, chroot_path });
        const exit_code = try auth.runInteractive(
            &.{ "mkarchroot", root_path, "base-devel" },
            null,
        );
        if (exit_code != 0) {
            err_writer.print("{s}error:{s} failed to create chroot (exit {d})\n", .{ ec.red, ec.reset, exit_code });
            return false;
        }
    };
    return true;
}

/// Package file paths reported by `makepkg --packagelist` for clone_dir,
/// whether or not they exist yet. Null when the command fails or lists
/// nothing. Each run sources makepkg.conf and the PKGBUILD (about half a
/// second), so the build loop runs it once per package and reuses it.
/// Caller frees with freePaths.
fn packageList(allocator: Allocator, clone_dir: []const u8) !?[]const []const u8 {
    const result = try utils.runCommandIn(allocator, &.{ "makepkg", "--packagelist" }, clone_dir);
    defer result.deinit(allocator);
    if (!result.success()) return null;

    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try paths.append(allocator, try allocator.dupe(u8, line));
    }
    if (paths.items.len == 0) {
        paths.deinit(allocator);
        return null;
    }
    return try paths.toOwnedSlice(allocator);
}

fn freePaths(allocator: Allocator, paths: ?[]const []const u8) void {
    const list = paths orelse return;
    for (list) |p| allocator.free(p);
    allocator.free(list);
}

/// True if every file in a packageList result exists, i.e. the build can
/// be skipped.
fn allPackagesBuilt(paths: ?[]const []const u8) bool {
    const list = paths orelse return false;
    for (list) |path| {
        std.Io.Dir.accessAbsolute(utils.currentIo(), path, .{}) catch return false;
    }
    return true;
}

/// The paths from `list` whose file exists and, when `since` is set, was
/// last written at or after it. Null if none qualify. Caller frees with
/// freePaths.
///
/// `since` guards a list computed before the build: if pkgver() changed
/// the version, the listed names are stale and may still match old files
/// in PKGDEST, which must not be added to the repo.
fn existingPaths(allocator: Allocator, list: []const []const u8, since: ?i96) !?[]const []const u8 {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    const cwd = std.Io.Dir.cwd();
    for (list) |path| {
        const stat = cwd.statFile(utils.currentIo(), path, .{}) catch continue;
        if (since) |t| if (stat.mtime.nanoseconds < t) continue;
        try paths.append(allocator, try allocator.dupe(u8, path));
    }
    if (paths.items.len == 0) {
        paths.deinit(allocator);
        return null;
    }
    return try paths.toOwnedSlice(allocator);
}

/// Return the exact package file paths produced by the build in clone_dir.
/// Reuses `list` (from packageList before the build) when it names files
/// written since `since`, or as-is when nothing was built (`since` null);
/// otherwise asks `makepkg --packagelist` again. Returns null when no file
/// is found so callers fall back to the directory-scan approach. Caller
/// frees with freePaths.
fn collectBuiltPackagePaths(
    allocator: Allocator,
    clone_dir: []const u8,
    list: ?[]const []const u8,
    since: ?i96,
) !?[]const []const u8 {
    if (list) |l| {
        if (try existingPaths(allocator, l, since)) |paths| return paths;
    }
    const fresh = try packageList(allocator, clone_dir) orelse return null;
    defer freePaths(allocator, fresh);
    return existingPaths(allocator, fresh, null);
}

/// Build a package inside a clean chroot using makechrootpkg.
/// Injects previously-built AUR dependencies via -I flags so the
/// isolated chroot can satisfy AUR-to-AUR dependency chains.
fn runChrootBuild(
    self: *const BuildContext,
    entry: plan_mod.BuildEntry,
    built_pkg_paths: *const std.StringHashMapUnmanaged([]const []const u8),
    clone_dir: []const u8,
) !u8 {
    const chroot_path = chrootDir();

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(self.allocator);

    try argv.appendSlice(self.allocator, &.{ "makechrootpkg", "-c", "-u", "-r", chroot_path });

    for (entry.aur_dep_bases) |dep_base| {
        if (built_pkg_paths.get(dep_base)) |paths| {
            for (paths) |pkg_path| {
                try argv.appendSlice(self.allocator, &.{ "-I", pkg_path });
            }
        }
    }

    if (self.flags.rebuild) {
        try argv.appendSlice(self.allocator, &.{ "--", "--force" });
    }

    return self.auth.runInteractive(argv.items, clone_dir);
}

/// Build a VCS package in two makepkg passes so a package already in PKGDEST
/// is detected cleanly. A single `makepkg` run can only discover this after
/// pkgver(), and then aborts with "ERROR: A package has already been built"
/// (exit 13).
///   1. `makepkg -s --nobuild`: fetch, extract, prepare(), pkgver(). --nobuild
///      also disables makepkg's own already-built check.
///   2. If every `--packagelist` file exists, skip. Otherwise
///      `makepkg -s --noextract --holdver` builds the prepared tree:
///      --noextract skips download, extraction and prepare(); --holdver is
///      redundant with it but guards against VCS sources moving between passes.
/// With `prepared` set, the `upgrade --devel` version check already did
/// pass 1 and the already-built check (see sourcesStillPrepared), so only
/// pass 2 runs.
/// Returns the makepkg exit code (0 when skipped as already built).
/// When not `prepared`, stores the `--packagelist` result in `pkglist` and
/// sets `skipped` when every listed file already exists.
fn runVcsBuild(
    self: *const BuildContext,
    entry: plan_mod.BuildEntry,
    clone_dir: []const u8,
    prepared: bool,
    pkglist: *?[]const []const u8,
    skipped: *bool,
) !u8 {
    const sc = self.stdout_color;
    const stdout = types.getStdout();

    if (!prepared) {
        stdout.print("{s}::{s} Preparing {s} sources...\n", .{ sc.blue, sc.reset, entry.name });
        const prep_code = try utils.runInteractive(self.allocator, &.{ "makepkg", "-s", "--nobuild", "--noconfirm" }, clone_dir);
        if (prep_code != 0) return prep_code;
    }

    const version = devel.srcinfoVersion(self.allocator, clone_dir) catch null;
    defer if (version) |v| self.allocator.free(v);
    const ver = version orelse "latest";

    if (!prepared) {
        pkglist.* = packageList(self.allocator, clone_dir) catch null;
    }
    if (!prepared and allPackagesBuilt(pkglist.*)) {
        skipped.* = true;
        stdout.print("{s}::{s} {s} {s} already built, skipping (use --rebuild to force)\n", .{ sc.yellow, sc.reset, entry.name, ver });
        return 0;
    }

    stdout.print("{s}::{s} Building {s} {s}...\n", .{ sc.blue, sc.reset, entry.name, ver });
    return utils.runInteractive(self.allocator, &.{ "makepkg", "-s", "--noextract", "--holdver", "--noconfirm" }, clone_dir);
}

/// True if the `upgrade --devel` version check left prepared sources for
/// `name` in clone_dir and no tracked build file changed since (no AUR
/// pull, no edit during review). The check ran `makepkg --nobuild`, which
/// is the first pass of runVcsBuild, so the build can skip it instead of
/// fetching, extracting and running prepare() a second time.
fn sourcesStillPrepared(self: *const BuildContext, name: []const u8, clone_dir: []const u8) bool {
    const stamp = self.devel_prepared.get(name) orelse return false;
    const now = devel.sourceStamp(self.allocator, clone_dir) catch return false;
    return now == stamp;
}

/// True if any of `entry`'s AUR dep pkgbases is in the failed set.
pub fn hasFailedDep(
    entry: plan_mod.BuildEntry,
    failed_bases: *const std.StringHashMapUnmanaged(void),
) bool {
    for (entry.aur_dep_bases) |dep_base| {
        if (failed_bases.contains(dep_base)) return true;
    }
    return false;
}

/// True if any entry in `remaining` lists `pkgbase` as an AUR dep.
pub fn anySubsequentEntryNeeds(remaining: []const plan_mod.BuildEntry, pkgbase: []const u8) bool {
    for (remaining) |future| {
        for (future.aur_dep_bases) |dep_base| {
            if (std.mem.eql(u8, dep_base, pkgbase)) return true;
        }
    }
    return false;
}

/// Run makepkg (or makechrootpkg) for every entry in build order.
/// Propagates failures to downstream entries that depend on a failed pkgbase.
/// Returns a BuildResult that the caller must deinit.
/// Returns error.ChrootUnavailable (after printing why) if --chroot was
/// requested but the chroot could not be set up; nothing was built.
pub fn buildLoop(
    self: *BuildContext,
    plan: plan_mod.BuildPlan,
    repository: *repo_mod.Repository,
    c_root: []const u8,
) !BuildResult {
    const ec = self.stderr_color;
    const sc = self.stdout_color;
    var succeeded: std.ArrayListUnmanaged([]const u8) = .empty;
    var failed: std.ArrayListUnmanaged(FailedBuild) = .empty;
    var failed_bases: std.StringHashMapUnmanaged(void) = .empty;
    defer failed_bases.deinit(self.allocator);
    var all_built_basenames: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (all_built_basenames.items) |b| self.allocator.free(b);
        all_built_basenames.deinit(self.allocator);
    }

    if (self.flags.chroot) {
        // Nothing can be built without a chroot. Returning an empty result
        // here would look like "no failures" and let the caller install
        // every target, so fail the whole build instead.
        if (!try ensureChroot(self.allocator, self.auth, self.err_writer, ec)) {
            return error.ChrootUnavailable;
        }
    }

    // Track built package paths per pkgbase for chroot -I injection.
    // In chroot mode, built AUR deps must be explicitly installed into the
    // clean chroot via makechrootpkg -I since it has no aurpkgs repo.
    var built_pkg_paths: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    defer {
        var it = built_pkg_paths.iterator();
        while (it.next()) |kv| {
            for (kv.value_ptr.*) |p| self.allocator.free(p);
            self.allocator.free(kv.value_ptr.*);
        }
        built_pkg_paths.deinit(self.allocator);
    }

    // Package files already in the repo, for the VCS pre-check below.
    // Listed on first use and dropped after every build, which changes
    // PKGDEST (new files, repo-add -R removing old ones).
    var repo_versions: ?repo_mod.PackageVersions = null;
    defer if (repo_versions) |*v| v.deinit();

    for (plan.build_order, 0..) |entry, i| {
        if (hasFailedDep(entry, &failed_bases)) {
            self.err_writer.print("{s}::{s} skipping {s} -- a dependency failed to build\n", .{ ec.yellow, ec.reset, entry.name });
            try failed_bases.put(self.allocator, entry.pkgbase, {});
            try failed.append(self.allocator, .{ .pkgbase = entry.pkgbase, .exit_code = 0, .skipped = true });
            continue;
        }

        const clone_dir = try git.cloneDir(self.allocator, c_root, entry.pkgbase);
        defer self.allocator.free(clone_dir);

        const ver = self.devel_version_hint.get(entry.name) orelse
            if (devel.isVcsPackage(entry.name)) "latest" else entry.version;

        // Pre-check: skip the build if the output is already available.
        // VCS packages: use the devel-computed version hint to check the local
        // repo directly. makepkg --packagelist is useless before pkgver() runs
        // (it reports the stale cached pkgver). Without a hint, runVcsBuild
        // performs the check between its two makepkg passes instead.
        // Non-VCS packages: check PKGDEST via makepkg --packagelist as usual.
        // The --packagelist result is kept to find the built files
        // afterwards without running makepkg once more.
        const is_vcs = devel.isVcsPackage(entry.name);
        var pkglist: ?[]const []const u8 = null;
        defer freePaths(self.allocator, pkglist);
        if (!is_vcs and !self.flags.rebuild and !self.flags.chroot) {
            pkglist = packageList(self.allocator, clone_dir) catch null;
        }
        var already_built = !self.flags.rebuild and
            !self.flags.chroot and
            if (is_vcs) blk: {
                const hint = self.devel_version_hint.get(entry.name) orelse break :blk false;
                if (repo_versions == null) repo_versions = repository.packageVersions() catch break :blk false;
                break :blk repo_versions.?.contains(entry.name, hint);
            } else allPackagesBuilt(pkglist);

        // Built files are written after this point. The margin absorbs
        // coarse filesystem timestamps; files left by an earlier run are
        // far older.
        const build_start = std.Io.Timestamp.now(self.io, .real).nanoseconds - std.time.ns_per_s;

        if (already_built) {
            types.getStdout().print("{s}::{s} {s} {s} already built, skipping (use --rebuild to force)\n", .{ sc.yellow, sc.reset, entry.name, ver });
        } else {
            const split_vcs = is_vcs and !self.flags.chroot and !self.flags.rebuild;
            if (!split_vcs) {
                types.getStdout().print("{s}::{s} Building {s} {s}...\n", .{ sc.blue, sc.reset, entry.name, ver });
            }

            const exit_code = if (self.flags.chroot) blk: {
                break :blk try runChrootBuild(self, entry, &built_pkg_paths, clone_dir);
            } else if (split_vcs) blk: {
                const prepared = sourcesStillPrepared(self, entry.name, clone_dir);
                break :blk try runVcsBuild(self, entry, clone_dir, prepared, &pkglist, &already_built);
            } else blk: {
                const args: []const []const u8 = if (self.flags.rebuild)
                    &.{ "makepkg", "-sf", "--noconfirm" }
                else
                    &.{ "makepkg", "-s", "--noconfirm" };
                break :blk try utils.runInteractive(self.allocator, args, clone_dir);
            };

            // makepkg ran, so PKGDEST may have changed.
            if (repo_versions) |*v| {
                v.deinit();
                repo_versions = null;
            }

            // exit 13 = E_ALREADY_BUILT: pkgver() ran and updated the PKGBUILD,
            // but the output file already exists in PKGDEST. Fall through to
            // addPackageFiles so the repo DB stays consistent. Mostly avoided
            // by runVcsBuild; kept as a safety net (chroot, pkgver() in
            // packages without a VCS suffix).
            if (exit_code != 0 and exit_code != 13) {
                if (exit_code >= 128) {
                    try failed.append(self.allocator, .{ .pkgbase = entry.pkgbase, .exit_code = exit_code });
                    return .{
                        .succeeded = try succeeded.toOwnedSlice(self.allocator),
                        .failed = try failed.toOwnedSlice(self.allocator),
                        .signal_aborted = true,
                        .built_pkg_basenames = try all_built_basenames.toOwnedSlice(self.allocator),
                    };
                }

                self.err_writer.print("{s}error:{s} build failed for {s} (exit {d})\n", .{
                    ec.red, ec.reset, entry.pkgbase, exit_code,
                });

                try failed.append(self.allocator, .{ .pkgbase = entry.pkgbase, .exit_code = exit_code });
                try failed_bases.put(self.allocator, entry.pkgbase, {});
                continue;
            }
        }

        // Build succeeded — add packages to repo.
        // Use the --packagelist result (reused from before the build when
        // its files are fresh) to get only the files produced by this
        // specific build, avoiding stale old-version files in PKGDEST that
        // would cause repo-add -R to fail (it deletes the old file then can't
        // find it when it also appears in the argument list).
        const since: ?i96 = if (already_built) null else build_start;
        const built_paths = collectBuiltPackagePaths(self.allocator, clone_dir, pkglist, since) catch null;
        defer freePaths(self.allocator, built_paths);

        const added = if (built_paths) |paths|
            repository.addPackageFiles(paths)
        else
            repository.addBuiltPackages();
        const added_files = added catch |err| {
            self.err_writer.print("{s}error:{s} failed to add built packages for {s}: {}\n", .{ ec.red, ec.reset, entry.pkgbase, err });
            try failed.append(self.allocator, .{ .pkgbase = entry.pkgbase, .exit_code = 0 });
            try failed_bases.put(self.allocator, entry.pkgbase, {});
            continue;
        };

        for (added_files) |path| {
            const basename = std.fs.path.basename(path);
            try all_built_basenames.append(self.allocator, try self.allocator.dupe(u8, basename));
        }

        if (self.flags.chroot) {
            try built_pkg_paths.put(self.allocator, entry.pkgbase, added_files);
        } else {
            defer {
                for (added_files) |p| self.allocator.free(p);
                self.allocator.free(added_files);
            }
        }

        // Refresh aurpkgs sync DB only when a subsequent build needs this package.
        // repo-add updated the repo dir DB, but pacman's sync cache
        // (/var/lib/pacman/sync/aurpkgs.db) is root-owned and separate.
        if (anySubsequentEntryNeeds(plan.build_order[i + 1 ..], entry.pkgbase)) {
            repo_mod.refreshAurpkgsSyncDb(self.allocator, repository, self.auth) catch |err| {
                self.err_writer.print("{s}warning:{s} failed to refresh aurpkgs sync db: {}\n", .{ ec.yellow, ec.reset, err });
            };
        }

        try succeeded.append(self.allocator, entry.pkgbase);
    }

    return .{
        .succeeded = try succeeded.toOwnedSlice(self.allocator),
        .failed = try failed.toOwnedSlice(self.allocator),
        .signal_aborted = false,
        .built_pkg_basenames = try all_built_basenames.toOwnedSlice(self.allocator),
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

fn writeWithMtime(dir: std.Io.Dir, name: []const u8, ns: i96) !void {
    try dir.writeFile(testing.io, .{ .sub_path = name, .data = "pkg" });
    const file = try dir.openFile(testing.io, name, .{ .mode = .read_write });
    defer file.close(testing.io);
    try file.setTimestamps(testing.io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = ns } } });
}

test "existingPaths keeps only files written since the build started" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    const start: i96 = 1_000 * std.time.ns_per_s;
    try writeWithMtime(tmp.dir, "new.pkg.tar.zst", start + std.time.ns_per_s);
    try writeWithMtime(tmp.dir, "old.pkg.tar.zst", start - 3600 * std.time.ns_per_s);

    const new_path = try std.fs.path.join(testing.allocator, &.{ root, "new.pkg.tar.zst" });
    defer testing.allocator.free(new_path);
    const old_path = try std.fs.path.join(testing.allocator, &.{ root, "old.pkg.tar.zst" });
    defer testing.allocator.free(old_path);
    const missing_path = try std.fs.path.join(testing.allocator, &.{ root, "debug.pkg.tar.zst" });
    defer testing.allocator.free(missing_path);
    const list: []const []const u8 = &.{ new_path, old_path, missing_path };

    // After a build: the stale file and the missing one are dropped.
    const fresh = (try existingPaths(testing.allocator, list, start)).?;
    defer freePaths(testing.allocator, fresh);
    try testing.expectEqual(@as(usize, 1), fresh.len);
    try testing.expectEqualStrings(new_path, fresh[0]);

    // Nothing built (already-built skip): every existing file counts.
    const existing = (try existingPaths(testing.allocator, list, null)).?;
    defer freePaths(testing.allocator, existing);
    try testing.expectEqual(@as(usize, 2), existing.len);

    // pkgver() moved the version: no listed file is fresh, so the caller
    // must ask makepkg again.
    try testing.expect(try existingPaths(testing.allocator, &.{old_path}, start) == null);

    try testing.expect(allPackagesBuilt(&.{ new_path, old_path }));
    try testing.expect(!allPackagesBuilt(list));
    try testing.expect(!allPackagesBuilt(null));
}
