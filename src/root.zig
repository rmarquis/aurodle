const std = @import("std");

pub const utils = @import("utils.zig");
pub const aur = @import("aur.zig");
pub const commands = @import("commands.zig");
pub const git = @import("git.zig");
pub const repo = @import("repo.zig");
pub const alpm = @import("alpm.zig");
pub const pacman = @import("pacman.zig");
pub const registry = @import("registry.zig");
pub const solver = @import("solver.zig");

test {
    std.testing.refAllDecls(@This());
}
