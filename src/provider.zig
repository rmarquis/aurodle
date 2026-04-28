const color = @import("color.zig");

pub const ProviderCandidate = struct {
    name: []const u8,
    version: []const u8,
    db_name: []const u8, // repo name or "aur"
};

pub const ProviderChooserFn = *const fn (
    dep_name: []const u8,
    candidates: []const ProviderCandidate,
    stderr_color: color.Style,
) ?usize;

pub const ProviderSelection = struct {
    dep_name: []const u8,
    chosen: []const u8,
};
