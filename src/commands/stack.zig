//! The modules the build, query and repository commands run on: the local
//! repository, libalpm, the package registry and privilege escalation.
//! Opening them reads makepkg.conf and pacman.conf, so a frontend opens a
//! Stack only for commands that need one, and after any pacman step that
//! changes the databases.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const aur = core.aur;
const auth_mod = core.auth;
const pacman_mod = core.pacman;
const registry_mod = core.registry;
const repo_mod = core.repo;
const ui = @import("ui");
const color = ui.color;
const output = ui.output;
const term = ui.term;
const types = @import("types.zig");
const BuildContext = @import("build_context.zig").BuildContext;

pub const Stack = struct {
    allocator: Allocator,
    io: std.Io,
    aur_client: *aur.Client,
    cache_root: []const u8,
    /// The caller's flags, with IgnorePkg from pacman.conf added to `ignore`.
    flags: types.Flags,
    repository: repo_mod.Repository,
    pacman: pacman_mod.Pacman,
    registry: registry_mod.PackageRegistry,
    auth: auth_mod.Auth,
    ignore: []const []const u8,
    stderr_style: color.Style,

    pub const InitError = error{
        /// Initialisation failed and the reason was printed to stderr.
        Reported,
        OutOfMemory,
    };

    /// Open the stack in place. The registry points at `pacman`, and the
    /// repository's reporter and the provider chooser at `stderr_style`,
    /// so a Stack must not move once opened. `aur_client` and `cache_root`
    /// must outlive it.
    pub fn init(
        self: *Stack,
        allocator: Allocator,
        io: std.Io,
        aur_client: *aur.Client,
        cache_root: []const u8,
        flags: types.Flags,
    ) InitError!void {
        self.allocator = allocator;
        self.io = io;
        self.aur_client = aur_client;
        self.cache_root = cache_root;

        // The local repository comes first: it derives the repository name
        // from pacman.conf and PKGDEST.
        self.repository = repo_mod.Repository.init(allocator, io, cache_root) catch |err| {
            if (err == error.PkgdestNotSet) {
                // Usually the first thing a new user hits: give the whole setup.
                std.debug.print("error: PKGDEST is not set in makepkg.conf\n", .{});
                std.debug.print("{s}\n", .{repo_mod.Repository.configInstructions()});
            } else if (err == error.RepoNotInPacmanConf) {
                std.debug.print("error: no pacman.conf repo has a Server = file:// matching PKGDEST\n", .{});
                std.debug.print("{s}\n", .{repo_mod.Repository.configInstructions()});
            } else {
                std.debug.print("error: failed to initialize repository: {}\n", .{err});
            }
            return error.Reported;
        };
        errdefer self.repository.deinit();

        self.pacman = pacman_mod.Pacman.init(allocator, self.repository.repo_name) catch |err| {
            std.debug.print("error: failed to initialize pacman: {}\n", .{err});
            return error.Reported;
        };
        errdefer self.pacman.deinit();

        self.ignore = try mergeIgnore(allocator, flags.ignore, self.pacman.ignore_pkgs);
        errdefer allocator.free(self.ignore);
        self.flags = flags;
        self.flags.ignore = self.ignore;

        // Cascade lookup: installed -> sync -> AUR -> provider.
        self.registry = registry_mod.PackageRegistry.init(allocator, &self.pacman, aur_client);
        errdefer self.registry.deinit();

        self.stderr_style = color.Style.detect(std.posix.STDERR_FILENO, self.pacman.color);
        self.repository.reporter = output.stderrReporter(&self.stderr_style);
        if (!flags.noconfirm) {
            self.registry.provider_chooser = term.providerChooser(&self.stderr_style);
        }
        // Chroot builds install AUR dependencies from the local repository,
        // so one installed on the host but missing from it must be built.
        self.registry.ignore_installed_aur = flags.chroot;

        // PACMAN_AUTH, then sudo, then su. Credentials are only acquired by
        // the build commands, once the plan is confirmed and reviewed.
        self.auth = auth_mod.Auth.init(allocator, self.repository.makepkg_conf.pacman_auth) catch |err| {
            if (err == error.NoAuthMethod) {
                std.debug.print("error: no privilege escalation method found (sudo/su not on PATH)\n", .{});
                std.debug.print("hint: set PACMAN_AUTH in makepkg.conf or install sudo/doas\n", .{});
            } else {
                std.debug.print("error: failed to initialize auth: {}\n", .{err});
            }
            return error.Reported;
        };
    }

    pub fn deinit(self: *Stack) void {
        self.auth.deinit();
        self.registry.deinit();
        self.allocator.free(self.ignore);
        self.pacman.deinit();
        self.repository.deinit();
        self.* = undefined;
    }

    /// The context the build and query commands take. It borrows the
    /// stack, which must outlive it.
    pub fn buildContext(self: *Stack) BuildContext {
        return BuildContext.init(
            self.allocator,
            self.io,
            self.aur_client,
            &self.pacman,
            &self.registry,
            &self.repository,
            &self.auth,
            self.cache_root,
            self.flags,
        );
    }
};

/// `cli` followed by the names in `conf` not already in it.
/// Caller frees the slice (the names are borrowed).
fn mergeIgnore(allocator: Allocator, cli: []const []const u8, conf: []const []const u8) ![]const []const u8 {
    var merged: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer merged.deinit(allocator);
    try merged.appendSlice(allocator, cli);
    next: for (conf) |pkg| {
        for (cli) |existing| {
            if (std.mem.eql(u8, existing, pkg)) continue :next;
        }
        try merged.append(allocator, pkg);
    }
    return merged.toOwnedSlice(allocator);
}

test "mergeIgnore appends pacman.conf names not given on the command line" {
    const merged = try mergeIgnore(std.testing.allocator, &.{ "a", "b" }, &.{ "b", "c" });
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqualStrings("a", merged[0]);
    try std.testing.expectEqualStrings("b", merged[1]);
    try std.testing.expectEqualStrings("c", merged[2]);
}
