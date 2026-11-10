const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("../aur.zig");
const pacman_mod = @import("../pacman.zig");
const registry_mod = @import("../registry.zig");
const repo_mod = @import("../repo.zig");
const auth_mod = @import("../auth.zig");
const color = @import("../color.zig");
const types = @import("types.zig");

pub const BuildContext = struct {
    allocator: Allocator,
    io: std.Io,
    aur_client: *aur.Client,
    pacman: *pacman_mod.Pacman,
    registry: *registry_mod.PackageRegistry,
    repository: *repo_mod.Repository,
    auth: *auth_mod.Auth,
    cache_root: []const u8,
    flags: types.Flags,
    stdout_color: color.Style,
    stderr_color: color.Style,
    err_writer: types.ErrWriter,
    /// Populated by --devel upgrade check; used by displayPlan to show real versions.
    devel_version_hint: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Populated alongside devel_version_hint, for packages whose version
    /// check left fully prepared sources in src/. Maps the package name to
    /// devel.sourceStamp() at that time; the build reuses the sources if
    /// the stamp still matches.
    devel_prepared: std.StringHashMapUnmanaged(i96) = .empty,

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        aur_client: *aur.Client,
        pm: *pacman_mod.Pacman,
        reg: *registry_mod.PackageRegistry,
        repository: *repo_mod.Repository,
        auth: *auth_mod.Auth,
        cache_root: []const u8,
        flags: types.Flags,
    ) BuildContext {
        const use_color = pm.color;
        return BuildContext{
            .allocator = allocator,
            .io = io,
            .aur_client = aur_client,
            .pacman = pm,
            .registry = reg,
            .repository = repository,
            .auth = auth,
            .cache_root = cache_root,
            .flags = flags,
            .stdout_color = color.Style.detect(std.posix.STDOUT_FILENO, use_color),
            .stderr_color = color.Style.detect(std.posix.STDERR_FILENO, use_color),
            .err_writer = types.defaultErrWriter(),
        };
    }
};

test {
    std.testing.refAllDecls(@This());
}
