const std = @import("std");
const registry_mod = @import("../registry.zig");
const solver_mod = @import("../solver.zig");
const cmds = @import("../commands.zig");

const Commands = cmds.Commands;
const ExitCode = cmds.ExitCode;
const getStdout = cmds.getStdout;
const handleResolveError = cmds.handleResolveError;
const displayPlan = cmds.displayPlan;

// ── Resolve Command ──────────────────────────────────────────────────

/// Display the resolved dependency tree (human-readable).
pub fn resolve(self: *Commands, targets: []const []const u8) !ExitCode {
    const reg = self.registry orelse {
        cmds.printErr("error: registry not initialized\n");
        return .general_error;
    };

    var s = solver_mod.Solver.init(self.allocator, reg);
    defer s.deinit();

    const plan = s.resolve(targets) catch |err| {
        return handleResolveError(err);
    };
    defer plan.deinit(self.allocator);

    displayPlan(plan);
    return .success;
}

// ── Buildorder Command ───────────────────────────────────────────────

/// Display the build order as a plain list (machine-readable).
/// One package per line, in build order.
pub fn buildorder(self: *Commands, targets: []const []const u8) !ExitCode {
    const reg = self.registry orelse {
        cmds.printErr("error: registry not initialized\n");
        return .general_error;
    };

    var s = solver_mod.Solver.init(self.allocator, reg);
    defer s.deinit();

    const plan = s.resolve(targets) catch |err| {
        return handleResolveError(err);
    };
    defer plan.deinit(self.allocator);

    const stdout = getStdout();

    // Sort: non-targets first (deepest deps first), then targets last
    std.mem.sort(solver_mod.DependencyEntry, plan.all_deps, {}, struct {
        fn lessThan(_: void, a: solver_mod.DependencyEntry, b: solver_mod.DependencyEntry) bool {
            // Targets always come after non-targets
            if (a.is_target != b.is_target) return !a.is_target;
            // Among non-targets, deeper deps come first
            if (a.depth != b.depth) return a.depth > b.depth;
            // Stable tiebreak by name
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    // Show all dependencies with classification prefixes (FR-7)
    for (plan.all_deps) |dep| {
        const prefix: []const u8 = if (dep.is_target) switch (dep.source) {
            .aur, .satisfied_aur => "TARGETAUR",
            .repos, .satisfied_repo => "TARGETREPO",
            .unknown => "UNKNOWN",
        } else switch (dep.source) {
            .aur => "AUR",
            .repos => "REPOS",
            .satisfied_repo => "SATISFIEDREPO",
            .satisfied_aur => "SATISFIEDAUR",
            .unknown => "UNKNOWN",
        };
        if (dep.pkgbase) |pkgbase| {
            stdout.print("{s} {s} {s}\n", .{ prefix, pkgbase, dep.name }) catch {};
        } else {
            stdout.print("{s} {s}\n", .{ prefix, dep.name }) catch {};
        }
    }
    return .success;
}
