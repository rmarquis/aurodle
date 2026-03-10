const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("../aur.zig");
const alpm = @import("../alpm.zig");
const git = @import("../git.zig");
const devel = @import("../devel.zig");
const solver_mod = @import("../solver.zig");
const repo_mod = @import("../repo.zig");
const pacman_mod = @import("../pacman.zig");
const utils = @import("../utils.zig");
const cmds = @import("../commands.zig");
const query = @import("query.zig");

const Commands = cmds.Commands;
const ExitCode = cmds.ExitCode;
const BuildResult = cmds.BuildResult;
const FailedBuild = cmds.FailedBuild;
const OutdatedEntry = cmds.OutdatedEntry;
const getStdout = cmds.getStdout;
const getStderr = cmds.getStderr;
const printError = cmds.printError;
const printErr = cmds.printErr;
const handleResolveError = cmds.handleResolveError;
const displayPlan = cmds.displayPlan;

// ── Show Command ─────────────────────────────────────────────────────

/// Display build files for a package clone.
/// Lists files in the clone directory and displays PKGBUILD content.
pub fn show(self: *Commands, target: []const u8) !ExitCode {
    const c_root = self.cache_root orelse blk: {
        break :blk git.defaultCacheRoot(self.allocator) catch {
            printErr("error: could not determine cache directory (HOME not set)\n");
            return .general_error;
        };
    };
    const owns_root = self.cache_root == null;
    defer if (owns_root) self.allocator.free(c_root);

    // Resolve pkgname to pkgbase
    const pkgbase = blk: {
        if (self.aur_client.info(target) catch null) |pkg| {
            break :blk pkg.pkgbase;
        }
        break :blk target;
    };

    // Verify clone exists
    if (!try git.isCloned(self.allocator, c_root, pkgbase)) {
        const stderr = getStderr();
        stderr.print("error: {s} is not cloned. Run 'aurodle sync {s}' first.\n", .{ target, target }) catch {};
        return .general_error;
    }

    const files = try git.listFiles(self.allocator, c_root, pkgbase);
    defer {
        for (files) |f| self.allocator.free(f.name);
        self.allocator.free(files);
    }

    const stdout = getStdout();

    // Display file listing
    stdout.print(":: {s} build files:\n", .{pkgbase}) catch {};
    for (files) |file| {
        const marker: []const u8 = if (file.is_pkgbuild) " (PKGBUILD)" else "";
        stdout.print("  {s}{s}\n", .{ file.name, marker }) catch {};
    }
    stdout.writeByte('\n') catch {};

    // Display PKGBUILD content
    const pkgbuild_content = git.readFile(self.allocator, c_root, pkgbase, "PKGBUILD") catch |err| {
        const stderr = getStderr();
        stderr.print("error: could not read PKGBUILD: {}\n", .{err}) catch {};
        return .general_error;
    };
    defer self.allocator.free(pkgbuild_content);

    stdout.print(":: PKGBUILD:\n{s}\n", .{pkgbuild_content}) catch {};

    return .success;
}

// ── Clone Command ────────────────────────────────────────────────────

/// Clone AUR packages to the cache directory (FR-8).
pub fn clonePackages(self: *Commands, targets: []const []const u8) !ExitCode {
    const stderr = getStderr();
    const stdout = getStdout();

    // Resolve pkgname->pkgbase via AUR RPC
    const packages = self.aur_client.multiInfo(targets) catch |err| {
        try printError(err);
        return .general_error;
    };
    defer self.allocator.free(packages);

    // Build pkgname->pkgbase mapping
    var pkgbase_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer pkgbase_map.deinit(self.allocator);
    for (packages) |pkg| {
        try pkgbase_map.put(self.allocator, pkg.name, pkg.pkgbase);
    }

    // Check for missing packages
    var any_error = false;
    for (targets) |target| {
        if (!pkgbase_map.contains(target)) {
            stderr.print("error: package '{s}' was not found\n", .{target}) catch {};
            any_error = true;
        }
    }

    // Get cache root
    const c_root = self.cache_root orelse blk: {
        break :blk git.defaultCacheRoot(self.allocator) catch {
            stderr.writeAll("error: could not determine cache directory (HOME not set)\n") catch {};
            return .general_error;
        };
    };
    const owns_root = self.cache_root == null;
    defer if (owns_root) self.allocator.free(c_root);

    // Clone each resolved package
    var cloned_set: std.StringHashMapUnmanaged(void) = .empty;
    defer cloned_set.deinit(self.allocator);

    for (targets) |target| {
        const pkgbase = pkgbase_map.get(target) orelse continue;

        if (cloned_set.contains(pkgbase)) continue;
        try cloned_set.put(self.allocator, pkgbase, {});

        const result = git.clone(self.allocator, c_root, pkgbase) catch {
            stderr.print("error: failed to clone '{s}'\n", .{pkgbase}) catch {};
            any_error = true;
            continue;
        };

        if (!self.flags.quiet) {
            switch (result) {
                .cloned => stdout.print("cloned '{s}'\n", .{pkgbase}) catch {},
                .already_exists => stdout.print("'{s}' already cloned\n", .{pkgbase}) catch {},
            }
        }
    }

    return if (any_error) .general_error else .success;
}

// ── Sync Command ─────────────────────────────────────────────────────

/// Execute the full sync workflow: resolve -> clone -> review -> build -> install.
pub fn sync(self: *Commands, targets: []const []const u8) !ExitCode {
    const reg = self.registry orelse {
        printErr("error: registry not initialized\n");
        return .general_error;
    };
    const repository = self.repo orelse {
        printErr("error: repository not initialized\n");
        return .general_error;
    };
    const c_root = self.cache_root orelse {
        printErr("error: cache root not set\n");
        return .general_error;
    };

    // Phase 1: Resolve
    var s = solver_mod.Solver.init(self.allocator, reg);
    s.rebuild = self.flags.rebuild;
    defer s.deinit();

    const plan = s.resolve(targets) catch |err| {
        return handleResolveError(err);
    };
    defer plan.deinit(self.allocator);

    if (plan.build_order.len == 0) {
        // Check for targets available in aurpkgs: either not installed (repo_aur)
        // or already installed (satisfied_aur) — reinstall like pacman -S would.
        var aurpkgs_targets: std.ArrayListUnmanaged([]const u8) = .empty;
        defer aurpkgs_targets.deinit(self.allocator);
        for (plan.all_deps) |dep| {
            if (!dep.is_target) continue;
            if (dep.source == .repo_aur) {
                try aurpkgs_targets.append(self.allocator, dep.name);
            } else if (dep.source == .satisfied_aur) {
                // Reinstall if available in aurpkgs repo
                if (self.pacman) |pm| {
                    if (pm.isAurRepo(pm.syncDbFor(dep.name) orelse "")) {
                        try aurpkgs_targets.append(self.allocator, dep.name);
                    }
                }
            }
        }
        if (aurpkgs_targets.items.len > 0 or plan.repo_targets.len > 0) {
            try installAllTargets(self, aurpkgs_targets.items, plan.repo_targets);
        }
        if (aurpkgs_targets.items.len == 0 and plan.repo_targets.len == 0) {
            getStdout().writeAll(" nothing to do -- all targets are up to date\n") catch {};
        }
        return .success;
    }

    // Phase 2: Display and confirm
    displayPlan(plan, self.pacman);

    if (!self.flags.noconfirm) {
        if (!try utils.promptYesNo("Proceed with installation?")) {
            return .success;
        }
    }

    // Phase 3: Clone
    for (plan.build_order) |entry| {
        _ = git.cloneOrUpdate(self.allocator, c_root, entry.pkgbase) catch |err| {
            const stderr = getStderr();
            stderr.print("error: failed to clone/update '{s}': {}\n", .{ entry.pkgbase, err }) catch {};
            return .general_error;
        };
    }

    // Phase 4: Review (unless --noshow)
    if (!self.flags.noshow) {
        try reviewPackages(self, plan.build_order, c_root);
    }

    // Phase 5: Build
    try repository.ensureExists();
    const build_result = try buildLoop(self, plan, repository, c_root);
    defer build_result.deinit(self.allocator);

    if (build_result.signal_aborted) {
        return .signal_killed;
    }

    // Phase 6: Install targets (AUR from aurpkgs + repo targets in one transaction)
    var aur_targets: std.ArrayListUnmanaged([]const u8) = .empty;
    defer aur_targets.deinit(self.allocator);
    for (plan.build_order) |entry| {
        if (entry.is_target) try aur_targets.append(self.allocator, entry.name);
    }

    if (build_result.failed.len == 0) {
        try installAllTargets(self, aur_targets.items, plan.repo_targets);
    } else {
        // Install only targets whose builds succeeded
        const installable = try filterInstallable(self, aur_targets.items, build_result);
        defer self.allocator.free(installable);
        if (installable.len > 0 or plan.repo_targets.len > 0) {
            try installAllTargets(self, installable, plan.repo_targets);
        }
        printBuildSummary(build_result);
        return .build_failed;
    }

    return .success;
}

// ── Build Command ────────────────────────────────────────────────────

/// Build packages and add to repository without installing.
pub fn build(self: *Commands, targets: []const []const u8) !ExitCode {
    const reg = self.registry orelse {
        printErr("error: registry not initialized\n");
        return .general_error;
    };
    const repository = self.repo orelse {
        printErr("error: repository not initialized\n");
        return .general_error;
    };
    const c_root = self.cache_root orelse {
        printErr("error: cache root not set\n");
        return .general_error;
    };

    var s = solver_mod.Solver.init(self.allocator, reg);
    s.rebuild = self.flags.rebuild;
    defer s.deinit();

    const plan = s.resolve(targets) catch |err| {
        return handleResolveError(err);
    };
    defer plan.deinit(self.allocator);

    if (plan.build_order.len == 0) {
        getStdout().writeAll(" nothing to do -- all targets are up to date\n") catch {};
        return .success;
    }

    displayPlan(plan, self.pacman);

    if (!self.flags.noconfirm) {
        if (!try utils.promptYesNo("Proceed with build?")) {
            return .success;
        }
    }

    // Clone
    for (plan.build_order) |entry| {
        _ = git.cloneOrUpdate(self.allocator, c_root, entry.pkgbase) catch |err| {
            const stderr = getStderr();
            stderr.print("error: failed to clone/update '{s}': {}\n", .{ entry.pkgbase, err }) catch {};
            return .general_error;
        };
    }

    // Review
    if (!self.flags.noshow) {
        try reviewPackages(self, plan.build_order, c_root);
    }

    // Build
    try repository.ensureExists();
    const result = try buildLoop(self, plan, repository, c_root);
    defer result.deinit(self.allocator);

    if (result.signal_aborted) return .signal_killed;
    if (result.failed.len > 0) {
        printBuildSummary(result);
        return .build_failed;
    }

    return .success;
}

// ── Upgrade Command ──────────────────────────────────────────────────

/// Upgrade outdated AUR packages via the full sync workflow.
/// With no arguments: upgrade all outdated AUR packages.
/// With arguments: upgrade only the specified packages.
pub fn upgrade(self: *Commands, targets: []const []const u8) !ExitCode {
    const pm = self.pacman orelse {
        printErr("error: pacman not initialized\n");
        return .general_error;
    };

    const foreign = try pm.allForeignPackages();
    defer self.allocator.free(foreign);

    // Apply name filter if provided
    const to_check = if (targets.len > 0) blk: {
        var name_set: std.StringHashMapUnmanaged(void) = .empty;
        defer name_set.deinit(self.allocator);
        for (targets) |n| try name_set.put(self.allocator, n, {});

        var filtered: std.ArrayListUnmanaged(pacman_mod.InstalledPackage) = .empty;
        for (foreign) |pkg| {
            if (name_set.contains(pkg.name)) try filtered.append(self.allocator, pkg);
        }
        break :blk try filtered.toOwnedSlice(self.allocator);
    } else foreign;
    defer if (targets.len > 0) self.allocator.free(to_check);

    // Batch query AUR
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(self.allocator);
    for (to_check) |pkg| try names.append(self.allocator, pkg.name);

    const aur_pkgs = self.aur_client.multiInfo(names.items) catch |err| {
        try printError(err);
        return .general_error;
    };
    defer self.allocator.free(aur_pkgs);

    var aur_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer aur_map.deinit(self.allocator);
    for (aur_pkgs) |pkg| try aur_map.put(self.allocator, pkg.name, pkg.version);

    // Find outdated
    var to_upgrade: std.ArrayListUnmanaged([]const u8) = .empty;
    defer to_upgrade.deinit(self.allocator);
    var outdated_display: std.ArrayListUnmanaged(OutdatedEntry) = .empty;
    defer outdated_display.deinit(self.allocator);

    // Track which packages are already queued for upgrade
    var upgrade_set: std.StringHashMapUnmanaged(void) = .empty;
    defer upgrade_set.deinit(self.allocator);

    for (to_check) |pkg| {
        const dominated_by_aur = if (aur_map.get(pkg.name)) |aur_ver|
            alpm.vercmp(pkg.version, aur_ver) < 0
        else
            false;

        if (dominated_by_aur or self.flags.rebuild) {
            try to_upgrade.append(self.allocator, pkg.name);
            try upgrade_set.put(self.allocator, pkg.name, {});
            if (aur_map.get(pkg.name)) |aur_ver| {
                try outdated_display.append(self.allocator, .{
                    .name = pkg.name,
                    .installed_version = pkg.version,
                    .aur_version = aur_ver,
                });
            }
        }
    }

    // --devel: check VCS packages for upstream updates
    if (self.flags.devel) {
        try checkDevelUpgrades(self, to_check, &upgrade_set, &to_upgrade, &outdated_display);
    }

    if (to_upgrade.items.len == 0) {
        getStdout().writeAll(" all AUR packages are up to date\n") catch {};
        return .success;
    }

    // Display what will be upgraded
    const stdout = getStdout();
    stdout.print(":: {d} package(s) to upgrade:\n", .{outdated_display.items.len}) catch {};
    query.formatOutdated(outdated_display.items);

    // Delegate to sync for the actual build+install workflow
    return sync(self, to_upgrade.items);
}

// ── Devel Upgrade Check ──────────────────────────────────────────────

/// Check VCS packages for upstream updates and add outdated ones to upgrade lists.
fn checkDevelUpgrades(
    self: *Commands,
    packages: []const pacman_mod.InstalledPackage,
    upgrade_set: *std.StringHashMapUnmanaged(void),
    to_upgrade: *std.ArrayListUnmanaged([]const u8),
    outdated_display: *std.ArrayListUnmanaged(OutdatedEntry),
) !void {
    const c_root = self.cache_root orelse blk: {
        break :blk git.defaultCacheRoot(self.allocator) catch {
            getStderr().writeAll("warning: could not determine cache directory for --devel check\n") catch {};
            return;
        };
    };
    const owns_root = self.cache_root == null;
    defer if (owns_root) self.allocator.free(c_root);

    // Collect allocated version strings for cleanup
    var devel_versions: std.ArrayListUnmanaged(devel.VcsVersionResult) = .empty;
    defer {
        for (devel_versions.items) |v| v.deinit();
        devel_versions.deinit(self.allocator);
    }

    for (packages) |pkg| {
        if (!devel.isVcsPackage(pkg.name)) continue;
        if (upgrade_set.contains(pkg.name)) continue;

        if (!self.flags.quiet) {
            getStderr().print(":: checking {s}...\n", .{pkg.name}) catch {};
        }

        const vcs_result = devel.checkVersion(self.allocator, c_root, pkg.name) catch {
            getStderr().print("warning: failed to check VCS version for {s}\n", .{pkg.name}) catch {};
            continue;
        };

        const result = vcs_result orelse continue;
        try devel_versions.append(self.allocator, result);

        if (alpm.vercmp(pkg.version, result.version) < 0) {
            try to_upgrade.append(self.allocator, pkg.name);
            try upgrade_set.put(self.allocator, pkg.name, {});
            try outdated_display.append(self.allocator, .{
                .name = pkg.name,
                .installed_version = pkg.version,
                .aur_version = result.version,
            });
        }
    }
}

// ── Clean Command ────────────────────────────────────────────────────

/// Remove stale aurpkgs artifacts after user confirmation.
/// Checks the aurpkgs database for packages no longer installed locally,
/// then removes their clone directories, package files, and database entries.
pub fn clean(self: *Commands) !ExitCode {
    const pm = self.pacman orelse {
        printErr("error: pacman not initialized\n");
        return .general_error;
    };
    const repository = self.repo orelse {
        printErr("error: repository not initialized\n");
        return .general_error;
    };

    // Find aurpkgs packages that are no longer installed
    const uninstalled = pm.uninstalledAurpkgs() catch |err| switch (err) {
        error.AurDbNotConfigured => {
            printErr("error: local AUR repository not configured in pacman.conf\n");
            return .general_error;
        },
        else => return err,
    };
    defer self.allocator.free(uninstalled);

    const plan = try repository.clean(uninstalled);
    defer repository.freeCleanResult(plan);

    if (plan.removed_clones.len == 0 and plan.removed_packages.len == 0) {
        if (!self.flags.quiet) {
            getStdout().writeAll(" nothing to clean\n") catch {};
        }
        return .success;
    }

    const stdout = getStdout();

    if (plan.removed_packages.len > 0) {
        stdout.print(":: Stale packages ({d}):\n", .{plan.removed_packages.len}) catch {};
        for (plan.removed_packages) |filename| {
            stdout.print("  {s}\n", .{filename}) catch {};
        }
    }

    if (plan.removed_clones.len > 0) {
        stdout.print(":: Stale clone directories ({d}):\n", .{plan.removed_clones.len}) catch {};
        for (plan.removed_clones) |name| {
            stdout.print("  {s}/\n", .{name}) catch {};
        }
    }

    if (!self.flags.noconfirm) {
        if (!try utils.promptYesNo("Proceed with cleanup?")) {
            return .success;
        }
    }

    repository.cleanExecute(plan);

    // Refresh pacman's sync copy of the aurpkgs database.
    // repo-remove modified the db in repo_dir, but pacman reads from
    // /var/lib/pacman/sync/ which is a separate root-owned copy.
    if (plan.removed_packages.len > 0) {
        refreshAurpkgsSyncDb(self.allocator, repository) catch |err| {
            getStderr().print("warning: failed to refresh aurpkgs sync db: {}\n", .{err}) catch {};
        };
    }

    return .success;
}

// ── Build Loop ───────────────────────────────────────────────────────

fn buildLoop(
    self: *Commands,
    plan: solver_mod.BuildPlan,
    repository: *repo_mod.Repository,
    c_root: []const u8,
) !BuildResult {
    var succeeded: std.ArrayListUnmanaged([]const u8) = .empty;
    var failed: std.ArrayListUnmanaged(FailedBuild) = .empty;
    var failed_bases: std.StringHashMapUnmanaged(void) = .empty;
    defer failed_bases.deinit(self.allocator);

    for (plan.build_order, 0..) |entry, i| {
        // Skip if a dependency failed, propagating failure to downstream entries
        if (hasFailedDep(entry, &failed_bases)) {
            getStderr().print(":: skipping {s} -- a dependency failed to build\n", .{entry.name}) catch {};
            try failed_bases.put(self.allocator, entry.pkgbase, {});
            continue;
        }

        const clone_dir = try git.cloneDir(self.allocator, c_root, entry.pkgbase);
        defer self.allocator.free(clone_dir);

        getStdout().print(":: building {s} {s}...\n", .{ entry.name, entry.version }) catch {};

        // Run makepkg -s (--syncdeps installs missing deps as --asdeps)
        const makepkg_args: []const []const u8 = if (self.flags.rebuild)
            &.{ "makepkg", "-sf", "--noconfirm" }
        else
            &.{ "makepkg", "-s", "--noconfirm" };
        const exit_code = try utils.runInteractive(
            self.allocator,
            makepkg_args,
            clone_dir,
        );

        if (exit_code != 0) {
            // Signal-killed (e.g., Ctrl+C -> SIGINT -> exit 130)
            if (exit_code >= 128) {
                try failed.append(self.allocator, .{
                    .pkgbase = entry.pkgbase,
                    .exit_code = exit_code,
                });
                return .{
                    .succeeded = try succeeded.toOwnedSlice(self.allocator),
                    .failed = try failed.toOwnedSlice(self.allocator),
                    .signal_aborted = true,
                };
            }

            getStderr().print("error: build failed for {s} (exit {d})\n", .{
                entry.pkgbase,
                exit_code,
            }) catch {};

            try failed.append(self.allocator, .{
                .pkgbase = entry.pkgbase,
                .exit_code = exit_code,
            });
            try failed_bases.put(self.allocator, entry.pkgbase, {});
            continue;
        }

        // Build succeeded — add packages to repo
        const added = repository.addBuiltPackages() catch |err| {
            getStderr().print("error: failed to add built packages for {s}: {}\n", .{ entry.pkgbase, err }) catch {};
            try failed.append(self.allocator, .{
                .pkgbase = entry.pkgbase,
                .exit_code = 0,
            });
            try failed_bases.put(self.allocator, entry.pkgbase, {});
            continue;
        };
        defer {
            for (added) |p| self.allocator.free(p);
            self.allocator.free(added);
        }

        // Refresh aurpkgs sync DB only when a subsequent build needs this package.
        // repo-add updated the repo dir DB, but pacman's sync cache
        // (/var/lib/pacman/sync/aurpkgs.db) is root-owned and separate.
        if (anySubsequentEntryNeeds(plan.build_order[i + 1 ..], entry.pkgbase)) {
            refreshAurpkgsSyncDb(self.allocator, repository) catch |err| {
                getStderr().print("warning: failed to refresh aurpkgs sync db: {}\n", .{err}) catch {};
            };
        }

        try succeeded.append(self.allocator, entry.pkgbase);
    }

    return .{
        .succeeded = try succeeded.toOwnedSlice(self.allocator),
        .failed = try failed.toOwnedSlice(self.allocator),
        .signal_aborted = false,
    };
}

pub fn hasFailedDep(
    entry: solver_mod.BuildEntry,
    failed_bases: *const std.StringHashMapUnmanaged(void),
) bool {
    for (entry.aur_dep_bases) |dep_base| {
        if (failed_bases.contains(dep_base)) return true;
    }
    return false;
}

/// Check whether any entry in `remaining` has `pkgbase` in its aur_dep_bases.
fn anySubsequentEntryNeeds(remaining: []const solver_mod.BuildEntry, pkgbase: []const u8) bool {
    for (remaining) |future| {
        for (future.aur_dep_bases) |dep_base| {
            if (std.mem.eql(u8, dep_base, pkgbase)) return true;
        }
    }
    return false;
}

// ── Review ───────────────────────────────────────────────────────────

fn reviewPackages(
    self: *Commands,
    entries: []const solver_mod.BuildEntry,
    c_root: []const u8,
) !void {
    const stdout = getStdout();
    const editor = getEditor();

    for (entries) |entry| {
        const clone_dir = try git.cloneDir(self.allocator, c_root, entry.pkgbase);
        defer self.allocator.free(clone_dir);

        const is_update = git.hasOrigHead(self.allocator, c_root, entry.pkgbase) catch false;

        if (is_update) {
            // Updated clone — show diff interactively
            const msg = try std.fmt.allocPrint(self.allocator, "View {s} diff?", .{entry.pkgbase});
            defer self.allocator.free(msg);

            if (try utils.promptYesNo(msg)) {
                const exit_code = utils.runInteractive(
                    self.allocator,
                    &.{ "git", "diff", "ORIG_HEAD..HEAD" },
                    clone_dir,
                ) catch {
                    stdout.writeAll("  (could not show diff)\n") catch {};
                    continue;
                };
                _ = exit_code;
                stdout.print(":: {s} diff reviewed\n", .{entry.pkgbase}) catch {};
            }
        } else {
            // Fresh clone — open all files in editor
            const msg = try std.fmt.allocPrint(self.allocator, "Review {s} files?", .{entry.pkgbase});
            defer self.allocator.free(msg);

            if (try utils.promptYesNo(msg)) {
                const exit_code = utils.runInteractive(
                    self.allocator,
                    &.{ editor, clone_dir },
                    null,
                ) catch {
                    stdout.writeAll("  (could not open editor)\n") catch {};
                    continue;
                };

                if (exit_code != 0) {
                    stdout.print("  editor exited with {d}\n", .{exit_code}) catch {};
                }
                stdout.print(":: {s} files reviewed\n", .{entry.pkgbase}) catch {};
            }
        }
    }
}

fn getEditor() []const u8 {
    if (std.posix.getenv("VISUAL")) |v| if (v.len > 0) return v;
    if (std.posix.getenv("EDITOR")) |e| if (e.len > 0) return e;
    return "vim";
}

// ── Install ──────────────────────────────────────────────────────────

/// Install AUR targets (from aurpkgs) and repo targets (from their sync db)
/// in a single `pacman -S` transaction.
fn installAllTargets(self: *Commands, aurpkgs_names: []const []const u8, repo_names: []const []const u8) !void {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(self.allocator);

    try argv.appendSlice(self.allocator, &.{ "pacman", "-S" });

    if (self.flags.asdeps) {
        try argv.append(self.allocator, "--asdeps");
    } else if (self.flags.asexplicit) {
        try argv.append(self.allocator, "--asexplicit");
    }

    if (self.flags.noconfirm) {
        try argv.append(self.allocator, "--noconfirm");
    }

    var qualified_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (qualified_names.items) |q| self.allocator.free(q);
        qualified_names.deinit(self.allocator);
    }

    // AUR targets qualified with the local AUR repo name (e.g., aurpkgs/pkgname)
    const aur_repo_name = if (self.repo) |r| r.repo_name else repo_mod.DEFAULT_REPO_NAME;
    for (aurpkgs_names) |name| {
        const qualified = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ aur_repo_name, name });
        try qualified_names.append(self.allocator, qualified);
        try argv.append(self.allocator, qualified);
    }

    // Repo targets qualified with their actual sync db (e.g., extra/expac)
    for (repo_names) |name| {
        const repo = if (self.pacman) |pm| pm.syncDbFor(name) else null;
        if (repo) |r| {
            const qualified = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ r, name });
            try qualified_names.append(self.allocator, qualified);
            try argv.append(self.allocator, qualified);
        } else {
            try argv.append(self.allocator, name);
        }
    }

    const exit_code = try utils.runSudoInteractive(self.allocator, argv.items);

    if (exit_code != 0) {
        getStderr().print("error: installation failed (exit {d})\n", .{exit_code}) catch {};
    }
}

fn filterInstallable(
    self: *Commands,
    targets: []const []const u8,
    result: BuildResult,
) ![]const []const u8 {
    var failed_set: std.StringHashMapUnmanaged(void) = .empty;
    defer failed_set.deinit(self.allocator);
    for (result.failed) |f| {
        try failed_set.put(self.allocator, f.pkgbase, {});
    }

    var installable: std.ArrayListUnmanaged([]const u8) = .empty;
    for (targets) |target| {
        if (!failed_set.contains(target)) {
            try installable.append(self.allocator, target);
        }
    }
    return try installable.toOwnedSlice(self.allocator);
}

fn printBuildSummary(result: BuildResult) void {
    const stderr = getStderr();
    stderr.print("\n:: Build summary: {d} succeeded, {d} failed\n", .{
        result.succeeded.len,
        result.failed.len,
    }) catch {};
    for (result.failed) |f| {
        stderr.print("  FAILED: {s} (exit {d})\n", .{
            f.pkgbase,
            f.exit_code,
        }) catch {};
    }
}

/// Copy the local AUR repo DB to pacman's sync cache so that subsequent
/// makepkg -s calls (which spawn their own pacman) see just-built packages.
/// Only touches the local AUR repo entry — official repo DBs are left untouched.
fn refreshAurpkgsSyncDb(allocator: Allocator, repository: *repo_mod.Repository) !void {
    const sync_db_path = try std.fmt.allocPrint(allocator, "/var/lib/pacman/sync/{s}.db", .{repository.repo_name});
    defer allocator.free(sync_db_path);
    const result = try utils.runSudo(allocator, &.{ "cp", repository.db_path, sync_db_path });
    defer result.deinit(allocator);
    if (!result.success()) return error.SyncDbRefreshFailed;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "hasFailedDep returns false for empty failed set" {
    const entry = solver_mod.BuildEntry{
        .name = "foo",
        .pkgbase = "foo",
        .version = "1.0",
        .is_target = true,
        .aur_dep_bases = &.{},
    };
    var failed: std.StringHashMapUnmanaged(void) = .empty;
    try testing.expect(!hasFailedDep(entry, &failed));
}

test "hasFailedDep returns true when aur dep pkgbase is failed" {
    const entry = solver_mod.BuildEntry{
        .name = "foo",
        .pkgbase = "foo",
        .version = "1.0",
        .is_target = true,
        .aur_dep_bases = &.{"bar"},
    };
    var failed: std.StringHashMapUnmanaged(void) = .empty;
    defer failed.deinit(testing.allocator);
    try failed.put(testing.allocator, "bar", {});
    try testing.expect(hasFailedDep(entry, &failed));
}

test "hasFailedDep returns false when unrelated pkgbase is failed" {
    const entry = solver_mod.BuildEntry{
        .name = "foo",
        .pkgbase = "foo",
        .version = "1.0",
        .is_target = true,
        .aur_dep_bases = &.{"bar"},
    };
    var failed: std.StringHashMapUnmanaged(void) = .empty;
    defer failed.deinit(testing.allocator);
    try failed.put(testing.allocator, "baz", {});
    try testing.expect(!hasFailedDep(entry, &failed));
}

test "anySubsequentEntryNeeds returns true when future entry depends on pkgbase" {
    const entries = [_]solver_mod.BuildEntry{
        .{ .name = "B", .pkgbase = "B", .version = "1.0", .is_target = false, .aur_dep_bases = &.{"A"} },
        .{ .name = "C", .pkgbase = "C", .version = "1.0", .is_target = true, .aur_dep_bases = &.{"B"} },
    };
    try testing.expect(anySubsequentEntryNeeds(&entries, "A"));
    try testing.expect(anySubsequentEntryNeeds(entries[1..], "B"));
}

test "anySubsequentEntryNeeds returns false when no future entry depends on pkgbase" {
    const entries = [_]solver_mod.BuildEntry{
        .{ .name = "B", .pkgbase = "B", .version = "1.0", .is_target = false, .aur_dep_bases = &.{"A"} },
        .{ .name = "C", .pkgbase = "C", .version = "1.0", .is_target = true, .aur_dep_bases = &.{} },
    };
    // Nothing depends on "B"
    try testing.expect(!anySubsequentEntryNeeds(&entries, "B"));
    // Empty remaining slice
    try testing.expect(!anySubsequentEntryNeeds(entries[2..], "A"));
}

test "upgrade returns general_error when pacman not initialized" {
    var cmd = Commands.init(testing.allocator, undefined, .{});
    const result = try upgrade(&cmd, &.{});
    try testing.expectEqual(ExitCode.general_error, result);
}

test "clean returns general_error when pacman not initialized" {
    var cmd = Commands.init(testing.allocator, undefined, .{});
    const result = try clean(&cmd);
    try testing.expectEqual(ExitCode.general_error, result);
}
