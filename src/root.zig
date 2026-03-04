const std = @import("std");

pub const utils = @import("utils.zig");
pub const aur = @import("aur.zig");
pub const commands = @import("commands.zig");

test {
    std.testing.refAllDecls(@This());
}
