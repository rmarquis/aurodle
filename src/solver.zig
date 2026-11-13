const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("aur.zig");
const registry_mod = @import("registry.zig");
const graph_mod = @import("solver/graph.zig");
const topo_mod = @import("solver/topo.zig");
const conflicts_mod = @import("solver/conflicts.zig");
const plan_mod = @import("plan.zig");
const version_mod = @import("version.zig");

const NodeMeta = graph_mod.NodeMeta;
const DepGraph = graph_mod.DepGraph;

// ── Public Types (re-exported from plan.zig) ─────────────────────────────

pub const BuildEntry = plan_mod.BuildEntry;
pub const DependencyEntry = plan_mod.DependencyEntry;
pub const Conflict = plan_mod.Conflict;
pub const StaleRepoDep = plan_mod.StaleRepoDep;
pub const SolverOptions = plan_mod.SolverOptions;
pub const BuildPlan = plan_mod.BuildPlan;
pub const Unresolved = plan_mod.Unresolved;

// ── Production Type Alias ────────────────────────────────────────────────

pub const Solver = SolverImpl(registry_mod.PackageRegistry);

// ── Generic Solver Implementation ────────────────────────────────────────

pub fn SolverImpl(comptime RegistryT: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        registry: *RegistryT,
        graph: DepGraph,
        targets: std.StringHashMapUnmanaged(void),
        options: SolverOptions,
        /// Set when resolve() fails with error.UnresolvableDependency.
        unresolved: ?Unresolved = null,
        /// Dep string → name of the first package that required it.
        required_by: std.StringHashMapUnmanaged([]const u8) = .empty,
        /// Every versioned dep seen during discovery, checked after it.
        constraints: std.ArrayListUnmanaged(ConstraintEdge) = .empty,

        const ConstraintEdge = struct { dep: []const u8, parent: []const u8 };

        /// Rounds of "upgrade nodes that fail a constraint, then discover
        /// their new deps". Normally one; the cap stops contradictory
        /// constraints (foo>=2 and foo<2) from flipping a node forever.
        const max_constraint_rounds = 8;

        pub fn init(allocator: Allocator, reg: *RegistryT, options: SolverOptions) Self {
            return .{
                .allocator = allocator,
                .registry = reg,
                .options = options,
                .graph = DepGraph.init(allocator),
                .targets = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.graph.deinit();
            self.targets.deinit(self.allocator);
            self.required_by.deinit(self.allocator);
            self.constraints.deinit(self.allocator);
        }

        /// Resolve a set of target packages into a BuildPlan.
        /// Pipeline: discovery → conflict detection → topological sort → plan assembly.
        pub fn resolve(self: *Self, target_names: []const []const u8) !BuildPlan {
            // Record targets
            for (target_names) |name| {
                try self.targets.put(self.allocator, name, {});
            }

            // Phase 1: Discovery — BFS with batched AUR resolution
            try self.discover(target_names);

            // Phase 1.5: Conflict detection — check conflicts metadata
            const conflicts = try conflicts_mod.detectConflicts(
                @TypeOf(self.registry.pacman.*),
                self.allocator,
                &self.graph,
                self.registry.pacman,
            );

            // Phase 2: Reject cycles among the pkgbases to build
            try topo_mod.checkBuildCycles(self.allocator, &self.graph);

            // Phase 3: Plan assembly — ordering, pkgbase dedup, classification
            var plan = try self.assemblePlan(target_names);
            plan.conflicts = conflicts;
            plan.stale_repo_deps = try self.findStaleRepoDeps(plan.all_deps);

            // Populate provider selections from registry (if available)
            if (comptime @hasField(RegistryT, "provider_selections")) {
                const selections = self.registry.provider_selections.items;
                if (selections.len > 0) {
                    plan.provider_selections = try self.allocator.dupe(registry_mod.ProviderSelection, selections);
                }
            }

            return plan;
        }

        // ── Phase 1: Discovery (BFS with batched AUR resolution) ────────

        fn discover(self: *Self, target_names: []const []const u8) !void {
            var visited = std.StringHashMapUnmanaged(void){};
            defer visited.deinit(self.allocator);

            var frontier: std.ArrayListUnmanaged([]const u8) = .empty;
            defer frontier.deinit(self.allocator);
            try frontier.appendSlice(self.allocator, target_names);
            try self.expand(&visited, &frontier);

            // Versioned deps: a name is resolved once, by whichever edge
            // reached it first, so a later "foo>=2" may find foo 1.0 in the
            // graph. Upgrade such nodes, discover what they pull in, repeat.
            var round: usize = 0;
            while (round < max_constraint_rounds) : (round += 1) {
                if (!try self.upgradeUnsatisfied(&visited, &frontier)) break;
                try self.expand(&visited, &frontier);
            }
            try self.checkConstraints();
        }

        /// Breadth-first discovery from the dep strings in `frontier`
        /// (consumed), one batched registry lookup per level.
        fn expand(
            self: *Self,
            visited: *std.StringHashMapUnmanaged(void),
            frontier: *std.ArrayListUnmanaged([]const u8),
        ) !void {
            while (frontier.items.len > 0) {
                const resolutions = try self.registry.resolveMany(frontier.items);
                defer self.allocator.free(resolutions);

                var next_frontier: std.ArrayListUnmanaged([]const u8) = .empty;

                errdefer next_frontier.deinit(self.allocator);

                try self.prefetchAurTargets(frontier.items, resolutions, visited);

                for (frontier.items, resolutions) |dep, resolution| {
                    const name = registry_mod.parseDep(dep).name;
                    if (visited.contains(name)) continue;

                    const redirected = try self.resolveWithRedirects(dep, name, resolution, visited) orelse continue;
                    const actual_name = redirected.name;
                    const actual_resolution = redirected.resolution;

                    try visited.put(self.allocator, actual_name, {});

                    if (!self.targets.contains(actual_name) and self.isIgnoredPkg(actual_name)) {
                        return error.IgnoredDependency;
                    }

                    // Register alias so edges using the original name resolve correctly.
                    // Must be after all redirect paths.
                    if (!std.mem.eql(u8, actual_name, name)) {
                        try self.graph.addAlias(name, actual_name);
                        try visited.put(self.allocator, name, {});
                    }

                    const node = try self.graph.addNode(actual_name, .{
                        .source = actual_resolution.source,
                        .version = actual_resolution.version,
                        .pkgbase = if (actual_resolution.aur_pkg) |p| p.pkgbase else null,
                        .aur_pkg = actual_resolution.aur_pkg,
                    });

                    const aur_pkg = try self.fetchAndReclassifyAurPkg(node, actual_name, name, actual_resolution);

                    // Follow deps by how the package is obtained. Built: its
                    // AUR depends and makedepends. Installed from the local
                    // repository, including an installed target that is
                    // reinstalled from it: its depends there, which must be
                    // available too (an AUR one missing from the repository
                    // is built first). Already installed: nothing.
                    const reinstalled = node.meta.source == .satisfied_aur and self.targets.contains(actual_name);
                    if (node.meta.source == .repo_aur or reinstalled) {
                        const deps = try self.registry.localRepoDepends(actual_name);
                        try self.collectDeps(&next_frontier, visited, node, deps);
                    } else if (node.meta.source == .aur) {
                        if (aur_pkg) |pkg| try self.collectAllDeps(&next_frontier, visited, node, pkg);
                    }
                }

                frontier.deinit(self.allocator);
                frontier.* = next_frontier;
            }
        }

        // ── Phase 1b: Version constraints ───────────────────────────────

        /// For each versioned dep whose node fails it, ask the registry for a
        /// package that satisfies it (e.g. a newer sync or AUR version of an
        /// installed package) and update the node. Deps of a node that became
        /// an AUR build are queued in `frontier`. Returns true if any node
        /// changed.
        fn upgradeUnsatisfied(
            self: *Self,
            visited: *std.StringHashMapUnmanaged(void),
            frontier: *std.ArrayListUnmanaged([]const u8),
        ) !bool {
            var changed = false;
            for (self.constraints.items) |edge| {
                const node = self.constrainedNode(edge.dep) orelse continue;
                if (self.nodeSatisfies(node, edge.dep)) continue;

                const res = try self.registry.resolve(edge.dep);
                // Only accept an exact-name match that meets the constraint;
                // anything else is reported by checkConstraints.
                if (res.source == .unknown) continue;
                if (res.provider) |p| if (!std.mem.eql(u8, p, node.meta.name)) continue;
                const ver = res.version orelse continue;
                const constraint = registry_mod.parseDep(edge.dep).constraint.?;
                if (!versionSatisfies(ver, constraint)) continue;

                node.meta.source = res.source;
                node.meta.version = ver;
                if (res.aur_pkg) |pkg| {
                    node.meta.aur_pkg = pkg;
                    node.meta.pkgbase = pkg.pkgbase;
                    if (res.source == .aur) {
                        try self.collectAllDeps(frontier, visited, node, pkg);
                    }
                }
                changed = true;
            }
            return changed;
        }

        /// Fail with error.UnresolvableDependency (and set `unresolved`) if
        /// any versioned dep is still not met by its node.
        fn checkConstraints(self: *Self) !void {
            for (self.constraints.items) |edge| {
                const node = self.constrainedNode(edge.dep) orelse continue;
                if (self.nodeSatisfies(node, edge.dep)) continue;
                self.unresolved = .{
                    .dep = edge.dep,
                    .required_by = edge.parent,
                    .found_version = node.meta.version,
                };
                return error.UnresolvableDependency;
            }
        }

        /// The graph node a versioned dep must satisfy, or null when it can't
        /// be checked: the name was resolved through a provider (aliases;
        /// provision versions are not tracked) or never reached the graph.
        fn constrainedNode(self: *Self, dep: []const u8) ?*DepGraph.Node {
            const name = registry_mod.parseDep(dep).name;
            const node = self.graph.nodes.getPtr(name) orelse return null;
            if (node.meta.version == null) return null;
            return node;
        }

        fn nodeSatisfies(self: *Self, node: *const DepGraph.Node, dep: []const u8) bool {
            _ = self;
            const constraint = registry_mod.parseDep(dep).constraint orelse return true;
            return versionSatisfies(node.meta.version.?, constraint);
        }

        fn versionSatisfies(ver: []const u8, constraint: version_mod.VersionConstraint) bool {
            const cmp = RegistryT.vercmp(ver, constraint.version);
            return switch (constraint.op) {
                .eq => cmp == 0,
                .ge => cmp >= 0,
                .le => cmp <= 0,
                .gt => cmp > 0,
                .lt => cmp < 0,
            };
        }

        /// Prefetch full AUR metadata for frontier targets that were resolved locally
        /// (installed/sync) but still need dependency info. One batched multiInfo call
        /// replaces N individual info() calls.
        fn prefetchAurTargets(
            self: *Self,
            names: []const []const u8,
            resolutions: []const registry_mod.Resolution,
            visited: *const std.StringHashMapUnmanaged(void),
        ) !void {
            var prefetch: std.ArrayListUnmanaged([]const u8) = .empty;
            defer prefetch.deinit(self.allocator);
            for (names, resolutions) |name, res| {
                if (res.aur_pkg == null and self.targets.contains(name) and !visited.contains(name)) {
                    try prefetch.append(self.allocator, name);
                }
            }
            try self.registry.prefetchAur(prefetch.items);
        }

        const Redirected = struct {
            name: []const u8,
            resolution: registry_mod.Resolution,
        };

        /// Resolve provider redirects and unknown-source cascade for a frontier item.
        /// Returns null when the item should be skipped (already visited after redirect).
        fn resolveWithRedirects(
            self: *Self,
            dep: []const u8,
            name: []const u8,
            resolution: registry_mod.Resolution,
            visited: *const std.StringHashMapUnmanaged(void),
        ) !?Redirected {
            var actual_name = name;
            var actual_resolution = resolution;

            // Handle provider redirect (e.g. "auracle" → "auracle-git")
            if (resolution.provider) |provider_name| {
                if (!std.mem.eql(u8, provider_name, name)) {
                    if (self.targets.contains(name)) {
                        // For explicit targets, prefer the AUR package by exact name over a
                        // provider redirect. E.g. "pacaur" should build pacaur from AUR, not
                        // redirect to installed pacaur-git.
                        if (try self.registry.resolveFromAur(name)) |aur_res| {
                            if (aur_res.provider == null) {
                                actual_resolution = aur_res;
                            } else {
                                // AUR only knows this name via a provider — accept the redirect.
                                try self.targets.put(self.allocator, provider_name, {});
                                actual_name = provider_name;
                            }
                        } else {
                            // Target doesn't exist in AUR — accept the provider redirect.
                            try self.targets.put(self.allocator, provider_name, {});
                            actual_name = provider_name;
                        }
                    } else {
                        actual_name = provider_name;
                    }
                    if (!std.mem.eql(u8, actual_name, name)) {
                        if (visited.contains(actual_name)) return null;
                        actual_resolution = try self.registry.resolve(actual_name);
                    }
                }
            }

            // Resolve unknown via full cascade. Keep the dep's constraint
            // unless a provider redirect changed the name.
            if (actual_resolution.source == .unknown) {
                const query = if (std.mem.eql(u8, actual_name, name)) dep else actual_name;
                const full_res = try self.registry.resolve(query);
                if (full_res.source == .unknown) {
                    self.unresolved = .{
                        .dep = query,
                        .required_by = self.required_by.get(dep),
                        .found_version = full_res.version,
                    };
                    return error.UnresolvableDependency;
                }
                actual_resolution = full_res;
                // The full cascade may have found an AUR provider (e.g. "auracle" → "auracle-git").
                if (full_res.provider) |prov| {
                    if (!std.mem.eql(u8, prov, actual_name)) {
                        // An explicit target satisfied only by a provider:
                        // the provider is what gets built and installed.
                        if (self.targets.contains(actual_name)) {
                            try self.targets.put(self.allocator, prov, {});
                        }
                        actual_name = prov;
                        if (visited.contains(actual_name)) return null;
                    }
                }
            }

            return Redirected{ .name = actual_name, .resolution = actual_resolution };
        }

        /// Fetch full AUR package info for a node if needed, update its metadata,
        /// and reclassify repo_aur/satisfied_aur targets that require (re)building.
        /// Returns the best available aur_pkg pointer for dependency traversal.
        fn fetchAndReclassifyAurPkg(
            self: *Self,
            node: *DepGraph.Node,
            actual_name: []const u8,
            original_name: []const u8,
            actual_resolution: registry_mod.Resolution,
        ) !?*aur.Package {
            var aur_pkg = actual_resolution.aur_pkg;

            // Fetch full AUR metadata for targets and provider-redirected AUR packages.
            // Provider/search resolutions may return an aur_pkg with empty dep arrays
            // (the AUR search endpoint omits dependency fields).
            const is_redirect = !std.mem.eql(u8, actual_name, original_name);
            const is_aur_source = switch (actual_resolution.source) {
                .aur, .repo_aur, .satisfied_aur => true,
                else => false,
            };
            if (self.targets.contains(actual_name) or (is_redirect and is_aur_source)) {
                if (try self.registry.resolveFromAur(actual_name)) |aur_res| {
                    aur_pkg = aur_res.aur_pkg;
                }
            }

            if (aur_pkg) |pkg| {
                if (node.meta.pkgbase == null) node.meta.pkgbase = pkg.pkgbase;
                // Always store aur_pkg for conflict/provides detection even if source stays non-AUR.
                if (node.meta.aur_pkg == null) node.meta.aur_pkg = pkg;
            }

            // Reclassify repo_aur/satisfied_aur targets that need (re)building.
            // Outside the aur_pkg block: VCS packages must be reclassified even when AUR
            // metadata is unavailable (package only in local aurpkgs repo, not yet on AUR).
            if ((node.meta.source == .repo_aur or node.meta.source == .satisfied_aur) and self.targets.contains(actual_name)) {
                const dominated = if (aur_pkg) |pkg|
                    if (node.meta.version) |local_ver| RegistryT.vercmp(pkg.version, local_ver) > 0 else false
                else
                    false;
                const is_vcs = RegistryT.isVcsPackage(actual_name);
                if (dominated or is_vcs or (self.options.rebuild and !self.options.needed)) {
                    node.meta.source = .aur;
                    if (aur_pkg) |pkg| node.meta.version = pkg.version;
                }
            }

            return aur_pkg;
        }

        /// Collect dependencies: add edges and queue unseen names for next frontier.
        fn collectDeps(
            self: *Self,
            next_frontier: *std.ArrayListUnmanaged([]const u8),
            visited: *const std.StringHashMapUnmanaged(void),
            parent_node: *DepGraph.Node,
            deps: []const []const u8,
        ) !void {
            for (deps) |dep| {
                const spec = registry_mod.parseDep(dep);
                try parent_node.edges.put(self.allocator, spec.name, {});

                const gop = try self.required_by.getOrPut(self.allocator, dep);
                if (!gop.found_existing) gop.value_ptr.* = parent_node.meta.name;
                if (spec.constraint != null) {
                    try self.constraints.append(self.allocator, .{ .dep = dep, .parent = parent_node.meta.name });
                }

                // Queue the full dep string so the registry sees the constraint.
                if (!visited.contains(spec.name)) {
                    try next_frontier.append(self.allocator, dep);
                }
            }
        }

        fn collectAllDeps(
            self: *Self,
            next_frontier: *std.ArrayListUnmanaged([]const u8),
            visited: *const std.StringHashMapUnmanaged(void),
            node: *DepGraph.Node,
            pkg: *aur.Package,
        ) !void {
            try self.collectDeps(next_frontier, visited, node, pkg.depends);
            try self.collectDeps(next_frontier, visited, node, pkg.makedepends);
            try self.collectDeps(next_frontier, visited, node, pkg.checkdepends);
        }

        fn isIgnoredPkg(self: *Self, name: []const u8) bool {
            for (self.options.ignore) |ignored| {
                if (std.mem.eql(u8, ignored, name)) return true;
            }
            return false;
        }

        /// Dependencies taken from the local repository that the AUR has a
        /// newer version of, checked in one batched AUR request. Targets
        /// were already compared during discovery; VCS packages are skipped,
        /// since their AUR version is only the last pkgver pushed. The check
        /// is informational, so an unreachable AUR just skips it.
        fn findStaleRepoDeps(self: *Self, all_deps: []const DependencyEntry) ![]StaleRepoDep {
            const alloc = self.allocator;
            var names: std.ArrayListUnmanaged([]const u8) = .empty;
            defer names.deinit(alloc);
            for (all_deps) |dep| {
                if (dep.source != .repo_aur or dep.is_target) continue;
                if (RegistryT.isVcsPackage(dep.name)) continue;
                try names.append(alloc, dep.name);
            }
            if (names.items.len == 0) return &.{};

            self.registry.prefetchAur(names.items) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return &.{},
            };

            var stale: std.ArrayListUnmanaged(StaleRepoDep) = .empty;
            errdefer stale.deinit(alloc);
            for (names.items) |name| {
                const local = self.graph.getNode(name).?.meta.version orelse continue;
                const aur_version = (self.registry.aurVersion(name) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => null,
                }) orelse continue;
                if (RegistryT.vercmp(aur_version, local) <= 0) continue;
                try stale.append(alloc, .{ .name = name, .local_version = local, .aur_version = aur_version });
            }
            return stale.toOwnedSlice(alloc);
        }

        // ── Phase 3: Plan Assembly ───────────────────────────────────────

        fn assemblePlan(self: *Self, target_names: []const []const u8) !BuildPlan {
            const alloc = self.allocator;
            var build_order: std.ArrayListUnmanaged(BuildEntry) = .empty;
            var all_deps: std.ArrayListUnmanaged(DependencyEntry) = .empty;
            var repo_deps: std.ArrayListUnmanaged([]const u8) = .empty;

            // Dependency-first order over the whole graph, with the packages
            // of each pkgbase to build kept together after all their deps.
            const all_order = try topo_mod.postOrder(alloc, &self.graph, target_names);
            defer alloc.free(all_order);

            // Track seen pkgbases for deduplication (maps to build_order index)
            var seen_pkgbase = std.StringHashMapUnmanaged(usize){};
            defer seen_pkgbase.deinit(alloc);

            // Temporary per-entry collectors: target names, and the pkgbases
            // of the AUR deps of every package in the pkgbase.
            var target_lists: std.ArrayListUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
            defer target_lists.deinit(alloc);
            var dep_base_sets: std.ArrayListUnmanaged(std.StringArrayHashMapUnmanaged(void)) = .empty;
            defer {
                for (dep_base_sets.items) |*set| set.deinit(alloc);
                dep_base_sets.deinit(alloc);
            }

            // Build order: packages that get built, deduplicated by pkgbase
            for (all_order) |name| {
                const node = self.graph.getNode(name).?;
                if (node.meta.source != .aur) continue;
                const pkgbase = node.meta.pkgbase orelse name;
                const is_target = self.targets.contains(name);

                const idx = if (seen_pkgbase.get(pkgbase)) |idx| idx else blk: {
                    const idx = build_order.items.len;
                    try seen_pkgbase.put(alloc, pkgbase, idx);
                    try target_lists.append(alloc, .empty);
                    try dep_base_sets.append(alloc, .empty);
                    try build_order.append(alloc, .{
                        .name = name,
                        .pkgbase = pkgbase,
                        .version = node.meta.version orelse "unknown",
                        .is_target = false,
                        .out_of_date = if (node.meta.aur_pkg) |pkg| pkg.out_of_date else null,
                    });
                    break :blk idx;
                };

                if (is_target) {
                    try target_lists.items[idx].append(alloc, name);
                    build_order.items[idx].is_target = true;
                }
                for (node.edges.keys()) |dep_name| {
                    const dep_node = self.graph.getNode(dep_name) orelse continue;
                    if (dep_node.meta.source != .aur) continue;
                    const dep_pkgbase = dep_node.meta.pkgbase orelse dep_name;
                    if (std.mem.eql(u8, dep_pkgbase, pkgbase)) continue;
                    try dep_base_sets.items[idx].put(alloc, dep_pkgbase, {});
                }
            }

            // Finalize per-entry slices
            for (build_order.items, 0..) |*entry, i| {
                entry.target_names = try target_lists.items[i].toOwnedSlice(alloc);
                entry.aur_dep_bases = try alloc.dupe([]const u8, dep_base_sets.items[i].keys());
            }

            // Single pass: collect all deps + classify repo deps/targets.
            var repo_targets: std.ArrayListUnmanaged([]const u8) = .empty;
            for (all_order) |name| {
                const node = self.graph.getNode(name).?;
                const is_target = self.targets.contains(node.meta.name);
                try all_deps.append(alloc, .{
                    .name = node.meta.name,
                    .pkgbase = node.meta.pkgbase,
                    .source = node.meta.source,
                    .is_target = is_target,
                });
                if (is_target and (node.meta.source == .repos or node.meta.source == .satisfied_repos)) {
                    try repo_targets.append(alloc, node.meta.name);
                } else if (node.meta.source == .repos) {
                    try repo_deps.append(alloc, node.meta.name);
                }
            }

            const repo_deps_slice = try repo_deps.toOwnedSlice(alloc);
            errdefer alloc.free(repo_deps_slice);

            return .{
                .build_order = try build_order.toOwnedSlice(alloc),
                .all_deps = try all_deps.toOwnedSlice(alloc),
                .repo_deps = repo_deps_slice,
                .repo_targets = try repo_targets.toOwnedSlice(alloc),
            };
        }
    };
}
