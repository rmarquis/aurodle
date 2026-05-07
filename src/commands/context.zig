const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("../aur.zig");
const registry_mod = @import("../registry.zig");
const repo_mod = @import("../repo.zig");
const pacman_mod = @import("../pacman.zig");
const utils = @import("../utils.zig");
const auth_mod = @import("../auth.zig");
const color = @import("../color.zig");
const types = @import("types.zig");

pub const ExitCode = types.ExitCode;
pub const Flags = types.Flags;
pub const SortField = types.SortField;
pub const FailedBuild = types.FailedBuild;
pub const BuildResult = types.BuildResult;
pub const OutdatedEntry = types.OutdatedEntry;
pub const OutdatedList = types.OutdatedList;
pub const ErrWriter = types.ErrWriter;
pub const StdWriter = types.StdWriter;
pub const handleResolveError = types.handleResolveError;
pub const printError = types.printError;
pub const defaultErrWriter = types.defaultErrWriter;
pub const null_err_writer = types.null_err_writer;
pub const getStdout = types.getStdout;

// ── Commands Struct ──────────────────────────────────────────────────────

/// Monolithic context that holds all subsystem references.
/// TODO: split into QueryContext / BuildContext (see STRUCTURE_ANALYSIS_status6.md).
pub const Commands = struct {
    allocator: Allocator,
    aur_client: *aur.Client,
    pacman: ?*pacman_mod.Pacman,
    registry: ?*registry_mod.PackageRegistry,
    repo: ?*repo_mod.Repository,
    auth: ?*auth_mod.Auth,
    cache_root: ?[]const u8,
    flags: Flags,
    err_writer: ErrWriter,
    io: std.Io,
    stdout_color: color.Style,
    stderr_color: color.Style,
    /// Populated by --devel upgrade check; used by displayPlan to show real versions.
    devel_version_hint: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(allocator: Allocator, io: std.Io, aur_client: *aur.Client, flags: Flags) Commands {
        var c = Commands{
            .allocator = allocator,
            .aur_client = aur_client,
            .pacman = null,
            .registry = null,
            .repo = null,
            .auth = null,
            .cache_root = null,
            .flags = flags,
            .err_writer = defaultErrWriter(),
            .io = io,
            .stdout_color = color.Style.detect(std.posix.STDOUT_FILENO, true),
            .stderr_color = color.Style.detect(std.posix.STDERR_FILENO, true),
        };
        c.flags.reanchorIgnore();
        return c;
    }

    pub fn initFull(
        allocator: Allocator,
        io: std.Io,
        aur_client: *aur.Client,
        pm: *pacman_mod.Pacman,
        reg: *registry_mod.PackageRegistry,
        repository: *repo_mod.Repository,
        auth: *auth_mod.Auth,
        cache_root: []const u8,
        flags: Flags,
    ) Commands {
        const use_color = pm.color;
        var c = Commands{
            .allocator = allocator,
            .aur_client = aur_client,
            .pacman = pm,
            .registry = reg,
            .repo = repository,
            .auth = auth,
            .cache_root = cache_root,
            .flags = flags,
            .err_writer = defaultErrWriter(),
            .io = io,
            .stdout_color = color.Style.detect(std.posix.STDOUT_FILENO, use_color),
            .stderr_color = color.Style.detect(std.posix.STDERR_FILENO, use_color),
        };
        c.flags.reanchorIgnore();
        return c;
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

test {
    std.testing.refAllDecls(@This());
}
