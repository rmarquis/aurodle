//! Terminal presentation shared by the frontends: colours, prompts, output
//! writers and the formatting of packages, plans and search results.

const std = @import("std");

pub const color = @import("color.zig");
pub const display = @import("display.zig");
pub const output = @import("output.zig");
pub const term = @import("term.zig");

test {
    std.testing.refAllDecls(@This());
}
