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
const auth_mod = @import("../auth.zig");
const registry_mod = @import("../registry.zig");
const cmds = @import("../commands.zig");
const query = @import("query.zig");
const color = @import("../color.zig");

const Commands = cmds.Commands;
const ExitCode = cmds.ExitCode;
const BuildResult = cmds.BuildResult;
const FailedBuild = cmds.FailedBuild;
const OutdatedEntry = cmds.OutdatedEntry;
const getStdout = cmds.getStdout;
const printError = cmds.printError;
const handleResolveError = cmds.handleResolveError;
const displayPlan = cmds.displayPlan;

// ── Show Command ─────────────────────────────────────────────────────

/// Display build files for a package clone.
/// Lists files in the clone directory and displays PKGBUILD content.
pub fn show(self: *Commands, target: []const u8) !ExitCode {
    const ec = self.stderr_color;
    const c = self.stdout_color;
    const cache = self.resolveCacheRoot() catch {
        self.err_writer.print("{s}error:{s} could not determine cache directory (HOME not set)\n", .{ ec.red, ec.reset }) catch {};
        return .general_error;
    };
    const c_root = cache.path;
    defer self.freeCacheRoot(cache);

    // Resolve pkgname to pkgbase
    const pkgbase = blk: {
        if (self.aur_client.info(target) catch null) |pkg| {
            break :blk pkg.pkgbase;
        }
        break :blk target;
    };

    // Verify clone exists
    if (!try git.isCloned(self.allocator, c_root, pkgbase)) {
        self.err_writer.print("{s}error:{s} {s} is not cloned. Run 'aurodle sync {s}' first.\n", .{ ec.red, ec.reset, target, target }) catch {};
        return .general_error;
    }

    const clone_dir = try git.cloneDir(self.allocator, c_root, pkgbase);
    defer self.allocator.free(clone_dir);

    const viewer = getViewer();
    const exit_code = utils.runInteractive(self.allocator, &.{ viewer, clone_dir }, null) catch |err| {
        self.err_writer.print("{s}error:{s} could not open viewer ({s}): {}\n", .{ ec.red, ec.reset, viewer, err }) catch {};
        return .general_error;
    };

    _ = c;
    return if (exit_code == 0) .success else .general_error;
}

// ── Clone Command ────────────────────────────────────────────────────

/// Clone AUR packages to the cache directory (FR-8).
pub fn clonePackages(self: *Commands, targets: []const []const u8) !ExitCode {
    const ec = self.stderr_color;
    const stdout = getStdout();

    // Resolve pkgname->pkgbase via AUR RPC
    const packages = self.aur_client.multiInfo(targets) catch |err| {
        try printError(err, self.err_writer, ec);
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
            self.err_writer.print("{s}error:{s} package '{s}' was not found\n", .{ ec.red, ec.reset, target }) catch {};
            any_error = true;
        }
    }

    // Get cache root
    const cache = self.resolveCacheRoot() catch {
        self.err_writer.print("{s}error:{s} could not determine cache directory (HOME not set)\n", .{ ec.red, ec.reset }) catch {};
        return .general_error;
    };
    const c_root = cache.path;
    defer self.freeCacheRoot(cache);

    // Collect pkgbases to clone: either just targets, or full dep tree with --recurse
    var bases_to_clone: std.ArrayListUnmanaged([]const u8) = .empty;
    defer bases_to_clone.deinit(self.allocator);

    if (self.flags.recurse) {
        const reg = self.registry orelse {
            self.err_writer.print("{s}error:{s} registry not initialized (--recurse requires full stack)\n", .{ ec.red, ec.reset }) catch {};
            return .general_error;
        };

        var s = solver_mod.Solver.init(self.allocator, reg);
        defer s.deinit();

        const plan = s.resolve(targets) catch |err| {
            return handleResolveError(err, self.err_writer, ec);
        };
        defer plan.deinit(self.allocator);

        // Collect all AUR pkgbases from build order
        for (plan.build_order) |entry| {
            try bases_to_clone.append(self.allocator, entry.pkgbase);
        }
    } else {
        for (targets) |target| {
            if (pkgbase_map.get(target)) |pkgbase| {
                try bases_to_clone.append(self.allocator, pkgbase);
            }
        }
    }

    // Clone each package
    var cloned_set: std.StringHashMapUnmanaged(void) = .empty;
    defer cloned_set.deinit(self.allocator);

    for (bases_to_clone.items) |pkgbase| {
        if (cloned_set.contains(pkgbase)) continue;
        try cloned_set.put(self.allocator, pkgbase, {});

        const result = git.clone(self.allocator, c_root, pkgbase) catch {
            self.err_writer.print("{s}error:{s} failed to clone '{s}'\n", .{ ec.red, ec.reset, pkgbase }) catch {};
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
    // Filter ignored targets (prompt user for each)
    var ignore_buf: [256][]const u8 = undefined;
    const filtered = self.filterIgnored(targets, &ignore_buf);
    if (filtered.len == 0) return .success;

    return syncFiltered(self, filtered);
}

/// Inner sync workflow operating on pre-filtered targets (no ignore prompting).
fn syncFiltered(self: *Commands, filtered: []const []const u8) !ExitCode {
    const ec = self.stderr_color;
    const reg = self.registry orelse {
        self.err_writer.print("{s}error:{s} registry not initialized\n", .{ ec.red, ec.reset }) catch {};
        return .general_error;
    };
    const repository = self.repo orelse {
        self.err_writer.print("{s}error:{s} repository not initialized\n", .{ ec.red, ec.reset }) catch {};
        return .general_error;
    };
    const c_root = self.cache_root orelse {
        self.err_writer.print("{s}error:{s} cache root not set\n", .{ ec.red, ec.reset }) catch {};
        return .general_error;
    };

    // Phase 1: Resolve
    var s = solver_mod.Solver.init(self.allocator, reg);
    s.rebuild = self.flags.rebuild;
    s.needed = self.flags.needed;
    s.ignore = self.flags.ignore;
    defer s.deinit();

    const plan = s.resolve(filtered) catch |err| {
        return handleResolveError(err, self.err_writer, ec);
    };
    defer plan.deinit(self.allocator);

    // Phase 1.5: Resolve conflicts interactively
    var removals: []const []const u8 = &.{};
    if (plan.conflicts.len > 0 and !self.flags.noconfirm) {
        removals = try resolveConflicts(self.allocator, plan.conflicts, self.stdout_color) orelse {
            self.err_writer.print("{s}::{s} unresolvable package conflicts detected\n", .{ ec.red, ec.reset }) catch {};
            return .general_error;
        };
    }
    defer self.allocator.free(removals);

    if (plan.build_order.len == 0) {
        // Check for targets available in aurpkgs: either not installed (repo_aur)
        // or already installed (satisfied_aur) — reinstall like pacman -S would.
        var aurpkgs_targets: std.ArrayListUnmanaged([]const u8) = .empty;
        defer aurpkgs_targets.deinit(self.allocator);
        for (plan.all_deps) |dep| {
            if (!dep.is_target) continue;
            if (dep.source == .repo_aur) {
                try aurpkgs_targets.append(self.allocator, dep.name);
            } else if (dep.source == .satisfied_aur and !self.flags.needed) {
                // Reinstall if available in aurpkgs repo (skip with --needed)
                if (self.pacman) |pm| {
                    if (pm.isAurRepo(pm.syncDbFor(dep.name) orelse "")) {
                        try aurpkgs_targets.append(self.allocator, dep.name);
                    }
                }
            }
        }
        if (aurpkgs_targets.items.len > 0 or plan.repo_targets.len > 0) {
            // Build combined name list and display with compact/verbose support
            var all_names: std.ArrayListUnmanaged([]const u8) = .empty;
            defer all_names.deinit(self.allocator);
            try all_names.appendSlice(self.allocator, aurpkgs_targets.items);
            try all_names.appendSlice(self.allocator, plan.repo_targets);
            cmds.displayInstallList(all_names.items, self.pacman, self.err_writer, self.stdout_color, self.stderr_color);

            if (!self.flags.noconfirm) {
                if (!try utils.promptYesNoStyled(self.stdout_color, "Proceed with installation?")) {
                    return .success;
                }
            }

            try installAllTargets(self, aurpkgs_targets.items, plan.repo_targets);
        }
        if (aurpkgs_targets.items.len == 0 and plan.repo_targets.len == 0) {
            getStdout().writeAll(" nothing to do -- all targets are up to date\n") catch {};
        }
        return .success;
    }

    // Phase 1.6: Provider selection for transitive repo deps
    var chosen_providers: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer chosen_providers.deinit(self.allocator);
    var providers_to_install: std.ArrayListUnmanaged([]const u8) = .empty;
    defer providers_to_install.deinit(self.allocator);

    if (self.pacman) |pm| {
        const choices = try pm.findTransitiveProviderChoices(self.allocator, plan.repo_deps);
        defer {
            for (choices) |ch| self.allocator.free(ch.candidates);
            self.allocator.free(choices);
        }
        for (choices) |choice| {
            var candidates: std.ArrayListUnmanaged(registry_mod.ProviderCandidate) = .empty;
            defer candidates.deinit(self.allocator);
            for (choice.candidates) |m| {
                try candidates.append(self.allocator, .{
                    .name = m.provider_name,
                    .version = m.provider_version,
                    .db_name = m.db_name,
                });
            }
            const idx = if (self.flags.noconfirm)
                @as(?usize, 0)
            else
                utils.promptProviderChoice(choice.dep_name, candidates.items, self.stdout_color);
            const chosen_idx = idx orelse 0;
            try chosen_providers.put(self.allocator, choice.dep_name, choice.candidates[chosen_idx].provider_name);
            try providers_to_install.append(self.allocator, choice.candidates[chosen_idx].provider_name);
        }
    }

    const repo_deps_full = if (self.pacman) |pm|
        try pm.transitiveRepoDeps(self.allocator, plan.repo_deps, chosen_providers)
    else
        try self.allocator.dupe([]const u8, plan.repo_deps);
    defer self.allocator.free(repo_deps_full);

    // Phase 2: Display and confirm
    displayPlan(plan, repo_deps_full, self.pacman, removals, self.err_writer, self.stdout_color, ec);

    if (!self.flags.noconfirm) {
        if (!try utils.promptYesNoStyled(self.stdout_color, "Proceed with installation?")) {
            return .success;
        }
    }

    // Phase 3: Clone
    for (plan.build_order) |entry| {
        _ = git.cloneOrUpdate(self.allocator, c_root, entry.pkgbase) catch |err| {
            self.err_writer.print("{s}error:{s} failed to clone/update '{s}': {}\n", .{ ec.red, ec.reset, entry.pkgbase, err }) catch {};
            return .general_error;
        };
    }

    // Phase 4: Review (unless --noshow)
    if (!self.flags.noshow) {
        try reviewPackages(self, plan.build_order, c_root);
    }

    // Phase 4.5: Acquire credentials now that the user has committed
    if (try acquireAuth(self)) |exit| return exit;

    // Pre-install chosen providers so makepkg -s finds them already installed
    if (providers_to_install.items.len > 0) {
        if (!try preInstallProviders(self, providers_to_install.items)) return .general_error;
    }

    // Phase 5: Build
    try repository.ensureExists();
    const build_result = try buildLoop(self, plan, repository, c_root);
    defer build_result.deinit(self.allocator);

    if (build_result.signal_aborted) {
        return .signal_killed;
    }

    // Refresh sync DB so pacman -S sees the just-built packages.
    if (build_result.succeeded.len > 0) {
        refreshAurpkgsSyncDb(self.allocator, repository, self.auth.?) catch |err| {
            self.err_writer.print("{s}warning:{s} failed to refresh aurpkgs sync db: {}\n", .{ ec.yellow, ec.reset, err }) catch {};
        };
    }

    // Phase 6: Install targets (AUR from aurpkgs + repo targets in one transaction)
    // Use target_names to handle split packages (multiple targets per pkgbase)
    var aur_targets: std.ArrayListUnmanaged([]const u8) = .empty;
    defer aur_targets.deinit(self.allocator);
    for (plan.build_order) |entry| {
        for (entry.target_names) |tname| {
            try aur_targets.append(self.allocator, tname);
        }
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
        printBuildSummary(build_result, self.err_writer, ec);
        return .build_failed;
    }

    return .success;
}

// ── Build Command ────────────────────────────────────────────────────

/// Build packages and add to repository without installing.
pub fn build(self: *Commands, targets: []const []const u8) !ExitCode {
    const ec = self.stderr_color;
    const reg = self.registry orelse {
        self.err_writer.print("{s}error:{s} registry not initialized\n", .{ ec.red, ec.reset }) catch {};
        return .general_error;
    };
    const repository = self.repo orelse {
        self.err_writer.print("{s}error:{s} repository not initialized\n", .{ ec.red, ec.reset }) catch {};
        return .general_error;
    };
    const c_root = self.cache_root orelse {
        self.err_writer.print("{s}error:{s} cache root not set\n", .{ ec.red, ec.reset }) catch {};
        return .general_error;
    };

    // Filter ignored targets
    var ignore_buf: [256][]const u8 = undefined;
    const filtered = self.filterIgnored(targets, &ignore_buf);
    if (filtered.len == 0) return .success;

    var s = solver_mod.Solver.init(self.allocator, reg);
    s.rebuild = self.flags.rebuild;
    s.needed = self.flags.needed;
    s.ignore = self.flags.ignore;
    defer s.deinit();

    const plan = s.resolve(filtered) catch |err| {
        return handleResolveError(err, self.err_writer, ec);
    };
    defer plan.deinit(self.allocator);

    // Resolve conflicts interactively
    var removals: []const []const u8 = &.{};
    if (plan.conflicts.len > 0 and !self.flags.noconfirm) {
        removals = try resolveConflicts(self.allocator, plan.conflicts, self.stdout_color) orelse {
            self.err_writer.print("{s}::{s} unresolvable package conflicts detected\n", .{ ec.red, ec.reset }) catch {};
            return .general_error;
        };
    }
    defer self.allocator.free(removals);

    if (plan.build_order.len == 0) {
        getStdout().writeAll(" nothing to do -- all targets are up to date\n") catch {};
        return .success;
    }

    // Provider selection for transitive repo deps
    var chosen_providers: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer chosen_providers.deinit(self.allocator);
    var providers_to_install: std.ArrayListUnmanaged([]const u8) = .empty;
    defer providers_to_install.deinit(self.allocator);

    if (self.pacman) |pm| {
        const choices = try pm.findTransitiveProviderChoices(self.allocator, plan.repo_deps);
        defer {
            for (choices) |ch| self.allocator.free(ch.candidates);
            self.allocator.free(choices);
        }
        for (choices) |choice| {
            var candidates: std.ArrayListUnmanaged(registry_mod.ProviderCandidate) = .empty;
            defer candidates.deinit(self.allocator);
            for (choice.candidates) |m| {
                try candidates.append(self.allocator, .{
                    .name = m.provider_name,
                    .version = m.provider_version,
                    .db_name = m.db_name,
                });
            }
            const idx = if (self.flags.noconfirm)
                @as(?usize, 0)
            else
                utils.promptProviderChoice(choice.dep_name, candidates.items, self.stdout_color);
            const chosen_idx = idx orelse 0;
            try chosen_providers.put(self.allocator, choice.dep_name, choice.candidates[chosen_idx].provider_name);
            try providers_to_install.append(self.allocator, choice.candidates[chosen_idx].provider_name);
        }
    }

    const repo_deps_full = if (self.pacman) |pm|
        try pm.transitiveRepoDeps(self.allocator, plan.repo_deps, chosen_providers)
    else
        try self.allocator.dupe([]const u8, plan.repo_deps);
    defer self.allocator.free(repo_deps_full);

    displayPlan(plan, repo_deps_full, self.pacman, removals, self.err_writer, self.stdout_color, ec);

    if (!self.flags.noconfirm) {
        if (!try utils.promptYesNoStyled(self.stdout_color, "Proceed with build?")) {
            return .success;
        }
    }

    // Clone
    for (plan.build_order) |entry| {
        _ = git.cloneOrUpdate(self.allocator, c_root, entry.pkgbase) catch |err| {
            self.err_writer.print("{s}error:{s} failed to clone/update '{s}': {}\n", .{ ec.red, ec.reset, entry.pkgbase, err }) catch {};
            return .general_error;
        };
    }

    // Review
    if (!self.flags.noshow) {
        try reviewPackages(self, plan.build_order, c_root);
    }

    // Acquire credentials now that the user has committed
    if (try acquireAuth(self)) |exit| return exit;

    // Pre-install chosen providers so makepkg -s finds them already installed
    if (providers_to_install.items.len > 0) {
        if (!try preInstallProviders(self, providers_to_install.items)) return .general_error;
    }

    // Build
    try repository.ensureExists();
    const result = try buildLoop(self, plan, repository, c_root);
    defer result.deinit(self.allocator);

    if (result.signal_aborted) return .signal_killed;

    // Final sync DB refresh so the packages are installable via pacman -S.
    if (result.succeeded.len > 0) {
        refreshAurpkgsSyncDb(self.allocator, repository, self.auth.?) catch |err| {
            self.err_writer.print("{s}warning:{s} failed to refresh aurpkgs sync db: {}\n", .{ ec.yellow, ec.reset, err }) catch {};
        };
    }

    if (result.failed.len > 0) {
        printBuildSummary(result, self.err_writer, ec);
        return .build_failed;
    }

    return .success;
}

// ── Upgrade Command ──────────────────────────────────────────────────

/// Upgrade outdated AUR packages via the full sync workflow.
/// With no arguments: upgrade all outdated AUR packages.
/// With arguments: upgrade only the specified packages.
pub fn upgrade(self: *Commands, targets: []const []const u8) !ExitCode {
    const ec = self.stderr_color;
    const pm = self.pacman orelse {
        self.err_writer.print("{s}error:{s} pacman not initialized\n", .{ ec.red, ec.reset }) catch {};
        return .general_error;
    };
    const sc = self.stdout_color;
    getStdout().print("{s}::{s} Starting AUR upgrade...\n", .{ sc.blue, sc.reset }) catch {};

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
    try names.ensureUnusedCapacity(self.allocator, to_check.len);
    for (to_check) |pkg| names.appendAssumeCapacity(pkg.name);

    const aur_pkgs = self.aur_client.multiInfo(names.items) catch |err| {
        try printError(err, self.err_writer, ec);
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
    var devel_versions: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (devel_versions.items) |v| self.allocator.free(v);
        devel_versions.deinit(self.allocator);
    }
    if (self.flags.devel) {
        try checkDevelUpgrades(self, to_check, &upgrade_set, &to_upgrade, &outdated_display, &devel_versions);
    }

    // Remove ignored packages from both upgrade and display lists with a warning
    if (self.flags.ignore.len > 0) {
        var i: usize = 0;
        while (i < to_upgrade.items.len) {
            const name = to_upgrade.items[i];
            if (self.isIgnored(name)) {
                self.err_writer.print(
                    "{s}warning:{s} {s}: ignoring package upgrade\n",
                    .{ ec.yellow, ec.reset, name },
                ) catch {};
                _ = to_upgrade.swapRemove(i);
                // Also remove from display list
                var j: usize = 0;
                while (j < outdated_display.items.len) {
                    if (std.mem.eql(u8, outdated_display.items[j].name, name)) {
                        _ = outdated_display.swapRemove(j);
                    } else j += 1;
                }
            } else i += 1;
        }
    }

    if (to_upgrade.items.len == 0) {
        getStdout().writeAll(" there is nothing to do\n") catch {};
        return .success;
    }

    // Delegate to sync for the actual build+install workflow.
    // Use syncFiltered to skip ignore prompting (already handled above).
    return syncFiltered(self, to_upgrade.items);
}

// ── Devel Upgrade Check ──────────────────────────────────────────────

/// Check VCS packages for upstream updates and add outdated ones to upgrade lists.
fn checkDevelUpgrades(
    self: *Commands,
    packages: []const pacman_mod.InstalledPackage,
    upgrade_set: *std.StringHashMapUnmanaged(void),
    to_upgrade: *std.ArrayListUnmanaged([]const u8),
    outdated_display: *std.ArrayListUnmanaged(OutdatedEntry),
    devel_versions: *std.ArrayListUnmanaged([]const u8),
) !void {
    const ec2 = self.stderr_color;
    const cache = self.resolveCacheRoot() catch {
        self.err_writer.print("{s}warning:{s} could not determine cache directory for --devel check\n", .{ ec2.yellow, ec2.reset }) catch {};
        return;
    };
    const c_root = cache.path;
    defer self.freeCacheRoot(cache);

    for (packages) |pkg| {
        if (!devel.isVcsPackage(pkg.name)) continue;
        if (upgrade_set.contains(pkg.name)) continue;

        if (!self.flags.quiet) {
            self.err_writer.print("{s}::{s} checking {s}...\n", .{ ec2.blue, ec2.reset, pkg.name }) catch {};
        }

        const vcs_result = devel.checkVersion(self.allocator, c_root, pkg.name) catch {
            self.err_writer.print("{s}warning:{s} failed to check VCS version for {s}\n", .{ ec2.yellow, ec2.reset, pkg.name }) catch {};
            continue;
        };

        const version = vcs_result orelse continue;
        try devel_versions.append(self.allocator, version);

        if (alpm.vercmp(pkg.version, version) < 0) {
            try to_upgrade.append(self.allocator, pkg.name);
            try upgrade_set.put(self.allocator, pkg.name, {});
            try outdated_display.append(self.allocator, .{
                .name = pkg.name,
                .installed_version = pkg.version,
                .aur_version = version,
            });
        }
    }
}

// ── Clean Command ────────────────────────────────────────────────────

/// Remove stale aurpkgs artifacts after user confirmation.
/// Checks the aurpkgs database for packages no longer installed locally,
/// then removes their clone directories, package files, and database entries.
pub fn clean(self: *Commands) !ExitCode {
    const ec = self.stderr_color;
    const repository = self.repo orelse {
        self.err_writer.print("{s}error:{s} repository not initialized\n", .{ ec.red, ec.reset }) catch {};
        return .general_error;
    };

    const plan = if (self.flags.all) blk: {
        break :blk try repository.cleanAll();
    } else blk: {
        const pm = self.pacman orelse {
            self.err_writer.print("{s}error:{s} pacman not initialized\n", .{ ec.red, ec.reset }) catch {};
            return .general_error;
        };

        const uninstalled = pm.uninstalledAurpkgs() catch |err| switch (err) {
            error.AurDbNotConfigured => {
                self.err_writer.print("{s}error:{s} local AUR repository not configured in pacman.conf\n", .{ ec.red, ec.reset }) catch {};
                return .general_error;
            },
            else => return err,
        };
        defer self.allocator.free(uninstalled);

        break :blk try repository.clean(uninstalled);
    };
    defer repository.freeCleanResult(plan);

    if (plan.removed_clones.len == 0 and plan.removed_packages.len == 0) {
        if (!self.flags.quiet) {
            getStdout().writeAll(" nothing to clean\n") catch {};
        }
        return .success;
    }

    const stdout = getStdout();
    const c = self.stdout_color;

    const pkg_label = if (self.flags.all) "Packages" else "Stale packages";
    const clone_label = if (self.flags.all) "Clone directories" else "Stale clone directories";

    if (plan.removed_packages.len > 0) {
        stdout.print("{s}::{s} {s} ({d}):\n", .{ c.blue, c.reset, pkg_label, plan.removed_packages.len }) catch {};
        for (plan.removed_packages) |filename| {
            stdout.print("  {s}\n", .{filename}) catch {};
        }
    }

    if (plan.removed_clones.len > 0) {
        stdout.print("{s}::{s} {s} ({d}):\n", .{ c.blue, c.reset, clone_label, plan.removed_clones.len }) catch {};
        for (plan.removed_clones) |name| {
            stdout.print("  {s}/\n", .{name}) catch {};
        }
    }

    if (!self.flags.noconfirm) {
        if (!try utils.promptYesNoStyled(self.stdout_color, "Proceed with cleanup?")) {
            return .success;
        }
    }

    repository.cleanExecute(plan);

    // Refresh pacman's sync copy of the aurpkgs database.
    // repo-remove modified the db in repo_dir, but pacman reads from
    // /var/lib/pacman/sync/ which is a separate root-owned copy.
    if (plan.removed_packages.len > 0) {
        refreshAurpkgsSyncDb(self.allocator, repository, self.auth.?) catch |err| {
            self.err_writer.print("{s}warning:{s} failed to refresh aurpkgs sync db: {}\n", .{ ec.yellow, ec.reset, err }) catch {};
        };
    }

    return .success;
}

// ── Chroot Support ───────────────────────────────────────────────────

const DEFAULT_CHROOT_DIR = "/var/lib/aurodle/chroot";

/// Resolve chroot path: $CHROOT_DIR or default.
fn chrootDir() []const u8 {
    return std.posix.getenv("CHROOT_DIR") orelse DEFAULT_CHROOT_DIR;
}

/// Ensure a clean chroot exists, creating it with mkarchroot if needed.
fn ensureChroot(allocator: Allocator, auth: *auth_mod.Auth, err_writer: anytype, ec: color.Style) !bool {
    // Check that devtools is installed
    if (!utils.findOnPath("makechrootpkg")) {
        err_writer.print("{s}error:{s} makechrootpkg not found -- install devtools: pacman -S devtools\n", .{ ec.red, ec.reset }) catch {};
        return false;
    }

    const chroot_path = chrootDir();
    const root_path = std.fmt.allocPrint(allocator, "{s}/root", .{chroot_path}) catch return false;
    defer allocator.free(root_path);

    // Check if chroot root already exists
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

// ── Build Loop ───────────────────────────────────────────────────────

fn buildLoop(
    self: *Commands,
    plan: solver_mod.BuildPlan,
    repository: *repo_mod.Repository,
    c_root: []const u8,
) !BuildResult {
    const ec = self.stderr_color;
    const sc = self.stdout_color;
    var succeeded: std.ArrayListUnmanaged([]const u8) = .empty;
    var failed: std.ArrayListUnmanaged(FailedBuild) = .empty;
    var failed_bases: std.StringHashMapUnmanaged(void) = .empty;
    defer failed_bases.deinit(self.allocator);

    // Ensure chroot exists before starting builds
    if (self.flags.chroot) {
        if (!try ensureChroot(self.allocator, self.auth.?, self.err_writer, ec)) {
            return .{
                .succeeded = try succeeded.toOwnedSlice(self.allocator),
                .failed = try failed.toOwnedSlice(self.allocator),
                .signal_aborted = false,
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
        // Skip if a dependency failed, propagating failure to downstream entries
        if (hasFailedDep(entry, &failed_bases)) {
            self.err_writer.print("{s}::{s} skipping {s} -- a dependency failed to build\n", .{ ec.yellow, ec.reset, entry.name }) catch {};
            try failed_bases.put(self.allocator, entry.pkgbase, {});
            continue;
        }

        const clone_dir = try git.cloneDir(self.allocator, c_root, entry.pkgbase);
        defer self.allocator.free(clone_dir);

        const ver = if (devel.isVcsPackage(entry.name)) "latest" else entry.version;
        getStdout().print("{s}::{s} Building {s} {s}...\n", .{ sc.blue, sc.reset, entry.name, ver }) catch {};

        // Run build command: makechrootpkg in chroot mode, makepkg otherwise
        const exit_code = if (self.flags.chroot) blk: {
            break :blk try runChrootBuild(self, entry, &built_pkg_paths, clone_dir);
        } else blk: {
            const args: []const []const u8 = if (self.flags.rebuild)
                &.{ "makepkg", "-sf", "--noconfirm" }
            else
                &.{ "makepkg", "-s", "--noconfirm" };
            break :blk try utils.runInteractive(self.allocator, args, clone_dir);
        };

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

            self.err_writer.print("{s}error:{s} build failed for {s} (exit {d})\n", .{
                ec.red,
                ec.reset,
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
            self.err_writer.print("{s}error:{s} failed to add built packages for {s}: {}\n", .{ ec.red, ec.reset, entry.pkgbase, err }) catch {};
            try failed.append(self.allocator, .{
                .pkgbase = entry.pkgbase,
                .exit_code = 0,
            });
            try failed_bases.put(self.allocator, entry.pkgbase, {});
            continue;
        };

        // In chroot mode, remember built paths so downstream builds can use -I.
        if (self.flags.chroot) {
            try built_pkg_paths.put(self.allocator, entry.pkgbase, added);
        } else {
            defer {
                for (added) |p| self.allocator.free(p);
                self.allocator.free(added);
            }
        }

        // Refresh aurpkgs sync DB only when a subsequent build needs this package.
        // repo-add updated the repo dir DB, but pacman's sync cache
        // (/var/lib/pacman/sync/aurpkgs.db) is root-owned and separate.
        // In chroot mode the chroot is isolated, but the host DB still needs
        // refreshing for the final install step.
        if (anySubsequentEntryNeeds(plan.build_order[i + 1 ..], entry.pkgbase)) {
            refreshAurpkgsSyncDb(self.allocator, repository, self.auth.?) catch |err| {
                self.err_writer.print("{s}warning:{s} failed to refresh aurpkgs sync db: {}\n", .{ ec.yellow, ec.reset, err }) catch {};
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

/// Build a package inside a clean chroot using makechrootpkg.
/// Injects previously-built AUR dependencies via -I flags so the
/// isolated chroot can satisfy AUR-to-AUR dependency chains.
fn runChrootBuild(
    self: *const Commands,
    entry: solver_mod.BuildEntry,
    built_pkg_paths: *const std.StringHashMapUnmanaged([]const []const u8),
    clone_dir: []const u8,
) !u8 {
    const chroot_path = chrootDir();

    // Build argv: makechrootpkg -c -u -r <chroot> [-I dep1.pkg ...] [-- --force]
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(self.allocator);

    try argv.appendSlice(self.allocator, &.{ "makechrootpkg", "-c", "-u", "-r", chroot_path });

    // Inject previously-built AUR deps so they're available inside the chroot
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
    const sc = self.stdout_color;
    const editor = getViewer();

    for (entries) |entry| {
        const clone_dir = try git.cloneDir(self.allocator, c_root, entry.pkgbase);
        defer self.allocator.free(clone_dir);

        const is_update = git.hasOrigHead(self.allocator, c_root, entry.pkgbase) catch false;

        if (is_update) {
            // Updated clone — show diff interactively
            const msg = try std.fmt.allocPrint(self.allocator, "View {s} diff?", .{entry.pkgbase});
            defer self.allocator.free(msg);

            if (try utils.promptYesNoStyled(self.stdout_color, msg)) {
                const exit_code = utils.runInteractive(
                    self.allocator,
                    &.{ "git", "diff", "--color=always", "ORIG_HEAD..HEAD" },
                    clone_dir,
                ) catch {
                    stdout.writeAll("  (could not show diff)\n") catch {};
                    continue;
                };
                _ = exit_code;
                stdout.print("{s}::{s} {s} diff reviewed\n", .{ sc.blue, sc.reset, entry.pkgbase }) catch {};
            }
        } else {
            // Fresh clone — open all files in editor
            const msg = try std.fmt.allocPrint(self.allocator, "Review {s} files?", .{entry.pkgbase});
            defer self.allocator.free(msg);

            if (try utils.promptYesNoStyled(self.stdout_color, msg)) {
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
                stdout.print("{s}::{s} {s} files reviewed\n", .{ sc.blue, sc.reset, entry.pkgbase }) catch {};
            }
        }
    }
}

fn getViewer() []const u8 {
    if (std.posix.getenv("PAGER")) |p| if (p.len > 0) return p;
    if (std.posix.getenv("VISUAL")) |v| if (v.len > 0) return v;
    if (std.posix.getenv("EDITOR")) |e| if (e.len > 0) return e;
    return "vim";
}

// ── Install ──────────────────────────────────────────────────────────

/// Install AUR targets (from aurpkgs) and repo targets (from their sync db)
/// in a single `pacman -S` transaction.
/// Pre-install chosen virtual-dep providers via `pacman -S --needed --asdeps`
/// so that makepkg -s finds them already installed and skips its own prompt.
/// Returns false if pacman exits non-zero.
fn preInstallProviders(self: *Commands, pkg_names: []const []const u8) !bool {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(self.allocator);
    try argv.appendSlice(self.allocator, &.{ "pacman", "-S", "--needed", "--asdeps", "--noconfirm" });
    try argv.appendSlice(self.allocator, pkg_names);
    const exit_code = try self.auth.?.runInteractive(argv.items, null);
    if (exit_code != 0) {
        const ec = self.stderr_color;
        self.err_writer.print("{s}error:{s} failed to pre-install providers (exit {d})\n", .{ ec.red, ec.reset, exit_code }) catch {};
        return false;
    }
    return true;
}

fn installAllTargets(self: *Commands, aurpkgs_names: []const []const u8, repo_names: []const []const u8) !void {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(self.allocator);

    try argv.appendSlice(self.allocator, &.{ "pacman", "-S" });

    if (self.flags.asdeps) {
        try argv.append(self.allocator, "--asdeps");
    } else if (self.flags.asexplicit) {
        try argv.append(self.allocator, "--asexplicit");
    }

    if (self.flags.needed) {
        try argv.append(self.allocator, "--needed");
    }

    // Always pass --noconfirm and --ask 36: the user already confirmed via
    // aurodle's "Proceed with installation?" prompt, so pacman should not
    // re-prompt. --ask 36 = 4 (auto-accept conflicts) + 32 (auto-accept replacements).
    try argv.appendSlice(self.allocator, &.{ "--noconfirm", "--ask", "36" });

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

    const exit_code = try self.auth.?.runInteractive(argv.items, null);

    if (exit_code != 0) {
        const ec3 = self.stderr_color;
        self.err_writer.print("{s}error:{s} installation failed (exit {d})\n", .{ ec3.red, ec3.reset, exit_code }) catch {};
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

fn printBuildSummary(result: BuildResult, err_writer: std.io.AnyWriter, ec: color.Style) void {
    err_writer.print("\n{s}::{s} Build summary: {d} succeeded, {d} failed\n", .{
        ec.blue,
        ec.reset,
        result.succeeded.len,
        result.failed.len,
    }) catch {};
    for (result.failed) |f| {
        err_writer.print("  {s}FAILED:{s} {s} (exit {d})\n", .{
            ec.red,
            ec.reset,
            f.pkgbase,
            f.exit_code,
        }) catch {};
    }
}

/// Acquire privilege credentials and start the keepalive thread.
/// Called after the user has confirmed the plan and reviewed PKGBUILDs,
/// so we don't prompt for a password if they're going to bail out anyway.
/// Returns an ExitCode if acquisition failed, null on success.
fn acquireAuth(self: *Commands) !?ExitCode {
    const auth = self.auth orelse return null;
    const ec = self.stderr_color;
    const cred_exit = auth.acquireCredentials() catch 0;
    if (cred_exit != 0) {
        self.err_writer.print("{s}error:{s} credential acquisition failed\n", .{ ec.red, ec.reset }) catch {};
        return .general_error;
    }
    auth.startKeepalive();
    return null;
}

/// Copy the local AUR repo DB to pacman's sync cache so that subsequent
/// makepkg -s calls (which spawn their own pacman) see just-built packages.
/// Only touches the local AUR repo entry — official repo DBs are left untouched.
fn refreshAurpkgsSyncDb(allocator: Allocator, repository: *repo_mod.Repository, auth: *auth_mod.Auth) !void {
    const sync_db_path = try std.fmt.allocPrint(allocator, "/var/lib/pacman/sync/{s}.db", .{repository.repo_name});
    defer allocator.free(sync_db_path);
    const result = try auth.runCaptured(&.{ "cp", repository.db_path, sync_db_path });
    defer result.deinit(allocator);
    if (!result.success()) return error.SyncDbRefreshFailed;
}

/// Prompt the user to resolve each detected conflict.
/// Returns the list of packages accepted for removal, or null if any conflict was rejected.
fn resolveConflicts(allocator: Allocator, conflicts: []const solver_mod.Conflict, c: color.Style) !?[]const []const u8 {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stdin: std.fs.File = .{ .handle = std.posix.STDIN_FILENO };
    if (!std.posix.isatty(stdin.handle)) return null;

    const w = stdout.deprecatedWriter();
    var removals: std.ArrayListUnmanaged([]const u8) = .empty;
    defer removals.deinit(allocator); // no-op after toOwnedSlice succeeds

    for (conflicts) |conflict| {
        switch (conflict.kind) {
            .aur_aur => w.print(
                "{s}::{s} {s} and {s} are in conflict. Continue anyway? [y/N] ",
                .{ c.yellow, c.reset, conflict.package, conflict.conflicts_with },
            ) catch {},
            .aur_installed, .repo_installed => w.print(
                "{s}::{s} {s} and {s} are in conflict ({s}). Remove {s}? [y/N] ",
                .{ c.yellow, c.reset, conflict.package, conflict.conflicts_with, conflict.conflicts_with, conflict.conflicts_with },
            ) catch {},
            .aur_replaces => w.print(
                "{s}::{s} Replace {s} with aur/{s}? [y/N] ",
                .{ c.yellow, c.reset, conflict.conflicts_with, conflict.package },
            ) catch {},
            .repo_replaces => w.print(
                "{s}::{s} Replace {s} with {s}? [y/N] ",
                .{ c.yellow, c.reset, conflict.conflicts_with, conflict.package },
            ) catch {},
        }

        var buf: [16]u8 = undefined;
        const n = stdin.read(&buf) catch return null;
        if (n == 0) return null;
        const response = std.mem.trim(u8, buf[0..n], " \t\n\r");
        if (response.len == 0 or (response[0] != 'y' and response[0] != 'Y')) return null;

        // Track packages accepted for removal (installed conflicts and replaces)
        switch (conflict.kind) {
            .aur_installed, .repo_installed, .aur_replaces, .repo_replaces => {
                try removals.append(allocator, conflict.conflicts_with);
            },
            .aur_aur => {},
        }
    }
    return try removals.toOwnedSlice(allocator);
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
    cmd.err_writer = std.io.null_writer.any();
    cmd.stderr_color = color.Style.disabled;
    const result = try upgrade(&cmd, &.{});
    try testing.expectEqual(ExitCode.general_error, result);
}

test "clean returns general_error when pacman not initialized" {
    var cmd = Commands.init(testing.allocator, undefined, .{});
    cmd.err_writer = std.io.null_writer.any();
    cmd.stderr_color = color.Style.disabled;
    const result = try clean(&cmd);
    try testing.expectEqual(ExitCode.general_error, result);
}
