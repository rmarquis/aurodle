const std = @import("std");
const registry_mod = @import("../registry.zig");
const solver_mod = @import("../solver.zig");
const Source = @import("../source.zig").Source;
const types = @import("types.zig");
const build_ctx = @import("build_context.zig");
const display_mod = @import("display.zig");
const color = @import("../color.zig");

const BuildContext = build_ctx.BuildContext;
const ExitCode = types.ExitCode;
const getStdout = types.getStdout;
const handleResolveError = types.handleResolveError;
const displayPlan = display_mod.displayPlan;

// ── Resolve Command ──────────────────────────────────────────────────

/// Display the resolved dependency tree (human-readable).
pub fn resolve(self: *BuildContext, targets: []const []const u8) !ExitCode {
    const ec = self.stderr_color;

    // Filter ignored targets
    var ignore_buf: [256][]const u8 = undefined;
    const filtered = types.filterIgnored(self.stdout_color, self.stderr_color, self.err_writer, self.flags, targets, &ignore_buf);
    if (filtered.len == 0) return .success;

    var s = solver_mod.Solver.init(self.allocator, self.registry, self.flags.solverOptions());
    defer s.deinit();

    const plan = s.resolve(filtered) catch |err| {
        return handleResolveError(err, s.unresolved, self.err_writer, ec);
    };
    defer plan.deinit(self.allocator);

    displayPlan(plan, .{
        .repo_deps = plan.repo_deps,
        .pacman = self.pacman,
        .devel_versions = &self.devel_version_hint,
        .err_writer = self.err_writer,
        .stdout_color = self.stdout_color,
        .stderr_color = ec,
    });
    return .success;
}

// ── Buildorder Command ───────────────────────────────────────────────

/// Display the build order as a plain list (machine-readable).
/// One package per line, in build order.
pub fn buildorder(self: *BuildContext, targets: []const []const u8) !ExitCode {
    const ec = self.stderr_color;

    // Filter ignored targets
    var ignore_buf: [256][]const u8 = undefined;
    const filtered = types.filterIgnored(self.stdout_color, self.stderr_color, self.err_writer, self.flags, targets, &ignore_buf);
    if (filtered.len == 0) return .success;

    var s = solver_mod.Solver.init(self.allocator, self.registry, self.flags.solverOptions());
    defer s.deinit();

    const plan = s.resolve(filtered) catch |err| {
        return handleResolveError(err, s.unresolved, self.err_writer, ec);
    };
    defer plan.deinit(self.allocator);

    display_mod.warnStaleRepoDeps(plan, self.err_writer, ec);
    writeBuildOrder(getStdout(), self.pacman, plan.all_deps, self.flags.quiet);
    return .success;
}

/// Write `all_deps`, already in build order (dependencies first), one
/// "PREFIX pkgbase pkgname" line per package (FR-7), or "PREFIX pkgname"
/// when no pkgbase is known. With `quiet`, only the packages that get
/// built, so TARGETAUR there always means the target is built.
///
/// `out` needs print(fmt, args); `pm` needs installedPkgbase and
/// aurRepoPkgbase, as Pacman has.
pub fn writeBuildOrder(out: anytype, pm: anytype, all_deps: []const solver_mod.DependencyEntry, quiet: bool) void {
    for (all_deps) |dep| {
        if (quiet and dep.source != .aur) continue;
        // Without AUR metadata (installed or local-repo packages that were
        // not traversed), take the pkgbase from the pacman databases so
        // every AUR-sourced line carries one.
        const pkgbase = dep.pkgbase orelse switch (dep.source) {
            .satisfied_aur => pm.installedPkgbase(dep.name),
            .repo_aur => pm.aurRepoPkgbase(dep.name),
            else => null,
        };
        if (pkgbase) |base| {
            out.print("{s} {s} {s}\n", .{ buildOrderPrefix(dep), base, dep.name });
        } else {
            out.print("{s} {s}\n", .{ buildOrderPrefix(dep), dep.name });
        }
    }
}

fn buildOrderPrefix(dep: solver_mod.DependencyEntry) []const u8 {
    return if (dep.is_target) switch (dep.source) {
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
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

/// Collects output in memory.
const TestOut = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *TestOut) void {
        self.buf.deinit(testing.allocator);
    }

    fn print(self: *TestOut, comptime fmt: []const u8, args: anytype) void {
        const line = std.fmt.allocPrint(testing.allocator, fmt, args) catch unreachable;
        defer testing.allocator.free(line);
        self.buf.appendSlice(testing.allocator, line) catch unreachable;
    }
};

/// Pkgbases the pacman databases know for installed and local-repo
/// packages: "installed" and "cached" belong to "base".
const TestPacman = struct {
    fn installedPkgbase(_: TestPacman, name: []const u8) ?[]const u8 {
        return if (std.mem.eql(u8, name, "installed")) "base" else null;
    }
    fn aurRepoPkgbase(_: TestPacman, name: []const u8) ?[]const u8 {
        return if (std.mem.eql(u8, name, "cached")) "base" else null;
    }
};

fn entry(name: []const u8, pkgbase: ?[]const u8, source: Source, is_target: bool) solver_mod.DependencyEntry {
    return .{ .name = name, .pkgbase = pkgbase, .source = source, .is_target = is_target };
}

const mixed_deps = [_]solver_mod.DependencyEntry{
    entry("glibc", null, .satisfied_repos, false),
    entry("zlib", null, .repos, false),
    entry("installed", null, .satisfied_aur, false),
    entry("orphan", null, .satisfied_aur, false),
    entry("cached", null, .repo_aur, false),
    entry("lib-a", "lib", .aur, false),
    entry("lib-b", "lib", .aur, false),
    entry("app", "app", .aur, true),
    entry("current", "current", .satisfied_aur, true),
    entry("local", "local", .repo_aur, true),
    entry("expac", null, .repos, true),
    entry("pacman", null, .satisfied_repos, true),
};

test "writeBuildOrder prints every package with its prefix, in order" {
    var out: TestOut = .{};
    defer out.deinit();
    writeBuildOrder(&out, TestPacman{}, &mixed_deps, false);
    try testing.expectEqualStrings(
        \\SATISFIEDREPOS glibc
        \\REPOS zlib
        \\SATISFIEDAUR base installed
        \\SATISFIEDAUR orphan
        \\REPOAUR base cached
        \\AUR lib lib-a
        \\AUR lib lib-b
        \\TARGETAUR app app
        \\TARGETAUR current current
        \\TARGETAUR local local
        \\TARGETREPO expac
        \\TARGETREPO pacman
        \\
    , out.buf.items);
}

test "writeBuildOrder --quiet keeps only the packages that get built" {
    var out: TestOut = .{};
    defer out.deinit();
    writeBuildOrder(&out, TestPacman{}, &mixed_deps, true);
    try testing.expectEqualStrings(
        \\AUR lib lib-a
        \\AUR lib lib-b
        \\TARGETAUR app app
        \\
    , out.buf.items);
}

test "writeBuildOrder marks unknown packages, target or not" {
    var out: TestOut = .{};
    defer out.deinit();
    const deps = [_]solver_mod.DependencyEntry{
        entry("gone", null, .unknown, false),
        entry("typo", null, .unknown, true),
    };
    writeBuildOrder(&out, TestPacman{}, &deps, false);
    try testing.expectEqualStrings("UNKNOWN gone\nUNKNOWN typo\n", out.buf.items);
}
