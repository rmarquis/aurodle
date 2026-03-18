const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("aur.zig");
const registry_mod = @import("registry.zig");
const solver_mod = @import("solver.zig");
const repo_mod = @import("repo.zig");
const pacman_mod = @import("pacman.zig");
const devel = @import("devel.zig");
const color = @import("color.zig");

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
    ignore: []const []const u8 = &.{},
    ignore_buf: [64][]const u8 = undefined,
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
    err_writer: std.io.AnyWriter,
    stdout_color: color.Style,
    stderr_color: color.Style,

    pub fn init(allocator: Allocator, aur_client: *aur.Client, flags: Flags) Commands {
        return .{
            .allocator = allocator,
            .aur_client = aur_client,
            .pacman = null,
            .registry = null,
            .repo = null,
            .cache_root = null,
            .flags = flags,
            .err_writer = defaultErrWriter(),
            .stdout_color = color.Style.disabled,
            .stderr_color = color.Style.disabled,
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
        const use_color = pm.color;
        return .{
            .allocator = allocator,
            .aur_client = aur_client,
            .pacman = pm,
            .registry = reg,
            .repo = repository,
            .cache_root = cache_root,
            .flags = flags,
            .err_writer = defaultErrWriter(),
            .stdout_color = color.Style.detect(std.posix.STDOUT_FILENO, use_color),
            .stderr_color = color.Style.detect(std.posix.STDERR_FILENO, use_color),
        };
    }

    /// Filter out ignored packages from a target list.
    /// Prints a warning for each ignored target on stderr.
    /// Returns the filtered slice (backed by the provided buffer).
    pub fn filterIgnored(self: *Commands, targets: []const []const u8, buf: [][]const u8) []const []const u8 {
        if (self.flags.ignore.len == 0) return targets;

        const ec = self.stderr_color;
        var count: usize = 0;
        for (targets) |target| {
            if (self.isIgnored(target)) {
                self.err_writer.print(
                    "{s}warning:{s} {s} is in IgnorePkg -- skipping\n",
                    .{ ec.yellow, ec.reset, target },
                ) catch {};
            } else {
                buf[count] = target;
                count += 1;
            }
        }
        return buf[0..count];
    }

    pub fn isIgnored(self: *Commands, name: []const u8) bool {
        for (self.flags.ignore) |ignored| {
            if (std.mem.eql(u8, ignored, name)) return true;
        }
        return false;
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

pub fn displayPlan(plan: solver_mod.BuildPlan, pm: ?*pacman_mod.Pacman, removals: []const []const u8, err_writer: std.io.AnyWriter, c: color.Style, ec: color.Style) void {
    const stdout = getStdout();
    const verbose = if (pm) |p| p.verbose_pkg_lists else false;

    // Warn about targets being reinstalled with the same version
    if (pm) |p| {
        for (plan.build_order) |entry| {
            if (!entry.is_target) continue;
            if (devel.isVcsPackage(entry.name)) continue;
            if (p.installedVersion(entry.name)) |old| {
                if (std.mem.eql(u8, old, entry.version)) {
                    err_writer.print("{s}warning:{s} {s}-{s} is up to date -- reinstalling\n", .{ ec.yellow, ec.reset, entry.name, old }) catch {};
                }
            }
        }
        for (plan.repo_targets) |name| {
            if (p.installedVersion(name)) |old| {
                const new = p.syncVersion(name) orelse continue;
                if (std.mem.eql(u8, old, new)) {
                    err_writer.print("{s}warning:{s} {s}-{s} is up to date -- reinstalling\n", .{ ec.yellow, ec.reset, name, old }) catch {};
                }
            }
        }
    }

    // Warn about detected conflicts (informational for resolve/buildorder commands;
    // sync/build handle these interactively before reaching displayPlan)
    if (plan.conflicts.len > 0) {
        for (plan.conflicts) |conflict| {
            switch (conflict.kind) {
                .aur_aur => err_writer.print(
                    "{s}warning:{s} {s} and {s} are in conflict\n",
                    .{ ec.yellow, ec.reset, conflict.package, conflict.conflicts_with },
                ) catch {},
                .aur_installed => err_writer.print(
                    "{s}warning:{s} {s} conflicts with installed package {s}\n",
                    .{ ec.yellow, ec.reset, conflict.package, conflict.conflicts_with },
                ) catch {},
                .repo_installed => err_writer.print(
                    "{s}warning:{s} new dependency {s} conflicts with installed package {s}\n",
                    .{ ec.yellow, ec.reset, conflict.package, conflict.conflicts_with },
                ) catch {},
                .aur_replaces => err_writer.print(
                    "{s}warning:{s} aur/{s} replaces installed package {s}\n",
                    .{ ec.yellow, ec.reset, conflict.package, conflict.conflicts_with },
                ) catch {},
                .repo_replaces => err_writer.print(
                    "{s}warning:{s} {s} replaces installed package {s}\n",
                    .{ ec.yellow, ec.reset, conflict.package, conflict.conflicts_with },
                ) catch {},
            }
        }
    }

    // Display provider selections (informational)
    if (plan.provider_selections.len > 0) {
        for (plan.provider_selections) |sel| {
            err_writer.print("{s}::{s} {s} provider: {s}\n", .{ ec.blue, ec.reset, sel.dep_name, sel.chosen }) catch {};
        }
    }

    // Warn about packages flagged out-of-date on AUR
    {
        for (plan.build_order) |entry| {
            if (entry.out_of_date) |ts| {
                const es = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
                const ed = es.getEpochDay();
                const yd = ed.calculateYearDay();
                const md = yd.calculateMonthDay();
                const ds = es.getDaySeconds();
                err_writer.print(
                    "{s}warning:{s} {s} has been flagged {s}out of date{s} on {s}{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z{s}\n",
                    .{
                        ec.yellow,
                        ec.reset,
                        entry.name,
                        ec.red,
                        ec.reset,
                        ec.yellow,
                        yd.year,
                        md.month.numeric(),
                        md.day_index + 1,
                        ds.getHoursIntoDay(),
                        ds.getMinutesIntoHour(),
                        ds.getSecondsIntoMinute(),
                        ec.reset,
                    },
                ) catch {};
            }
        }
    }

    stdout.writeAll("resolving dependencies...\n") catch {};

    if (verbose) {
        displayPlanVerbose(plan, pm, removals, stdout, c);
    } else {
        displayPlanCompact(plan, pm, stdout, c);
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
    c: color.Style,
) void {
    const total = plan.build_order.len + plan.repo_deps.len + plan.repo_targets.len;
    if (total == 0) return;

    stdout.print("\nPackages ({d})", .{total}) catch {};
    for (plan.build_order) |entry| {
        stdout.print(" {s}aur/{s}{s}-{s}", .{ c.magenta, c.reset, entry.name, displayVersion(entry) }) catch {};
    }
    for (plan.repo_targets) |name| {
        printCompactRepoPkg(pm, name, stdout, c);
    }
    for (plan.repo_deps) |dep| {
        printCompactRepoPkg(pm, dep, stdout, c);
    }
    stdout.writeByte('\n') catch {};
}

fn printCompactRepoPkg(pm: ?*pacman_mod.Pacman, name: []const u8, stdout: anytype, c: color.Style) void {
    const repo = if (pm) |p| p.syncDbFor(name) else null;
    const ver = if (pm) |p| p.syncVersion(name) orelse "?" else "?";
    if (repo) |r| {
        stdout.print(" {s}{s}/{s}{s}-{s}", .{ c.magenta, r, c.reset, name, ver }) catch {};
    } else {
        stdout.print(" {s}-{s}", .{ name, ver }) catch {};
    }
}

const hdr_pkg = "Package ()";
const hdr_old_ver = "Old Version";
const hdr_new_ver = "New Version";

fn displayPlanVerbose(
    plan: solver_mod.BuildPlan,
    pm: ?*pacman_mod.Pacman,
    removals: []const []const u8,
    stdout: anytype,
    c: color.Style,
) void {
    const total = plan.build_order.len + removals.len + plan.repo_deps.len + plan.repo_targets.len;
    if (total == 0) return;

    // Compute column widths, seeded from header
    var name_col: usize = hdr_pkg.len + countDigits(total);
    var old_col: usize = hdr_old_ver.len;
    var has_old_version = false;

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

    // Single header
    stdout.writeByte('\n') catch {};
    stdout.print(hdr_pkg[0 .. hdr_pkg.len - 1] ++ "{d})", .{total}) catch {};
    pad(stdout, countDigits(total) + hdr_pkg.len, name_col);
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
            stdout.print("{s}{s}{s}", .{ c.red, old_ver, c.reset }) catch {};
            pad(stdout, old_ver.len, old_col);
        }
        stdout.writeByte('\n') catch {};
    }

    // AUR packages being built/installed
    for (plan.build_order) |entry| {
        stdout.print("{s}{s}{s}{s}", .{ c.magenta, aur_prefix, c.reset, entry.name }) catch {};
        pad(stdout, aur_prefix.len + entry.name.len, name_col);
        if (has_old_version) {
            const old_ver = if (pm) |p| p.installedVersion(entry.name) orelse "" else "";
            if (old_ver.len > 0) {
                stdout.print("{s}{s}{s}", .{ c.red, old_ver, c.reset }) catch {};
                pad(stdout, old_ver.len, old_col);
            } else {
                pad(stdout, 0, old_col);
            }
        }
        stdout.print("{s}{s}{s}\n", .{ c.green, displayVersion(entry), c.reset }) catch {};
    }

    // Repo packages (targets + deps)
    for (repo_lists) |list| {
        for (list) |name| {
            const repo = if (pm) |p| p.syncDbFor(name) else null;
            const ver = if (pm) |p| p.syncVersion(name) orelse "?" else "?";
            const w = if (repo) |r| blk: {
                stdout.print("{s}{s}/{s}{s}", .{ c.magenta, r, c.reset, name }) catch {};
                break :blk r.len + 1 + name.len;
            } else blk: {
                stdout.writeAll(name) catch {};
                break :blk name.len;
            };
            pad(stdout, w, name_col);
            if (has_old_version) {
                const old_ver = if (pm) |p| p.installedVersion(name) orelse "-" else "-";
                if (!std.mem.eql(u8, old_ver, "-")) {
                    stdout.print("{s}{s}{s}", .{ c.red, old_ver, c.reset }) catch {};
                } else {
                    stdout.writeAll(old_ver) catch {};
                }
                pad(stdout, old_ver.len, old_col);
            }
            stdout.print("{s}{s}{s}\n", .{ c.green, ver, c.reset }) catch {};
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
    while (v >= 10) {
        v /= 10;
        digits += 1;
    }
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

pub fn handleResolveError(err: anyerror, err_writer: std.io.AnyWriter, ec: color.Style) ExitCode {
    if (err == error.CircularDependency) {
        err_writer.print("{s}error:{s} circular dependency detected\n", .{ ec.red, ec.reset }) catch {};
    } else if (err == error.UnresolvableDependency) {
        err_writer.print("{s}error:{s} unresolvable dependency\n", .{ ec.red, ec.reset }) catch {};
    } else if (err == error.IgnoredDependency) {
        err_writer.print("{s}error:{s} a required dependency is in the ignore list\n", .{ ec.red, ec.reset }) catch {};
    } else {
        err_writer.print("{s}error:{s} dependency resolution failed: {}\n", .{ ec.red, ec.reset, err }) catch {};
    }
    return .general_error;
}

pub fn printError(err: anytype, err_writer: std.io.AnyWriter, ec: color.Style) !void {
    switch (err) {
        error.NetworkError => try err_writer.print("{s}error:{s} failed to connect to AUR\n", .{ ec.red, ec.reset }),
        error.RateLimited => try err_writer.print("{s}error:{s} AUR rate limit exceeded. Wait and retry.\n", .{ ec.red, ec.reset }),
        error.ApiError => try err_writer.print("{s}error:{s} AUR returned an error\n", .{ ec.red, ec.reset }),
        error.MalformedResponse => try err_writer.print("{s}error:{s} received malformed response from AUR\n", .{ ec.red, ec.reset }),
        else => try err_writer.print("{s}error:{s} {}\n", .{ ec.red, ec.reset, err }),
    }
}

pub fn defaultErrWriter() std.io.AnyWriter {
    const f: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    return f.deprecatedWriter().any();
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

// ── Tests ────────────────────────────────────────────────────────────

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

test "handleResolveError returns general_error for CircularDependency" {
    const result = handleResolveError(error.CircularDependency, std.io.null_writer.any(), color.Style.disabled);
    try testing.expectEqual(ExitCode.general_error, result);
}

test "handleResolveError returns general_error for UnresolvableDependency" {
    const result = handleResolveError(error.UnresolvableDependency, std.io.null_writer.any(), color.Style.disabled);
    try testing.expectEqual(ExitCode.general_error, result);
}

test "handleResolveError returns general_error for other errors" {
    const result = handleResolveError(error.OutOfMemory, std.io.null_writer.any(), color.Style.disabled);
    try testing.expectEqual(ExitCode.general_error, result);
}
