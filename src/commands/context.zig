const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("../aur.zig");
const registry_mod = @import("../registry.zig");
const repo_mod = @import("../repo.zig");
const pacman_mod = @import("../pacman.zig");
const utils = @import("../utils.zig");
const auth_mod = @import("../auth.zig");
const color = @import("../color.zig");

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
    asdeps: bool = false,
    asexplicit: bool = false,
    devel: bool = false,
    all: bool = false,
    recurse: bool = false,
    chroot: bool = false,
    by: ?aur.SearchField = null,
    sort: ?SortField = null,
    rsort: ?SortField = null,
    ignore: []const []const u8 = &.{},
    ignore_buf: [64][]const u8 = undefined,

    /// Re-anchor the ignore slice to point into our own ignore_buf.
    /// Must be called after any struct copy (Zig copies the slice pointer
    /// verbatim, leaving it pointing at the source struct's buffer).
    pub fn reanchorIgnore(self: *Flags) void {
        self.ignore = self.ignore_buf[0..self.ignore.len];
    }
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
    built_pkg_basenames: []const []const u8,

    pub fn deinit(self: BuildResult, allocator: Allocator) void {
        for (self.built_pkg_basenames) |b| allocator.free(b);
        allocator.free(self.built_pkg_basenames);
        allocator.free(self.succeeded);
        allocator.free(self.failed);
    }
};

pub const OutdatedEntry = struct {
    name: []const u8,
    installed_version: []const u8,
    aur_version: []const u8,
    ignored: bool = false,
};

/// Result of `outdated.collectOutdated`.  Shared by `outdated` and `upgrade`.
///
/// `entries` contains one row per package that's behind its AUR (or devel)
/// version; each carries the `ignored` flag so callers can decide whether to
/// display, filter, or warn.  `devel_versions` owns the strings produced by
/// the --devel pass (borrowed from by `entries[i].aur_version` for VCS-only
/// entries and by `devel_version_hint` when populated).  `total_checked` is
/// the number of installed foreign packages compared against the AUR —
/// zero means "nothing to compare" (distinct from "compared but none outdated").
pub const OutdatedList = struct {
    entries: []OutdatedEntry,
    devel_versions: [][]const u8,
    total_checked: usize,

    pub fn deinit(self: OutdatedList, allocator: Allocator) void {
        allocator.free(self.entries);
        for (self.devel_versions) |v| allocator.free(v);
        allocator.free(self.devel_versions);
    }
};

// ── Commands Struct ──────────────────────────────────────────────────

pub const Commands = struct {
    allocator: Allocator,
    aur_client: *aur.Client,
    pacman: ?*pacman_mod.Pacman,
    registry: ?*registry_mod.PackageRegistry,
    repo: ?*repo_mod.Repository,
    auth: ?*auth_mod.Auth,
    cache_root: ?[]const u8,
    flags: Flags,
    err_writer: std.io.AnyWriter,
    stdout_color: color.Style,
    stderr_color: color.Style,
    /// Populated by --devel upgrade check; used by displayPlan to show real versions.
    devel_version_hint: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(allocator: Allocator, aur_client: *aur.Client, flags: Flags) Commands {
        return .{
            .allocator = allocator,
            .aur_client = aur_client,
            .pacman = null,
            .registry = null,
            .repo = null,
            .auth = null,
            .cache_root = null,
            .flags = flags,
            .err_writer = defaultErrWriter(),
            .stdout_color = color.Style.detect(std.posix.STDOUT_FILENO, true),
            .stderr_color = color.Style.detect(std.posix.STDERR_FILENO, true),
        };
    }

    pub fn initFull(
        allocator: Allocator,
        aur_client: *aur.Client,
        pm: *pacman_mod.Pacman,
        reg: *registry_mod.PackageRegistry,
        repository: *repo_mod.Repository,
        auth: *auth_mod.Auth,
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
            .auth = auth,
            .cache_root = cache_root,
            .flags = flags,
            .err_writer = defaultErrWriter(),
            .stdout_color = color.Style.detect(std.posix.STDOUT_FILENO, use_color),
            .stderr_color = color.Style.detect(std.posix.STDERR_FILENO, use_color),
        };
    }

    /// Filter out ignored packages from a target list.
    /// Prompts the user for each ignored target (matching pacman behavior).
    /// Returns the filtered slice (backed by the provided buffer).
    pub fn filterIgnored(self: *Commands, targets: []const []const u8, buf: [][]const u8) []const []const u8 {
        if (self.flags.ignore.len == 0) return targets;

        const ec = self.stderr_color;
        var count: usize = 0;
        for (targets) |target| {
            if (self.isIgnored(target)) {
                var msg_buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "{s} is in IgnorePkg. Install anyway?", .{target}) catch target;
                const install = utils.promptYesNoStyled(self.stdout_color, msg) catch false;
                if (install) {
                    buf[count] = target;
                    count += 1;
                } else {
                    self.err_writer.print(
                        "{s}warning:{s} skipping target: {s}\n",
                        .{ ec.yellow, ec.reset, target },
                    ) catch {};
                }
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
};

// ── Shared Helpers (used by sub-modules) ─────────────────────────────

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

/// Module-level stderr DeprecatedWriter — lives at static address so the
/// AnyWriter returned by .any() holds a valid pointer for the entire
/// process lifetime.  (Constructing a DeprecatedWriter on the stack and
/// calling .any() returns a dangling pointer once the frame is gone.)
const stderr_writer_static: std.fs.File.DeprecatedWriter = blk: {
    const f: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    break :blk f.deprecatedWriter();
};

pub fn defaultErrWriter() std.io.AnyWriter {
    return stderr_writer_static.any();
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
