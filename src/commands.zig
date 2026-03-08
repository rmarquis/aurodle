const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("aur.zig");
const registry_mod = @import("registry.zig");
const solver_mod = @import("solver.zig");
const repo_mod = @import("repo.zig");
const pacman_mod = @import("pacman.zig");

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

pub const ReviewDecision = enum {
    proceed,
    skip,
    abort,
};

pub const FailedBuild = struct {
    pkgbase: []const u8,
    exit_code: u32,
    log_path: []const u8,
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

pub fn displayPlan(plan: solver_mod.BuildPlan, pm: ?*pacman_mod.Pacman) void {
    const stdout = getStdout();

    stdout.writeAll("resolving dependencies...\n") catch {};

    // Check if any AUR package has an old version (upgrade scenario)
    var has_old_version = false;
    if (pm) |p| {
        for (plan.build_order) |entry| {
            if (p.installedVersion(entry.name) != null) {
                has_old_version = true;
                break;
            }
        }
    }

    // AUR section
    if (plan.build_order.len > 0) {
        stdout.writeByte('\n') catch {};
        if (has_old_version) {
            stdout.print("AUR Package ({d})  Old Version  New Version\n", .{plan.build_order.len}) catch {};
        } else {
            stdout.print("AUR Package ({d})  New Version\n", .{plan.build_order.len}) catch {};
        }
        stdout.writeByte('\n') catch {};

        for (plan.build_order) |entry| {
            if (has_old_version) {
                const old_ver = if (pm) |p| p.installedVersion(entry.name) orelse "-" else "-";
                stdout.print("{s}  {s}  {s}\n", .{ entry.name, old_ver, entry.version }) catch {};
            } else {
                stdout.print("{s}  {s}\n", .{ entry.name, entry.version }) catch {};
            }
        }
    }

    // Repo deps section
    if (plan.repo_deps.len > 0) {
        stdout.writeByte('\n') catch {};
        stdout.print("Package ({d})  New Version\n", .{plan.repo_deps.len}) catch {};
        stdout.writeByte('\n') catch {};

        for (plan.repo_deps) |dep| {
            const repo = if (pm) |p| p.syncDbFor(dep) else null;
            const ver = if (pm) |p| p.syncVersion(dep) orelse "?" else "?";
            if (repo) |r| {
                stdout.print("{s}/{s}  {s}\n", .{ r, dep, ver }) catch {};
            } else {
                stdout.print("{s}  {s}\n", .{ dep, ver }) catch {};
            }
        }
    }

    stdout.writeByte('\n') catch {};
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
