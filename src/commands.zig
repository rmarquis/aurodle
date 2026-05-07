const std = @import("std");
const types = @import("commands/types.zig");
const display = @import("commands/display.zig");

// Re-export shared types and helpers.
pub const ExitCode = types.ExitCode;
pub const Flags = types.Flags;
pub const SortField = types.SortField;
pub const FailedBuild = types.FailedBuild;
pub const BuildResult = types.BuildResult;
pub const OutdatedEntry = types.OutdatedEntry;
pub const OutdatedList = types.OutdatedList;
pub const handleResolveError = types.handleResolveError;
pub const printError = types.printError;
pub const defaultErrWriter = types.defaultErrWriter;
pub const getStdout = types.getStdout;
pub const StdWriter = types.StdWriter;

// Context structs (replacing the monolithic Commands).
pub const QueryContext = @import("commands/query_context.zig").QueryContext;
pub const BuildContext = @import("commands/build_context.zig").BuildContext;

// Re-export display helpers.
pub const displayPlan = display.displayPlan;
pub const displayInstallList = display.displayInstallList;

// Sub-modules (pub for test discovery via refAllDecls and for main.zig routing)
pub const query = @import("commands/query.zig");
pub const build_cmd = @import("commands/build_cmd.zig");
pub const analysis = @import("commands/analysis.zig");
pub const status_cmd = @import("commands/status.zig");

test {
    std.testing.refAllDecls(@This());
}
