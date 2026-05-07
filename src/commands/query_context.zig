const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("../aur.zig");
const pacman_mod = @import("../pacman.zig");
const registry_mod = @import("../registry.zig");
const color = @import("../color.zig");
const types = @import("types.zig");

/// Lightweight context for commands that only need the AUR client
/// (and optionally pacman for version display).
pub const QueryContext = struct {
    allocator: Allocator,
    io: std.Io,
    aur_client: *aur.Client,
    pacman: ?*pacman_mod.Pacman,
    registry: ?*registry_mod.PackageRegistry,
    cache_root: []const u8,
    flags: types.Flags,
    stdout_color: color.Style,
    stderr_color: color.Style,
    err_writer: types.ErrWriter,

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        aur_client: *aur.Client,
        cache_root: []const u8,
        flags: types.Flags,
    ) QueryContext {
        const stdout_color = color.Style.detect(std.posix.STDOUT_FILENO, true);
        const stderr_color = color.Style.detect(std.posix.STDERR_FILENO, true);
        var ctx = QueryContext{
            .allocator = allocator,
            .io = io,
            .aur_client = aur_client,
            .pacman = null,
            .registry = null,
            .cache_root = cache_root,
            .flags = flags,
            .stdout_color = stdout_color,
            .stderr_color = stderr_color,
            .err_writer = types.defaultErrWriter(),
        };
        ctx.flags.reanchorIgnore();
        return ctx;
    }
};

test {
    std.testing.refAllDecls(@This());
}
