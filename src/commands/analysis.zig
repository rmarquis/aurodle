const std = @import("std");
const registry_mod = @import("../registry.zig");
const solver_mod = @import("../solver.zig");
const cmds = @import("../commands.zig");
const color = @import("../color.zig");

const Commands = cmds.Commands;
const ExitCode = cmds.ExitCode;
const getStdout = cmds.getStdout;
const handleResolveError = cmds.handleResolveError;
const displayPlan = cmds.displayPlan;

// ── Resolve Command ──────────────────────────────────────────────────

/// Display the resolved dependency tree (human-readable).
pub fn resolve(self: *Commands, targets: []const []const u8) !ExitCode {
    const ec = self.stderr_color;
    const reg = self.registry orelse {
        self.err_writer.print("{s}error:{s} registry not initialized\n", .{ ec.red, ec.reset }) catch {};
        return .general_error;
    };

    // Filter ignored targets
    var ignore_buf: [256][]const u8 = undefined;
    const filtered = self.filterIgnored(targets, &ignore_buf);
    if (filtered.len == 0) return .success;

    var s = solver_mod.Solver.init(self.allocator, reg);
    s.ignore = self.flags.ignore;
    defer s.deinit();

    const plan = s.resolve(filtered) catch |err| {
        return handleResolveError(err, self.err_writer, ec);
    };
    defer plan.deinit(self.allocator);

    displayPlan(plan, plan.repo_deps, self.pacman, &.{}, self.err_writer, self.stdout_color, ec);
    return .success;
}

// ── Buildorder Command ───────────────────────────────────────────────

/// Display the build order as a plain list (machine-readable).
/// One package per line, in build order.
pub fn buildorder(self: *Commands, targets: []const []const u8) !ExitCode {
    const ec = self.stderr_color;
    const reg = self.registry orelse {
        self.err_writer.print("{s}error:{s} registry not initialized\n", .{ ec.red, ec.reset }) catch {};
        return .general_error;
    };

    // Filter ignored targets
    var ignore_buf: [256][]const u8 = undefined;
    const filtered = self.filterIgnored(targets, &ignore_buf);
    if (filtered.len == 0) return .success;

    var s = solver_mod.Solver.init(self.allocator, reg);
    s.ignore = self.flags.ignore;
    defer s.deinit();

    const plan = s.resolve(filtered) catch |err| {
        return handleResolveError(err, self.err_writer, ec);
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
            // Within same depth: satisfied before unsatisfied
            const sa = @intFromEnum(a.source);
            const sb = @intFromEnum(b.source);
            if (sa != sb) return sa < sb;
            // Stable tiebreak by name
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    // Show all dependencies with classification prefixes (FR-7)
    for (plan.all_deps) |dep| {
        const prefix: []const u8 = if (dep.is_target) switch (dep.source) {
            .aur, .satisfied_aur, .repo_aur => "TARGETAUR",
            .repos, .satisfied_repos => "TARGETREPO",
            .unknown => "UNKNOWN",
        } else switch (dep.source) {
            .aur => "AUR",
            .repos => "REPOS",
            .repo_aur => "REPOAUR",
            .satisfied_repos => "SATISFIEDREPOS",
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
