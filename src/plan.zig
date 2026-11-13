const std = @import("std");
const Allocator = std.mem.Allocator;
const source_mod = @import("source.zig");
const provider_mod = @import("provider.zig");

/// Settings that change what a plan contains. The command layer derives
/// them from the command-line flags in one place (Flags.solverOptions),
/// so every command that shows or builds a plan agrees on its contents.
pub const SolverOptions = struct {
    /// Rebuild targets already built or installed at the AUR version.
    rebuild: bool = false,
    /// With `rebuild`, still skip targets that are up to date.
    needed: bool = false,
    /// Packages that must not be pulled in. Borrowed.
    ignore: []const []const u8 = &.{},
};

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

/// Why dependency resolution failed with error.UnresolvableDependency.
pub const Unresolved = struct {
    /// The dependency string that could not be satisfied (e.g. "foo>=2").
    dep: []const u8,
    /// Package that requires it; null for a user-requested target.
    required_by: ?[]const u8 = null,
    /// Version of the best candidate found, when one exists but is too old
    /// (or too new) for the constraint.
    found_version: ?[]const u8 = null,
};

/// The result of Solver.resolve.
///
/// Lifetimes: deinit frees the plan's own slices (build_order, all_deps,
/// the name lists and each entry's target_names/aur_dep_bases), not the
/// strings in them. Those are borrowed, never copied, from what the solver
/// read:
/// - the target names passed to resolve (argv);
/// - aur.Client's arena (AUR names, versions, pkgbases, dependency lists);
/// - libalpm memory through Pacman (repo package names, versions and
///   dependency lists), valid until Pacman.deinit.
/// The plan does not borrow from the solver itself, so it may outlive it,
/// but not the AUR client, the Pacman instance or argv.
pub const BuildPlan = struct {
    build_order: []BuildEntry,
    /// Every package in the graph (AUR, repo, installed), each after all
    /// of its dependencies; targets in the order given, each dependency
    /// chain just before the package that needs it.
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
