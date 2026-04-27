const std = @import("std");
const ctx = @import("commands/context.zig");

// Re-export shared context: Commands struct, all types, display helpers, IO helpers.
pub const ExitCode = ctx.ExitCode;
pub const Flags = ctx.Flags;
pub const SortField = ctx.SortField;
pub const FailedBuild = ctx.FailedBuild;
pub const BuildResult = ctx.BuildResult;
pub const OutdatedEntry = ctx.OutdatedEntry;
pub const OutdatedList = ctx.OutdatedList;
pub const Commands = ctx.Commands;
pub const displayPlan = ctx.displayPlan;
pub const displayInstallList = ctx.displayInstallList;
pub const handleResolveError = ctx.handleResolveError;
pub const printError = ctx.printError;
pub const defaultErrWriter = ctx.defaultErrWriter;
pub const getStdout = ctx.getStdout;
pub const StdWriter = ctx.StdWriter;

// Sub-modules (pub for test discovery via refAllDecls and for main.zig routing)
pub const query = @import("commands/query.zig");
pub const build_cmd = @import("commands/build_cmd.zig");
pub const analysis = @import("commands/analysis.zig");
pub const status_cmd = @import("commands/status.zig");

test {
    std.testing.refAllDecls(@This());
}
