const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("aur.zig");
const registry_mod = @import("registry.zig");
const solver_mod = @import("solver.zig");
const repo_mod = @import("repo.zig");
const pacman_mod = @import("pacman.zig");
const devel = @import("devel.zig");

// Sub-modules (pub for test discovery via refAllDecls)
pub const query = @import("commands/query.zig");
pub const build_cmd = @import("commands/build_cmd.zig");
pub const analysis = @import("commands/analysis.zig");

// ── Types ────────────────────────────────────────────────────────────

pub const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
    build_failed = 3,
    signal_killed = 128,
};

pub const Flags = struct {
    help: bool = false,
    noconfirm: bool = false,
    noshow: bool = false,
    needed: bool = false,
    rebuild: bool = false,
    quiet: bool = false,
    raw: bool = false,
    asdeps: bool = false,
    asexplicit: bool = false,
    devel: bool = false,
    all: bool = false,
    by: ?aur.SearchField = null,
    sort: ?SortField = null,
    rsort: ?SortField = null,
    format_str: ?[]const u8 = null,
};

pub const SortField = enum {
    name,
    votes,
    popularity,

    pub fn fromString(s: []const u8) ?SortField {
        const map = std.StaticStringMap(SortField).initComptime(.{
            .{ "name", .name },
            .{ "votes", .votes },
            .{ "popularity", .popularity },
        });
        return map.get(s);
    }
};

pub const FailedBuild = struct {
    pkgbase: []const u8,
    exit_code: u32,
};

pub const BuildResult = struct {
    succeeded: []const []const u8,
    failed: []const FailedBuild,
    signal_aborted: bool,

    pub fn deinit(self: BuildResult, allocator: Allocator) void {
        allocator.free(self.succeeded);
        allocator.free(self.failed);
    }
};

pub const OutdatedEntry = struct {
    name: []const u8,
    installed_version: []const u8,
    aur_version: []const u8,
};

// ── Commands Struct ──────────────────────────────────────────────────

pub const Commands = struct {
    allocator: Allocator,
    aur_client: *aur.Client,
    pacman: ?*pacman_mod.Pacman,
    registry: ?*registry_mod.PackageRegistry,
    repo: ?*repo_mod.Repository,
    cache_root: ?[]const u8,
    flags: Flags,

    pub fn init(allocator: Allocator, aur_client: *aur.Client, flags: Flags) Commands {
        return .{
            .allocator = allocator,
            .aur_client = aur_client,
            .pacman = null,
            .registry = null,
            .repo = null,
            .cache_root = null,
            .flags = flags,
        };
    }

    pub fn initFull(
        allocator: Allocator,
        aur_client: *aur.Client,
        pm: *pacman_mod.Pacman,
        reg: *registry_mod.PackageRegistry,
        repository: *repo_mod.Repository,
        cache_root: []const u8,
        flags: Flags,
    ) Commands {
        return .{
            .allocator = allocator,
            .aur_client = aur_client,
            .pacman = pm,
            .registry = reg,
            .repo = repository,
            .cache_root = cache_root,
            .flags = flags,
        };
    }

    // ── Query commands ───────────────────────────────────────────────

    pub fn info(self: *Commands, targets: []const []const u8) !ExitCode {
        return query.info(self, targets);
    }

    pub fn search(self: *Commands, query_str: []const u8) !ExitCode {
        return query.search(self, query_str);
    }

    pub fn outdated(self: *Commands, filter: []const []const u8) !ExitCode {
        return query.outdated(self, filter);
    }

    // ── Build commands ───────────────────────────────────────────────

    pub fn show(self: *Commands, target: []const u8) !ExitCode {
        return build_cmd.show(self, target);
    }

    pub fn clonePackages(self: *Commands, targets: []const []const u8) !ExitCode {
        return build_cmd.clonePackages(self, targets);
    }

    pub fn sync(self: *Commands, targets: []const []const u8) !ExitCode {
        return build_cmd.sync(self, targets);
    }

    pub fn build(self: *Commands, targets: []const []const u8) !ExitCode {
        return build_cmd.build(self, targets);
    }

    pub fn upgrade(self: *Commands, targets: []const []const u8) !ExitCode {
        return build_cmd.upgrade(self, targets);
    }

    pub fn clean(self: *Commands) !ExitCode {
        return build_cmd.clean(self);
    }

    // ── Analysis commands ────────────────────────────────────────────

    pub fn resolve(self: *Commands, targets: []const []const u8) !ExitCode {
        return analysis.resolve(self, targets);
    }

    pub fn buildorder(self: *Commands, targets: []const []const u8) !ExitCode {
        return analysis.buildorder(self, targets);
    }
};

// ── Shared Helpers (used by sub-modules) ─────────────────────────────

pub fn displayPlan(plan: solver_mod.BuildPlan, pm: ?*pacman_mod.Pacman, removals: []const []const u8) void {
    const stdout = getStdout();
    const verbose = if (pm) |p| p.verbose_pkg_lists else false;

    // Warn about targets being reinstalled with the same version
    if (pm) |p| {
        const stderr = getStderr();
        for (plan.build_order) |entry| {
            if (!entry.is_target) continue;
            if (devel.isVcsPackage(entry.name)) continue;
            if (p.installedVersion(entry.name)) |old| {
                if (std.mem.eql(u8, old, entry.version)) {
                    stderr.print("warning: {s}-{s} is up to date -- reinstalling\n", .{ entry.name, old }) catch {};
                }
            }
        }
        for (plan.repo_targets) |name| {
            if (p.installedVersion(name)) |old| {
                const new = p.syncVersion(name) orelse continue;
                if (std.mem.eql(u8, old, new)) {
                    stderr.print("warning: {s}-{s} is up to date -- reinstalling\n", .{ name, old }) catch {};
                }
            }
        }
    }

    // Warn about detected conflicts (informational for resolve/buildorder commands;
    // sync/build handle these interactively before reaching displayPlan)
    if (plan.conflicts.len > 0) {
        const stderr = getStderr();
        for (plan.conflicts) |conflict| {
            switch (conflict.kind) {
                .aur_aur => stderr.print(
                    "warning: {s} and {s} are in conflict\n",
                    .{ conflict.package, conflict.conflicts_with },
                ) catch {},
                .aur_installed => stderr.print(
                    "warning: {s} conflicts with installed package {s}\n",
                    .{ conflict.package, conflict.conflicts_with },
                ) catch {},
                .repo_installed => stderr.print(
                    "warning: new dependency {s} conflicts with installed package {s}\n",
                    .{ conflict.package, conflict.conflicts_with },
                ) catch {},
            }
        }
    }

    // Display provider selections (informational)
    if (plan.provider_selections.len > 0) {
        const stderr = getStderr();
        for (plan.provider_selections) |sel| {
            stderr.print(":: {s} provider: {s}\n", .{ sel.dep_name, sel.chosen }) catch {};
        }
    }

    // Warn about packages flagged out-of-date on AUR
    {
        const stderr = getStderr();
        for (plan.build_order) |entry| {
            if (entry.out_of_date) |ts| {
                const es = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
                const ed = es.getEpochDay();
                const yd = ed.calculateYearDay();
                const md = yd.calculateMonthDay();
                const ds = es.getDaySeconds();
                stderr.print(
                    "warning: {s} has been flagged out of date on {d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\n",
                    .{
                        entry.name,
                        yd.year,
                        md.month.numeric(),
                        md.day_index + 1,
                        ds.getHoursIntoDay(),
                        ds.getMinutesIntoHour(),
                        ds.getSecondsIntoMinute(),
                    },
                ) catch {};
            }
        }
    }

    stdout.writeAll("resolving dependencies...\n") catch {};

    if (verbose) {
        displayPlanVerbose(plan, pm, removals, stdout);
    } else {
        displayPlanCompact(plan, pm, stdout);
    }

    if (pm) |p| {
        if (plan.repo_deps.len > 0 or plan.repo_targets.len > 0) {
            var sizes = p.repoDepSizes(plan.repo_deps);
            const target_sizes = p.repoDepSizes(plan.repo_targets);
            sizes.download += target_sizes.download;
            sizes.install += target_sizes.install;
            sizes.net_upgrade += target_sizes.net_upgrade;
            if (target_sizes.has_upgrades) sizes.has_upgrades = true;

            stdout.writeByte('\n') catch {};
            if (sizes.download > 0) {
                printSize(stdout, "Total Download Size:  ", sizes.download);
            }
            printSize(stdout, "Total Installed Size: ", sizes.install);
            if (sizes.has_upgrades) {
                printSize(stdout, "Net Upgrade Size:     ", sizes.net_upgrade);
            }
        }
    }

    stdout.writeByte('\n') catch {};
}

fn displayPlanCompact(
    plan: solver_mod.BuildPlan,
    pm: ?*pacman_mod.Pacman,
    stdout: anytype,
) void {
    const repo_count = plan.repo_deps.len + plan.repo_targets.len;
    const aur_hdr = "AUR Packages ()".len + countDigits(plan.build_order.len);
    const repo_hdr = "Repo Packages ()".len + countDigits(repo_count);
    const hdr_width = @max(aur_hdr, repo_hdr);

    if (plan.build_order.len > 0) {
        stdout.print("\nAUR Packages ({d})", .{plan.build_order.len}) catch {};
        stdout.writeByteNTimes(' ', hdr_width - aur_hdr) catch {};
        for (plan.build_order) |entry| {
            stdout.print(" aur/{s}-{s}", .{ entry.name, displayVersion(entry) }) catch {};
        }
        stdout.writeByte('\n') catch {};
    }
    if (repo_count > 0) {
        stdout.print("\nRepo Packages ({d})", .{repo_count}) catch {};
        stdout.writeByteNTimes(' ', hdr_width - repo_hdr) catch {};
        for (plan.repo_targets) |name| {
            const ver = if (pm) |p| p.syncVersion(name) orelse "?" else "?";
            stdout.print(" {s}-{s}", .{ name, ver }) catch {};
        }
        for (plan.repo_deps) |dep| {
            const ver = if (pm) |p| p.syncVersion(dep) orelse "?" else "?";
            stdout.print(" {s}-{s}", .{ dep, ver }) catch {};
        }
        stdout.writeByte('\n') catch {};
    }
}

const hdr_aur = "AUR Package ()";
const hdr_repo = "Repo Package ()";
const hdr_old_ver = "Old Version";
const hdr_new_ver = "New Version";

fn displayPlanVerbose(
    plan: solver_mod.BuildPlan,
    pm: ?*pacman_mod.Pacman,
    removals: []const []const u8,
    stdout: anytype,
) void {
    // Compute column widths across both sections, seeded from headers
    var name_col: usize = 0;
    var old_col: usize = hdr_old_ver.len;
    var has_old_version = false;

    const aur_count = plan.build_order.len + removals.len;
    if (aur_count > 0) {
        const w = hdr_aur.len + countDigits(aur_count);
        if (w > name_col) name_col = w;
    }
    const repo_count = plan.repo_deps.len + plan.repo_targets.len;
    if (repo_count > 0) {
        const w = hdr_repo.len + countDigits(repo_count);
        if (w > name_col) name_col = w;
    }

    const aur_prefix = "aur/";
    for (plan.build_order) |entry| {
        if (aur_prefix.len + entry.name.len > name_col) name_col = aur_prefix.len + entry.name.len;
        if (pm) |p| {
            if (p.installedVersion(entry.name)) |v| {
                has_old_version = true;
                if (v.len > old_col) old_col = v.len;
            }
        }
    }
    // Account for removals in column widths
    for (removals) |name| {
        if (name.len > name_col) name_col = name.len;
        if (pm) |p| {
            if (p.installedVersion(name)) |v| {
                has_old_version = true;
                if (v.len > old_col) old_col = v.len;
            }
        }
    }
    if (removals.len > 0) has_old_version = true;

    const repo_lists = [_][]const []const u8{ plan.repo_targets, plan.repo_deps };
    for (repo_lists) |list| {
        for (list) |name| {
            const repo = if (pm) |p| p.syncDbFor(name) else null;
            const w = if (repo) |r| r.len + 1 + name.len else name.len;
            if (w > name_col) name_col = w;
            if (pm) |p| {
                if (p.installedVersion(name)) |v| {
                    has_old_version = true;
                    if (v.len > old_col) old_col = v.len;
                }
            }
        }
    }

    // AUR section (includes removals)
    if (aur_count > 0) {
        stdout.writeByte('\n') catch {};
        stdout.print(hdr_aur[0 .. hdr_aur.len - 1] ++ "{d})", .{aur_count}) catch {};
        pad(stdout, countDigits(aur_count) + hdr_aur.len, name_col);
        if (has_old_version) {
            stdout.writeAll(hdr_old_ver) catch {};
            pad(stdout, hdr_old_ver.len, old_col);
        }
        stdout.writeAll(hdr_new_ver ++ "\n\n") catch {};

        // Packages being removed (old version, no new version)
        for (removals) |name| {
            stdout.writeAll(name) catch {};
            pad(stdout, name.len, name_col);
            if (has_old_version) {
                const old_ver = if (pm) |p| p.installedVersion(name) orelse "?" else "?";
                stdout.writeAll(old_ver) catch {};
                pad(stdout, old_ver.len, old_col);
            }
            stdout.writeByte('\n') catch {};
        }

        // Packages being built/installed
        for (plan.build_order) |entry| {
            stdout.print("{s}{s}", .{ aur_prefix, entry.name }) catch {};
            pad(stdout, aur_prefix.len + entry.name.len, name_col);
            if (has_old_version) {
                const old_ver = if (pm) |p| p.installedVersion(entry.name) orelse "" else "";
                if (old_ver.len > 0) {
                    stdout.writeAll(old_ver) catch {};
                    pad(stdout, old_ver.len, old_col);
                } else {
                    pad(stdout, 0, old_col);
                }
            }
            stdout.print("{s}\n", .{displayVersion(entry)}) catch {};
        }
    }

    // Repo section (targets + deps combined)
    if (repo_count > 0) {
        stdout.writeByte('\n') catch {};
        stdout.print(hdr_repo[0 .. hdr_repo.len - 1] ++ "{d})", .{repo_count}) catch {};
        pad(stdout, countDigits(repo_count) + hdr_repo.len, name_col);
        if (has_old_version) {
            stdout.writeAll(hdr_old_ver) catch {};
            pad(stdout, hdr_old_ver.len, old_col);
        }
        stdout.writeAll(hdr_new_ver ++ "\n\n") catch {};

        for (repo_lists) |list| {
            for (list) |name| {
                const repo = if (pm) |p| p.syncDbFor(name) else null;
                const ver = if (pm) |p| p.syncVersion(name) orelse "?" else "?";
                const w = if (repo) |r| blk: {
                    stdout.print("{s}/{s}", .{ r, name }) catch {};
                    break :blk r.len + 1 + name.len;
                } else blk: {
                    stdout.writeAll(name) catch {};
                    break :blk name.len;
                };
                pad(stdout, w, name_col);
                if (has_old_version) {
                    const old_ver = if (pm) |p| p.installedVersion(name) orelse "-" else "-";
                    stdout.writeAll(old_ver) catch {};
                    pad(stdout, old_ver.len, old_col);
                }
                stdout.print("{s}\n", .{ver}) catch {};
            }
        }
    }
}

fn pad(writer: anytype, current: usize, col: usize) void {
    const spaces = (col + 2) -| current;
    writer.writeByteNTimes(' ', if (spaces < 2) 2 else spaces) catch {};
}

/// Return "latest" for VCS packages whose version will be determined at build time.
fn displayVersion(entry: solver_mod.BuildEntry) []const u8 {
    return if (devel.isVcsPackage(entry.name)) "latest" else entry.version;
}

fn countDigits(n: usize) usize {
    var digits: usize = 1;
    var v = n;
    while (v >= 10) { v /= 10; digits += 1; }
    return digits;
}

fn printSize(writer: anytype, label: []const u8, bytes: i64) void {
    const abs = if (bytes < 0) -bytes else bytes;
    const sign: []const u8 = if (bytes < 0) "-" else "";
    if (abs >= 1024 * 1024) {
        writer.print("{s}{s}{d:.2} MiB\n", .{ label, sign, @as(f64, @floatFromInt(abs)) / (1024.0 * 1024.0) }) catch {};
    } else if (abs >= 1024) {
        writer.print("{s}{s}{d:.2} KiB\n", .{ label, sign, @as(f64, @floatFromInt(abs)) / 1024.0 }) catch {};
    } else {
        writer.print("{s}{s}{d} B\n", .{ label, sign, abs }) catch {};
    }
}


pub fn handleResolveError(err: anyerror) ExitCode {
    const stderr = getStderr();
    if (err == error.CircularDependency) {
        stderr.writeAll("error: circular dependency detected\n") catch {};
    } else if (err == error.UnresolvableDependency) {
        stderr.writeAll("error: unresolvable dependency\n") catch {};
    } else {
        stderr.print("error: dependency resolution failed: {}\n", .{err}) catch {};
    }
    return .general_error;
}

pub fn printError(err: anytype) !void {
    const stderr = getStderr();
    switch (err) {
        error.NetworkError => try stderr.writeAll("error: failed to connect to AUR\n"),
        error.RateLimited => try stderr.writeAll("error: AUR rate limit exceeded. Wait and retry.\n"),
        error.ApiError => try stderr.writeAll("error: AUR returned an error\n"),
        error.MalformedResponse => try stderr.writeAll("error: received malformed response from AUR\n"),
        else => try stderr.print("error: {}\n", .{err}),
    }
}

pub fn printErr(msg: []const u8) void {
    getStderr().writeAll(msg) catch {};
}

// ── I/O Helpers ──────────────────────────────────────────────────────

pub const StdWriter = @TypeOf(blk: {
    const f: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    break :blk f.deprecatedWriter();
});

pub fn getStdout() StdWriter {
    const f: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    return f.deprecatedWriter();
}

pub fn getStderr() StdWriter {
    const f: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    return f.deprecatedWriter();
}

// ── Tests ────────────────────────────────────────────────────────────

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

test "handleResolveError returns general_error for CircularDependency" {
    const result = handleResolveError(error.CircularDependency);
    try testing.expectEqual(ExitCode.general_error, result);
}

test "handleResolveError returns general_error for UnresolvableDependency" {
    const result = handleResolveError(error.UnresolvableDependency);
    try testing.expectEqual(ExitCode.general_error, result);
}

test "handleResolveError returns general_error for other errors" {
    const result = handleResolveError(error.OutOfMemory);
    try testing.expectEqual(ExitCode.general_error, result);
}
