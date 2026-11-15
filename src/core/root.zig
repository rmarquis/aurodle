//! The core: AUR, pacman, git, build and repository mechanics shared by the
//! frontends. Nothing here prints to the terminal or prompts the user;
//! messages go through `report.Reporter`.

const std = @import("std");

pub const alpm = @import("alpm.zig");
pub const aur = @import("aur.zig");
pub const auth = @import("auth.zig");
pub const chroot = @import("chroot.zig");
pub const dep_spec = @import("dep_spec.zig");
pub const devel = @import("devel.zig");
pub const git = @import("git.zig");
pub const makepkg = @import("makepkg.zig");
pub const pacman = @import("pacman.zig");
pub const pacman_conf = @import("pacman_conf.zig");
pub const plan = @import("plan.zig");
pub const provider = @import("provider.zig");
pub const registry = @import("registry.zig");
pub const repo = @import("repo.zig");
pub const repo_conf = @import("repo_conf.zig");
pub const report = @import("report.zig");
pub const solver = @import("solver.zig");
pub const source = @import("source.zig");
pub const utils = @import("utils.zig");
pub const version = @import("version.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("aur/tests.zig");
    _ = @import("git/tests.zig");
    _ = @import("pacman/tests.zig");
    _ = @import("registry/tests.zig");
    _ = @import("repo/tests.zig");
    _ = @import("solver/tests.zig");
}
