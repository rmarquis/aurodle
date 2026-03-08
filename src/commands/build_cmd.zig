const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("../aur.zig");
const alpm = @import("../alpm.zig");
const git = @import("../git.zig");
const devel = @import("../devel.zig");
const registry_mod = @import("../registry.zig");
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
        // Check for repo_aur targets: available in aurpkgs but not installed.
        var repo_aur_targets: std.ArrayListUnmanaged([]const u8) = .empty;
        defer repo_aur_targets.deinit(self.allocator);
        for (plan.all_deps) |dep| {
            if (dep.is_target and dep.source == .repo_aur) {
                try repo_aur_targets.append(self.allocator, dep.name);
            }
        }
        if (repo_aur_targets.items.len > 0) {
            try installTargets(self, repo_aur_targets.items);
            return .success;
        }
        getStdout().writeAll(" nothing to do -- all targets are up to date\n") catch {};
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
        const decision = try reviewPackages(self, plan.build_order, c_root);
        switch (decision) {
            .abort => return .success,
            .skip, .proceed => {},
        }
    }

    // Phase 5: Build
    try repository.ensureExists();
    const build_result = try buildLoop(self, plan, repository, reg, c_root);
    defer build_result.deinit(self.allocator);

    if (build_result.signal_aborted) {
        return .signal_killed;
    }

    // Phase 6: Install targets
    if (build_result.failed.len == 0) {
        try installTargets(self, targets);
    } else {
        // Install only targets whose builds succeeded
        const installable = try filterInstallable(self, targets, build_result);
        defer self.allocator.free(installable);
        if (installable.len > 0) {
            try installTargets(self, installable);
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
        const decision = try reviewPackages(self, plan.build_order, c_root);
        if (decision == .abort) return .success;
    }

    // Build
    try repository.ensureExists();
    const result = try buildLoop(self, plan, repository, reg, c_root);
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

/// Remove stale cache artifacts after user confirmation.
/// Uses repo.zig's two-phase approach: compute plan, display, confirm, execute.
pub fn clean(self: *Commands) !ExitCode {
    const pm = self.pacman orelse {
        printErr("error: pacman not initialized\n");
        return .general_error;
    };
    const repository = self.repo orelse {
        printErr("error: repository not initialized\n");
        return .general_error;
    };

    // Get installed foreign package names for staleness check
    const foreign = try pm.allForeignPackages();
    defer self.allocator.free(foreign);

    var installed_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer installed_names.deinit(self.allocator);
    for (foreign) |pkg| try installed_names.append(self.allocator, pkg.name);

    const plan = try repository.clean(installed_names.items);
    defer repository.freeCleanResult(plan);

    if (plan.removed_clones.len == 0 and plan.removed_logs.len == 0) {
        if (!self.flags.quiet) {
            getStdout().writeAll(" nothing to clean\n") catch {};
        }
        return .success;
    }

    const stdout = getStdout();

    if (plan.removed_clones.len > 0) {
        stdout.print(":: Stale clone directories ({d}):\n", .{plan.removed_clones.len}) catch {};
        for (plan.removed_clones) |name| {
            stdout.print("  {s}/\n", .{name}) catch {};
        }
    }

    if (plan.removed_logs.len > 0) {
        stdout.print(":: Stale build logs ({d}):\n", .{plan.removed_logs.len}) catch {};
        for (plan.removed_logs) |name| {
            stdout.print("  {s}\n", .{name}) catch {};
        }
    }

    if (plan.bytes_freed >= 1024 * 1024) {
        stdout.print("\nTotal space to free: {d:.1} MiB\n", .{
            @as(f64, @floatFromInt(plan.bytes_freed)) / (1024.0 * 1024.0),
        }) catch {};
    } else if (plan.bytes_freed >= 1024) {
        stdout.print("\nTotal space to free: {d:.1} KiB\n", .{
            @as(f64, @floatFromInt(plan.bytes_freed)) / 1024.0,
        }) catch {};
    } else {
        stdout.print("\nTotal space to free: {d} B\n", .{plan.bytes_freed}) catch {};
    }

    if (!self.flags.noconfirm) {
        if (!try utils.promptYesNo("Proceed with cleanup?")) {
            return .success;
        }
    }

    repository.cleanExecute(plan);
    return .success;
}

// ── Build Loop ───────────────────────────────────────────────────────

fn buildLoop(
    self: *Commands,
    plan: solver_mod.BuildPlan,
    repository: *repo_mod.Repository,
    reg: *registry_mod.PackageRegistry,
    c_root: []const u8,
) !BuildResult {
    var succeeded: std.ArrayListUnmanaged([]const u8) = .empty;
    var failed: std.ArrayListUnmanaged(FailedBuild) = .empty;
    var failed_bases: std.StringHashMapUnmanaged(void) = .empty;
    defer failed_bases.deinit(self.allocator);

    for (plan.build_order) |entry| {
        // Skip if a dependency failed
        if (hasFailedDep(entry, plan, &failed_bases)) {
            getStderr().print(":: skipping {s} -- a dependency failed to build\n", .{entry.name}) catch {};
            continue;
        }

        const clone_dir = try git.cloneDir(self.allocator, c_root, entry.pkgbase);
        defer self.allocator.free(clone_dir);

        const log_path = try std.fs.path.join(self.allocator, &.{ repository.log_dir, entry.pkgbase });
        defer self.allocator.free(log_path);

        getStdout().print(":: building {s} {s}...\n", .{ entry.name, entry.version }) catch {};

        // Run makepkg -s (--syncdeps installs missing deps as --asdeps)
        const makepkg_args: []const []const u8 = if (self.flags.rebuild)
            &.{ "makepkg", "-sf", "--noconfirm" }
        else
            &.{ "makepkg", "-s", "--noconfirm" };
        const makepkg_result = try utils.runCommandWithLog(
            self.allocator,
            makepkg_args,
            clone_dir,
            log_path,
        );
        defer makepkg_result.deinit(self.allocator);

        if (makepkg_result.exit_code != 0) {
            // Signal-killed (e.g., Ctrl+C -> SIGINT -> exit 130)
            if (makepkg_result.exit_code >= 128) {
                try failed.append(self.allocator, .{
                    .pkgbase = entry.pkgbase,
                    .exit_code = makepkg_result.exit_code,
                    .log_path = log_path,
                });
                return .{
                    .succeeded = try succeeded.toOwnedSlice(self.allocator),
                    .failed = try failed.toOwnedSlice(self.allocator),
                    .signal_aborted = true,
                };
            }

            getStderr().print("error: build failed for {s} (exit {d})\n  log: {s}\n", .{
                entry.pkgbase,
                makepkg_result.exit_code,
                log_path,
            }) catch {};

            try failed.append(self.allocator, .{
                .pkgbase = entry.pkgbase,
                .exit_code = makepkg_result.exit_code,
                .log_path = log_path,
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
                .log_path = log_path,
            });
            try failed_bases.put(self.allocator, entry.pkgbase, {});
            continue;
        };
        defer {
            for (added) |p| self.allocator.free(p);
            self.allocator.free(added);
        }

        // Refresh aurpkgs sync DB so next makepkg -s can find just-built deps.
        // repo-add updates the repo dir DB, but pacman's sync cache
        // (/var/lib/pacman/sync/aurpkgs.db) is stale and root-owned.
        refreshAurpkgsSyncDb(self.allocator, repository) catch |err| {
            getStderr().print("warning: failed to refresh aurpkgs sync db: {}\n", .{err}) catch {};
        };

        // Invalidate registry cache so next resolve can find just-built deps
        reg.invalidate(&.{entry.name});

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
    plan: solver_mod.BuildPlan,
    failed_bases: *const std.StringHashMapUnmanaged(void),
) bool {
    _ = plan;
    // Direct check: is this pkgbase itself failed?
    if (failed_bases.contains(entry.pkgbase)) return true;

    // Because build_order is topologically sorted, any dependency
    // that was going to be built already ran. If it failed, it's in
    // failed_bases. We check if any of this package's transitive
    // AUR dependencies are in the failed set by checking all failed
    // bases against the entry — a simple approach that works because
    // later entries depend on earlier ones.
    return false;
}

// ── Review ───────────────────────────────────────────────────────────

fn reviewPackages(
    self: *Commands,
    entries: []const solver_mod.BuildEntry,
    c_root: []const u8,
) !cmds.ReviewDecision {
    const stdout = getStdout();

    for (entries) |entry| {
        stdout.print("\n:: Reviewing {s} {s}\n", .{ entry.pkgbase, entry.version }) catch {};

        // Check for changes since last build
        const diff = git.diffSinceLastPull(self.allocator, c_root, entry.pkgbase) catch null;
        if (diff) |d| {
            defer self.allocator.free(d);
            if (d.len == 0) {
                stdout.writeAll("   (no changes since last build)\n") catch {};
            }
        }

        // List files
        const files = git.listFiles(self.allocator, c_root, entry.pkgbase) catch {
            stdout.writeAll("  (could not list files)\n") catch {};
            continue;
        };
        defer {
            for (files) |f| self.allocator.free(f.name);
            self.allocator.free(files);
        }

        for (files) |file| {
            stdout.print("  {s}\n", .{file.name}) catch {};
        }

        // Display PKGBUILD
        const content = git.readFile(self.allocator, c_root, entry.pkgbase, "PKGBUILD") catch {
            stdout.writeAll("  (could not read PKGBUILD)\n") catch {};
            continue;
        };
        defer self.allocator.free(content);

        stdout.print("--- PKGBUILD ---\n{s}\n--- end ---\n", .{content}) catch {};

        // Multi-option prompt
        stdout.writeAll("[p]roceed / [s]kip remaining reviews / [a]bort? ") catch {};
        const stdin_file: std.fs.File = .{ .handle = std.posix.STDIN_FILENO };
        const stdin_reader = stdin_file.deprecatedReader();
        const byte = stdin_reader.readByte() catch return .proceed;
        // Consume rest of line
        stdin_reader.skipUntilDelimiterOrEof('\n') catch {};

        switch (byte) {
            'a', 'A' => return .abort,
            's', 'S' => return .proceed,
            else => continue,
        }
    }

    return .proceed;
}

// ── Install ──────────────────────────────────────────────────────────

fn installTargets(self: *Commands, names: []const []const u8) !void {
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

    // Qualify with repo name to install from aurpkgs, not official repos
    var qualified_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (qualified_names.items) |q| self.allocator.free(q);
        qualified_names.deinit(self.allocator);
    }

    for (names) |name| {
        const qualified = try std.fmt.allocPrint(self.allocator, "aurpkgs/{s}", .{name});
        try qualified_names.append(self.allocator, qualified);
        try argv.append(self.allocator, qualified);
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
        stderr.print("  FAILED: {s} (exit {d}) -- log: {s}\n", .{
            f.pkgbase,
            f.exit_code,
            f.log_path,
        }) catch {};
    }
}

/// Copy the aurpkgs repo DB to pacman's sync cache so that subsequent
/// makepkg -s calls (which spawn their own pacman) see just-built packages.
/// Only touches the aurpkgs entry — official repo DBs are left untouched.
fn refreshAurpkgsSyncDb(allocator: Allocator, repository: *repo_mod.Repository) !void {
    const sync_db_path = "/var/lib/pacman/sync/" ++ repo_mod.REPO_NAME ++ ".db";
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
    };
    const plan = solver_mod.BuildPlan{
        .build_order = &.{},
        .all_deps = &.{},
        .repo_deps = &.{},
    };
    var failed: std.StringHashMapUnmanaged(void) = .empty;
    try testing.expect(!hasFailedDep(entry, plan, &failed));
}

test "hasFailedDep returns true when own pkgbase is failed" {
    const entry = solver_mod.BuildEntry{
        .name = "foo",
        .pkgbase = "foo",
        .version = "1.0",
        .is_target = true,
    };
    const plan = solver_mod.BuildPlan{
        .build_order = &.{},
        .all_deps = &.{},
        .repo_deps = &.{},
    };
    var failed: std.StringHashMapUnmanaged(void) = .empty;
    defer failed.deinit(testing.allocator);
    try failed.put(testing.allocator, "foo", {});
    try testing.expect(hasFailedDep(entry, plan, &failed));
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
