/// Build phase: invoke makepkg or makechrootpkg per plan entry, add built
/// packages to the local repo, and propagate failures to downstream entries.
const std = @import("std");
const Allocator = std.mem.Allocator;
const git = @import("../../git.zig");
const devel = @import("../../devel.zig");
const plan_mod = @import("../../plan.zig");
const repo_mod = @import("../../repo.zig");
const utils = @import("../../utils.zig");
const auth_mod = @import("../../auth.zig");
const color = @import("../../color.zig");
const cmds = @import("../context.zig");

const Commands = cmds.Commands;
const BuildResult = cmds.BuildResult;
const FailedBuild = cmds.FailedBuild;

const DEFAULT_CHROOT_DIR = "/var/lib/aurodle/chroot";

fn chrootDir() []const u8 {
    return std.posix.getenv("CHROOT_DIR") orelse DEFAULT_CHROOT_DIR;
}

/// Ensure a clean chroot exists, creating it with mkarchroot if needed.
fn ensureChroot(allocator: Allocator, auth: *auth_mod.Auth, err_writer: anytype, ec: color.Style) !bool {
    if (!utils.findOnPath("makechrootpkg")) {
        err_writer.print("{s}error:{s} makechrootpkg not found -- install devtools: pacman -S devtools\n", .{ ec.red, ec.reset }) catch {};
        return false;
    }

    const chroot_path = chrootDir();
    const root_path = std.fmt.allocPrint(allocator, "{s}/root", .{chroot_path}) catch return false;
    defer allocator.free(root_path);

    std.fs.accessAbsolute(root_path, .{}) catch {
        err_writer.print("{s}::{s} creating chroot at {s}...\n", .{ ec.blue, ec.reset, chroot_path }) catch {};
        const exit_code = try auth.runInteractive(
            &.{ "mkarchroot", root_path, "base-devel" },
            null,
        );
        if (exit_code != 0) {
            err_writer.print("{s}error:{s} failed to create chroot (exit {d})\n", .{ ec.red, ec.reset, exit_code }) catch {};
            return false;
        }
    };
    return true;
}

/// Returns true if every package file listed by `makepkg --packagelist` already
/// exists on disk. When true the build can be skipped entirely.
fn allPackagesBuilt(allocator: Allocator, clone_dir: []const u8) !bool {
    const result = try utils.runCommandIn(allocator, &.{ "makepkg", "--packagelist" }, clone_dir);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.exit_code != 0) return false;

    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, result.stdout, "\n"), '\n');
    var found_any = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        found_any = true;
        std.fs.accessAbsolute(line, .{}) catch return false;
    }
    return found_any;
}

/// Return the exact package file paths produced by the build in clone_dir,
/// as reported by `makepkg --packagelist`. Only paths that exist on disk
/// are included. Returns null when --packagelist fails so callers fall back
/// to the directory-scan approach. Caller owns the returned slice and strings.
fn collectBuiltPackagePaths(allocator: Allocator, clone_dir: []const u8) !?[]const []const u8 {
    const result = try utils.runCommandIn(allocator, &.{ "makepkg", "--packagelist" }, clone_dir);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.exit_code != 0) return null;

    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, result.stdout, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        std.fs.accessAbsolute(line, .{}) catch continue;
        try paths.append(allocator, try allocator.dupe(u8, line));
    }

    if (paths.items.len == 0) return null;
    return try paths.toOwnedSlice(allocator);
}

/// Build a package inside a clean chroot using makechrootpkg.
/// Injects previously-built AUR dependencies via -I flags so the
/// isolated chroot can satisfy AUR-to-AUR dependency chains.
fn runChrootBuild(
    self: *const Commands,
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

    return self.auth.?.runInteractive(argv.items, clone_dir);
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
pub fn buildLoop(
    self: *Commands,
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
        if (!try ensureChroot(self.allocator, self.auth.?, self.err_writer, ec)) {
            return .{
                .succeeded = try succeeded.toOwnedSlice(self.allocator),
                .failed = try failed.toOwnedSlice(self.allocator),
                .signal_aborted = false,
                .built_pkg_basenames = try all_built_basenames.toOwnedSlice(self.allocator),
            };
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

    for (plan.build_order, 0..) |entry, i| {
        if (hasFailedDep(entry, &failed_bases)) {
            self.err_writer.print("{s}::{s} skipping {s} -- a dependency failed to build\n", .{ ec.yellow, ec.reset, entry.name }) catch {};
            try failed_bases.put(self.allocator, entry.pkgbase, {});
            continue;
        }

        const clone_dir = try git.cloneDir(self.allocator, c_root, entry.pkgbase);
        defer self.allocator.free(clone_dir);

        const ver = self.devel_version_hint.get(entry.name) orelse
            if (devel.isVcsPackage(entry.name)) "latest" else entry.version;

        // Pre-check: skip the build if the output is already available.
        // VCS packages: use the devel-computed version hint to check the local
        // repo directly. makepkg --packagelist is useless before pkgver() runs
        // (it reports the stale cached pkgver). Without a hint the check is
        // skipped and exit 13 handling acts as the safety net instead.
        // Non-VCS packages: check PKGDEST via makepkg --packagelist as usual.
        const already_built = !self.flags.rebuild and
            !self.flags.chroot and
            if (devel.isVcsPackage(entry.name)) blk: {
                const hint = self.devel_version_hint.get(entry.name) orelse break :blk false;
                break :blk repository.hasPackageVersion(entry.name, hint);
            } else (allPackagesBuilt(self.allocator, clone_dir) catch false);

        if (already_built) {
            cmds.getStdout().print("{s}::{s} {s} {s} already built, skipping (use --rebuild to force)\n", .{ sc.yellow, sc.reset, entry.name, ver }) catch {};
        } else {
            cmds.getStdout().print("{s}::{s} Building {s} {s}...\n", .{ sc.blue, sc.reset, entry.name, ver }) catch {};

            const exit_code = if (self.flags.chroot) blk: {
                break :blk try runChrootBuild(self, entry, &built_pkg_paths, clone_dir);
            } else blk: {
                const args: []const []const u8 = if (self.flags.rebuild)
                    &.{ "makepkg", "-sf", "--noconfirm" }
                else
                    &.{ "makepkg", "-s", "--noconfirm" };
                break :blk try utils.runInteractive(self.allocator, args, clone_dir);
            };

            // exit 13 = E_ALREADY_BUILT: pkgver() ran and updated the PKGBUILD,
            // but the output file already exists in PKGDEST. Fall through to
            // addPackageFiles so the repo DB stays consistent.
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
                }) catch {};

                try failed.append(self.allocator, .{ .pkgbase = entry.pkgbase, .exit_code = exit_code });
                try failed_bases.put(self.allocator, entry.pkgbase, {});
                continue;
            }
        }

        // Build succeeded — add packages to repo.
        // Use makepkg --packagelist to get only the files produced by this
        // specific build, avoiding stale old-version files in PKGDEST that
        // would cause repo-add -R to fail (it deletes the old file then can't
        // find it when it also appears in the argument list).
        const built_paths = collectBuiltPackagePaths(self.allocator, clone_dir) catch null;
        defer if (built_paths) |paths| {
            for (paths) |p| self.allocator.free(p);
            self.allocator.free(paths);
        };

        const added = if (built_paths) |paths|
            repository.addPackageFiles(paths)
        else
            repository.addBuiltPackages();
        const added_files = added catch |err| {
            self.err_writer.print("{s}error:{s} failed to add built packages for {s}: {}\n", .{ ec.red, ec.reset, entry.pkgbase, err }) catch {};
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
            repo_mod.refreshAurpkgsSyncDb(self.allocator, repository, self.auth.?) catch |err| {
                self.err_writer.print("{s}warning:{s} failed to refresh aurpkgs sync db: {}\n", .{ ec.yellow, ec.reset, err }) catch {};
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
