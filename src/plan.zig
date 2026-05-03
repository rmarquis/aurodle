const std = @import("std");
const Allocator = std.mem.Allocator;
const source_mod = @import("source.zig");
const provider_mod = @import("provider.zig");

pub const BuildEntry = struct {
    name: []const u8,
    pkgbase: []const u8,
    version: []const u8,
    is_target: bool,
    /// Names of user-requested targets that belong to this pkgbase.
    /// For split packages, multiple target names may share one build entry.
    target_names: []const []const u8 = &.{},
    /// Unix timestamp when flagged out-of-date on AUR, or null.
    out_of_date: ?i64 = null,
    /// Pkgbases of AUR dependencies (for build failure propagation and sync DB refresh).
    aur_dep_bases: []const []const u8 = &.{},
};

pub const DependencyEntry = struct {
    name: []const u8,
    pkgbase: ?[]const u8,
    source: source_mod.Source,
    is_target: bool,
    depth: u32,
};

pub const Conflict = struct {
    package: []const u8,
    conflicts_with: []const u8,
    kind: Kind,

    pub const Kind = enum {
        /// Two packages in the build plan conflict with each other.
        aur_aur,
        /// An AUR package conflicts with an already-installed package.
        aur_installed,
        /// A new repo dependency conflicts with an already-installed package.
        repo_installed,
        /// An AUR package replaces an already-installed package.
        aur_replaces,
        /// A new repo dependency replaces an already-installed package.
        repo_replaces,
    };
};

pub const BuildPlan = struct {
    build_order: []BuildEntry,
    all_deps: []DependencyEntry,
    /// Direct repo deps declared by AUR packages (used for installation).
    repo_deps: [][]const u8,
    repo_targets: [][]const u8,
    conflicts: []Conflict = &.{},
    provider_selections: []provider_mod.ProviderSelection = &.{},

    pub fn deinit(self: BuildPlan, allocator: Allocator) void {
        for (self.build_order) |entry| {
            allocator.free(entry.aur_dep_bases);
            allocator.free(entry.target_names);
        }
        allocator.free(self.build_order);
        allocator.free(self.all_deps);
        allocator.free(self.repo_deps);
        allocator.free(self.repo_targets);
        allocator.free(self.conflicts);
        allocator.free(self.provider_selections);
    }
};
