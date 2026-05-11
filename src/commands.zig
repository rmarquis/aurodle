const std = @import("std");

// Thin command router: re-exports sub-modules only.
// Types, contexts, and display helpers should be imported directly
// from their source files (commands/types.zig, commands/display.zig, etc.).

pub const query = @import("commands/query.zig");
pub const build_cmd = @import("commands/build_cmd.zig");
pub const analysis = @import("commands/analysis.zig");
pub const status_cmd = @import("commands/status.zig");

test {
    std.testing.refAllDecls(@This());
}
