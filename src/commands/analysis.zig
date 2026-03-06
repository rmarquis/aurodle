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

    // Show all dependencies with classification prefixes (FR-7)
    for (plan.all_deps) |dep| {
        const prefix: []const u8 = if (dep.is_target) "TARGET" else switch (dep.source) {
            .aur => "AUR",
            .repos => "REPOS",
            .satisfied => "SATISFIED",
            .unknown => "UNKNOWN",
        };
        stdout.print("{s} {s}\n", .{ prefix, dep.name }) catch {};
    }
    return .success;
}
