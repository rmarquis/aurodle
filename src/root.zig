const std = @import("std");

// Public API surface for external consumers (e.g. specification tests).
// Keep this minimal — internal code should import modules directly.
pub const alpm = @import("alpm.zig");
pub const devel = @import("devel.zig");

// Private imports kept alive so that `zig test` on this module still
// discovers tests in all source files.
const _utils = @import("utils.zig");
const _aur = @import("aur.zig");
const _commands = @import("commands.zig");
const _git = @import("git.zig");
const _repo = @import("repo.zig");
const _pacman = @import("pacman.zig");
const _registry = @import("registry.zig");
const _solver = @import("solver.zig");
const _color = @import("color.zig");
const _auth = @import("auth.zig");

test {
    std.testing.refAllDecls(@This());
    _ = _utils;
    _ = _aur;
    _ = _commands;
    _ = _git;
    _ = _repo;
    _ = _pacman;
    _ = _registry;
    _ = _solver;
    _ = _color;
    _ = _auth;
    _ = @import("aur/tests.zig");
    _ = @import("git/tests.zig");
    _ = @import("pacman/tests.zig");
    _ = @import("registry/tests.zig");
    _ = @import("repo/tests.zig");
    _ = @import("solver/tests.zig");
}
