const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("../aur.zig");
const git = @import("../git.zig");
const devel = @import("../devel.zig");
const solver_mod = @import("../solver.zig");
const repo_mod = @import("../repo.zig");
const pacman_mod = @import("../pacman.zig");
const utils = @import("../utils.zig");
const color = @import("../color.zig");
const cmds = @import("context.zig");
const display_mod = @import("display.zig");
const outdated_mod = @import("outdated.zig");

const build_phase = @import("build_cmd/build.zig");
const install_phase = @import("build_cmd/install.zig");
const review_phase = @import("build_cmd/review.zig");

const Commands = cmds.Commands;
const ExitCode = cmds.ExitCode;
const BuildResult = cmds.BuildResult;
const FailedBuild = cmds.FailedBuild;
const getStdout = cmds.getStdout;
const printError = cmds.printError;
const handleResolveError = cmds.handleResolveError;
const displayPlan = display_mod.displayPlan;

// Re-export for callers that import hasFailedDep directly (e.g. tests, context.zig).
pub const hasFailedDep = build_phase.hasFailedDep;

// ── Show Command ─────────────────────────────────────────────────────

/// Display build files for a package clone.
pub fn show(self: *Commands, target: []const u8) !ExitCode {
    const ec = self.stderr_color;
    const cache = git.resolveCacheRoot(self.cache_root, self.allocator) catch {
        self.err_writer.print("{s}error:{s} could not determine cache directory (HOME not set)\n", .{ ec.red, ec.reset }) catch {};
        return .general_error;
    };
    const c_root = cache.path;
    defer git.freeCacheRoot(cache, self.allocator);

    const pkgbase = blk: {
        if (self.aur_client.info(target) catch null) |pkg| {
            break :blk pkg.pkgbase;
        }
        break :blk target;
    };

    if (!try git.isCloned(self.allocator, c_root, pkgbase)) {
        self.err_writer.print("{s}error:{s} {s} is not cloned. Run 'aurodle sync {s}' first.\n", .{ ec.red, ec.reset, target, target }) catch {};
        return .general_error;
    }

    const clone_dir = try git.cloneDir(self.allocator, c_root, pkgbase);
    defer self.allocator.free(clone_dir);

    const viewer = review_phase.getViewer();
    const exit_code = utils.runInteractive(self.allocator, &.{ viewer, clone_dir }, null) catch |err| {
        self.err_writer.print("{s}error:{s} could not open viewer ({s}): {}\n", .{ ec.red, ec.reset, viewer, err }) catch {};
        return .general_error;
    };

    return if (exit_code == 0) .success else .general_error;
}

// ── Clone Command ────────────────────────────────────────────────────

/// Clone AUR packages to the cache directory (FR-8).
pub fn clonePackages(self: *Commands, targets: []const []const u8) !ExitCode {
    const ec = self.stderr_color;
    const stdout = getStdout();

    const packages = self.aur_client.multiInfo(targets) catch |err| {
        try printError(err, self.err_writer, ec);
        return .general_error;
    };
    defer self.allocator.free(packages);

    var pkgbase_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer pkgbase_map.deinit(self.allocator);
    for (packages) |pkg| {
        try pkgbase_map.put(self.allocator, pkg.name, pkg.pkgbase);
    }

    var any_error = false;
    for (targets) |target| {
        if (!pkgbase_map.contains(target)) {
            self.err_writer.print("{s}error:{s} package '{s}' was not found\n", .{ ec.red, ec.reset, target }) catch {};
            any_error = true;
        }
    }

    const cache = git.resolveCacheRoot(self.cache_root, self.allocator) catch {
        self.err_writer.print("{s}error:{s} could not determine cache directory (HOME not set)\n", .{ ec.red, ec.reset }) catch {};
        return .general_error;
    };
    const c_root = cache.path;
    defer git.freeCacheRoot(cache, self.allocator);

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

// ── Sync / Build Commands ────────────────────────────────────────────

const BuildMode = enum { sync, build_only };

/// Execute the full sync workflow: resolve -> clone -> review -> build -> install.
pub fn sync(self: *Commands, targets: []const []const u8) !ExitCode {
    var ignore_buf: [256][]const u8 = undefined;
    const filtered = self.filterIgnored(targets, &ignore_buf);
    if (filtered.len == 0) return .success;
    return runBuildPipeline(self, filtered, .sync);
}

/// Build packages and add to repository without installing.
pub fn build(self: *Commands, targets: []const []const u8) !ExitCode {
    var ignore_buf: [256][]const u8 = undefined;
    const filtered = self.filterIgnored(targets, &ignore_buf);
    if (filtered.len == 0) return .success;
    return runBuildPipeline(self, filtered, .build_only);
}

/// Shared pipeline for sync, build, and upgrade. Callers pass pre-filtered
/// targets (ignore prompting handled upstream).
/// Phases: resolve -> conflicts -> providers -> display -> clone -> review ->
///         build -> [install].  The final install phase runs only in .sync mode.
pub fn runBuildPipeline(self: *Commands, filtered: []const []const u8, mode: BuildMode) !ExitCode {
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
        removals = try review_phase.resolveConflicts(self.allocator, plan.conflicts, self.stdout_color) orelse {
            self.err_writer.print("{s}::{s} unresolvable package conflicts detected\n", .{ ec.red, ec.reset }) catch {};
            return .general_error;
        };
    }
    defer self.allocator.free(removals);

    if (plan.build_order.len == 0) {
        return handleEmptyBuildOrder(self, plan, mode);
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
        try install_phase.selectRepoDepsProviders(
            self.allocator,
            choices,
            self.flags.noconfirm,
            self.stdout_color,
            &chosen_providers,
            &providers_to_install,
        );
    }

    const repo_deps_full = if (self.pacman) |pm|
        try pm.transitiveRepoDeps(self.allocator, plan.repo_deps, chosen_providers)
    else
        try self.allocator.dupe([]const u8, plan.repo_deps);
    defer self.allocator.free(repo_deps_full);

    // Phase 2: Display and confirm
    displayPlan(plan, repo_deps_full, self.pacman, removals, self.err_writer, self.stdout_color, ec, &self.devel_version_hint);

    const prompt: []const u8 = switch (mode) {
        .sync => "Proceed with installation?",
        .build_only => "Proceed with build?",
    };
    if (!self.flags.noconfirm) {
        if (!try utils.promptYesNoStyled(self.stdout_color, prompt)) {
            return .success;
        }
    }

    // Phase 3: Clone
    for (plan.build_order) |entry| {
        const clone_result = git.cloneOrUpdate(self.allocator, c_root, entry.pkgbase) catch |err| {
            self.err_writer.print("{s}error:{s} failed to clone/update '{s}': {}\n", .{ ec.red, ec.reset, entry.pkgbase, err }) catch {};
            return .general_error;
        };
        if (clone_result == .reCloned) {
            self.err_writer.print("{s}warning:{s} cached repository for '{s}' was invalid and has been re-cloned\n", .{ ec.yellow, ec.reset, entry.pkgbase }) catch {};
        }
    }

    // Phase 4: Review (unless --noshow)
    if (!self.flags.noshow) {
        try review_phase.reviewPackages(self, plan.build_order, c_root);
    }

    // Phase 4.5: Acquire credentials now that the user has committed
    if (try install_phase.acquireAuth(self)) |exit| return exit;

    // Pre-install chosen providers so makepkg -s finds them already installed
    if (providers_to_install.items.len > 0) {
        if (!try install_phase.preInstallProviders(self, providers_to_install.items)) return .general_error;
    }

    // Phase 5: Build
    try repository.ensureExists();
    const build_result = try build_phase.buildLoop(self, plan, repository, c_root);
    defer build_result.deinit(self.allocator);

    if (build_result.signal_aborted) return .signal_killed;

    if (build_result.succeeded.len > 0) {
        repo_mod.refreshAurpkgsSyncDb(self.allocator, repository, self.auth.?) catch |err| {
            self.err_writer.print("{s}warning:{s} failed to refresh aurpkgs sync db: {}\n", .{ ec.yellow, ec.reset, err }) catch {};
        };
    }

    // Phase 6 (sync only): Install targets.
    if (mode == .sync) {
        var aur_targets: std.ArrayListUnmanaged([]const u8) = .empty;
        defer aur_targets.deinit(self.allocator);
        for (plan.build_order) |entry| {
            for (entry.target_names) |tname| {
                try aur_targets.append(self.allocator, tname);
            }
        }

        install_phase.purgePacmanCache(self, build_result.built_pkg_basenames);

        if (build_result.failed.len == 0) {
            try install_phase.installAllTargets(self, aur_targets.items, plan.repo_targets);
        } else {
            const installable = try install_phase.filterInstallable(self, aur_targets.items, build_result);
            defer self.allocator.free(installable);
            if (installable.len > 0 or plan.repo_targets.len > 0) {
                try install_phase.installAllTargets(self, installable, plan.repo_targets);
            }
            printBuildSummary(build_result, self.err_writer, ec);
            return .build_failed;
        }
    } else if (build_result.failed.len > 0) {
        printBuildSummary(build_result, self.err_writer, ec);
        return .build_failed;
    }

    return .success;
}

fn handleEmptyBuildOrder(self: *Commands, plan: solver_mod.BuildPlan, mode: BuildMode) !ExitCode {
    if (mode == .build_only) {
        getStdout().writeAll(" nothing to do -- all targets are up to date\n") catch {};
        return .success;
    }

    var aurpkgs_targets: std.ArrayListUnmanaged([]const u8) = .empty;
    defer aurpkgs_targets.deinit(self.allocator);
    for (plan.all_deps) |dep| {
        if (!dep.is_target) continue;
        if (dep.source == .repo_aur) {
            try aurpkgs_targets.append(self.allocator, dep.name);
        } else if (dep.source == .satisfied_aur and !self.flags.needed) {
            if (self.pacman) |pm| {
                if (pm.isAurRepo(pm.syncDbFor(dep.name) orelse "")) {
                    try aurpkgs_targets.append(self.allocator, dep.name);
                }
            }
        }
    }

    if (aurpkgs_targets.items.len == 0 and plan.repo_targets.len == 0) {
        getStdout().writeAll(" nothing to do -- all targets are up to date\n") catch {};
        return .success;
    }

    var all_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer all_names.deinit(self.allocator);
    try all_names.appendSlice(self.allocator, aurpkgs_targets.items);
    try all_names.appendSlice(self.allocator, plan.repo_targets);
    display_mod.displayInstallList(all_names.items, self.pacman, self.err_writer, self.stdout_color, self.stderr_color);

    if (!self.flags.noconfirm) {
        if (!try utils.promptYesNoStyled(self.stdout_color, "Proceed with installation?")) {
            return .success;
        }
    }

    try install_phase.installAllTargets(self, aurpkgs_targets.items, plan.repo_targets);
    return .success;
}

// ── Upgrade Command ──────────────────────────────────────────────────

/// Upgrade outdated AUR packages via the full sync workflow.
pub fn upgrade(self: *Commands, targets: []const []const u8) !ExitCode {
    const ec = self.stderr_color;
    const sc = self.stdout_color;

    if (self.pacman == null) {
        self.err_writer.print("{s}error:{s} pacman not initialized\n", .{ ec.red, ec.reset }) catch {};
        return .general_error;
    }

    getStdout().print("{s}::{s} Starting AUR upgrade...\n", .{ sc.blue, sc.reset }) catch {};

    const result = (try outdated_mod.collectOutdated(self, targets, true)) orelse return .general_error;
    defer result.deinit(self.allocator);
    defer self.devel_version_hint.clearAndFree(self.allocator);

    var to_upgrade: std.ArrayListUnmanaged([]const u8) = .empty;
    defer to_upgrade.deinit(self.allocator);
    try to_upgrade.ensureUnusedCapacity(self.allocator, result.entries.len);
    for (result.entries) |entry| {
        if (entry.ignored) {
            self.err_writer.print(
                "{s}warning:{s} {s}: ignoring package upgrade\n",
                .{ ec.yellow, ec.reset, entry.name },
            ) catch {};
            continue;
        }
        to_upgrade.appendAssumeCapacity(entry.name);
    }

    if (to_upgrade.items.len == 0) {
        getStdout().writeAll(" there is nothing to do\n") catch {};
        return .success;
    }

    return runBuildPipeline(self, to_upgrade.items, .sync);
}

// ── Clean Command ────────────────────────────────────────────────────

/// Remove stale aurpkgs artifacts after user confirmation.
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
        if (!self.flags.quiet) getStdout().writeAll(" nothing to clean\n") catch {};
        return .success;
    }

    const stdout = getStdout();
    const c = self.stdout_color;

    const pkg_label = if (self.flags.all) "Packages" else "Stale packages";
    const clone_label = if (self.flags.all) "Clone directories" else "Stale clone directories";

    if (plan.removed_packages.len > 0) {
        stdout.print("{s}::{s} {s} ({d}):\n", .{ c.blue, c.reset, pkg_label, plan.removed_packages.len }) catch {};
        for (plan.removed_packages) |filename| stdout.print("  {s}\n", .{filename}) catch {};
    }

    if (plan.removed_clones.len > 0) {
        stdout.print("{s}::{s} {s} ({d}):\n", .{ c.blue, c.reset, clone_label, plan.removed_clones.len }) catch {};
        for (plan.removed_clones) |name| stdout.print("  {s}/\n", .{name}) catch {};
    }

    if (!self.flags.noconfirm) {
        if (!try utils.promptYesNoStyled(self.stdout_color, "Proceed with cleanup?")) return .success;
    }

    repository.cleanExecute(plan);

    if (plan.removed_packages.len > 0) {
        repo_mod.refreshAurpkgsSyncDb(self.allocator, repository, self.auth.?) catch |err| {
            self.err_writer.print("{s}warning:{s} failed to refresh aurpkgs sync db: {}\n", .{ ec.yellow, ec.reset, err }) catch {};
        };
    }

    return .success;
}

fn printBuildSummary(result: BuildResult, err_writer: std.io.AnyWriter, ec: color.Style) void {
    err_writer.print("\n{s}::{s} Build summary: {d} succeeded, {d} failed\n", .{
        ec.blue, ec.reset, result.succeeded.len, result.failed.len,
    }) catch {};
    for (result.failed) |f| {
        err_writer.print("  {s}FAILED:{s} {s} (exit {d})\n", .{ ec.red, ec.reset, f.pkgbase, f.exit_code }) catch {};
    }
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
    try testing.expect(!build_phase.hasFailedDep(entry, &failed));
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
    try testing.expect(build_phase.hasFailedDep(entry, &failed));
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
    try testing.expect(!build_phase.hasFailedDep(entry, &failed));
}

test "anySubsequentEntryNeeds returns true when future entry depends on pkgbase" {
    const entries = [_]solver_mod.BuildEntry{
        .{ .name = "B", .pkgbase = "B", .version = "1.0", .is_target = false, .aur_dep_bases = &.{"A"} },
        .{ .name = "C", .pkgbase = "C", .version = "1.0", .is_target = true, .aur_dep_bases = &.{"B"} },
    };
    try testing.expect(build_phase.anySubsequentEntryNeeds(&entries, "A"));
    try testing.expect(build_phase.anySubsequentEntryNeeds(entries[1..], "B"));
}

test "anySubsequentEntryNeeds returns false when no future entry depends on pkgbase" {
    const entries = [_]solver_mod.BuildEntry{
        .{ .name = "B", .pkgbase = "B", .version = "1.0", .is_target = false, .aur_dep_bases = &.{"A"} },
        .{ .name = "C", .pkgbase = "C", .version = "1.0", .is_target = true, .aur_dep_bases = &.{} },
    };
    try testing.expect(!build_phase.anySubsequentEntryNeeds(&entries, "B"));
    try testing.expect(!build_phase.anySubsequentEntryNeeds(entries[2..], "A"));
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
