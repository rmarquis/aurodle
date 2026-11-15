//! The AUR commands shared by the frontends: queries, builds, upgrades and
//! repository maintenance, with their prompts and output. Frontends parse
//! their own command line into `types.Flags` and call these.

const std = @import("std");

pub const analysis = @import("analysis.zig");
pub const build_cmd = @import("build_cmd.zig");
pub const build_context = @import("build_context.zig");
pub const query = @import("query.zig");
pub const query_context = @import("query_context.zig");
pub const stack = @import("stack.zig");
pub const status_cmd = @import("status.zig");
pub const types = @import("types.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("outdated.zig");
}
