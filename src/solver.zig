const std = @import("std");
const Allocator = std.mem.Allocator;
const registry_mod = @import("registry.zig");
const aur = @import("aur.zig");
const alpm = @import("alpm.zig");

// ── Public Types ─────────────────────────────────────────────────────────

pub const BuildEntry = struct {
    name: []const u8,
    pkgbase: []const u8,
    version: []const u8,
    is_target: bool,
};

pub const DependencyEntry = struct {
    name: []const u8,
    pkgbase: ?[]const u8,
    source: registry_mod.Source,
    is_target: bool,
    depth: u32,
};

pub const BuildPlan = struct {
    build_order: []BuildEntry,
    all_deps: []DependencyEntry,
    repo_deps: [][]const u8,
    repo_targets: [][]const u8,

    pub fn deinit(self: BuildPlan, allocator: Allocator) void {
        allocator.free(self.build_order);
        allocator.free(self.all_deps);
        allocator.free(self.repo_deps);
        allocator.free(self.repo_targets);
    }
};

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
        rebuild: bool = false,

        pub fn init(allocator: Allocator, reg: *RegistryT) Self {
            return .{
                .allocator = allocator,
                .registry = reg,
                .graph = DepGraph.init(allocator),
                .targets = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.graph.deinit();
            self.targets.deinit(self.allocator);
        }

        /// Resolve a set of target packages into a BuildPlan.
        /// Three-phase pipeline: discovery → topological sort → plan assembly.
        pub fn resolve(self: *Self, target_names: []const []const u8) !BuildPlan {
            // Record targets
            for (target_names) |name| {
                try self.targets.put(self.allocator, name, {});
            }

            // Phase 1: Discovery — BFS with batched AUR resolution
            try self.discover(target_names);

            // Phase 2: Topological sort — Kahn's algorithm on AUR nodes
            const order = try self.topoSort();
            defer self.allocator.free(order);

            // Phase 3: Plan assembly — pkgbase dedup + classification
            return self.assemblePlan(order);
        }

        // ── Phase 1: Discovery (BFS with batched AUR resolution) ────────

        fn discover(self: *Self, target_names: []const []const u8) !void {
            var visited = std.StringHashMapUnmanaged(void){};
            defer visited.deinit(self.allocator);

            // Build initial frontier from targets
            var frontier: std.ArrayListUnmanaged([]const u8) = .empty;
            defer frontier.deinit(self.allocator);
            for (target_names) |name| {
                try frontier.append(self.allocator, name);
            }

            var depth: u32 = 0;

            while (frontier.items.len > 0) {
                // Batch resolve current frontier
                const resolutions = try self.registry.resolveMany(frontier.items);
                defer self.allocator.free(resolutions);

                var next_frontier: std.ArrayListUnmanaged([]const u8) = .empty;

                // Prefetch AUR metadata for targets resolved locally that
                // still need dependency info. One batched multiInfo call
                // replaces N individual info() calls.
                {
                    var prefetch: std.ArrayListUnmanaged([]const u8) = .empty;
                    defer prefetch.deinit(self.allocator);
                    for (frontier.items, resolutions) |name, res| {
                        if (res.aur_pkg == null and self.targets.contains(name) and !visited.contains(name)) {
                            try prefetch.append(self.allocator, name);
                        }
                    }
                    try self.registry.prefetchAur(prefetch.items);
                }

                for (frontier.items, resolutions) |name, resolution| {
                    // Skip if already fully processed (diamond deps)
                    if (visited.contains(name)) {
                        if (self.graph.getNode(name)) |node| {
                            if (depth > node.meta.depth) node.meta.depth = depth;
                        }
                        continue;
                    }

                    var actual_name = name;
                    var actual_resolution = resolution;

                    // Handle provider redirect (e.g. "auracle" → "auracle-git")
                    if (resolution.provider) |provider_name| {
                        if (!std.mem.eql(u8, provider_name, name)) {
                            if (self.targets.contains(name)) {
                                try self.targets.put(self.allocator, provider_name, {});
                            }
                            actual_name = provider_name;
                            if (visited.contains(provider_name)) {
                                if (self.graph.getNode(provider_name)) |node| {
                                    if (depth > node.meta.depth) node.meta.depth = depth;
                                }
                                continue;
                            }
                            // Resolve the provider individually (typically cached or local)
                            actual_resolution = try self.registry.resolve(provider_name);
                        }
                    }

                    try visited.put(self.allocator, actual_name, {});

                    // Resolve unknown via full cascade before adding to graph
                    if (actual_resolution.source == .unknown) {
                        const full_res = try self.registry.resolve(actual_name);
                        if (full_res.source == .unknown) {
                            return error.UnresolvableDependency;
                        }
                        actual_resolution = full_res;
                    }

                    // Add node to graph
                    const node = try self.graph.addNode(actual_name, .{
                        .source = actual_resolution.source,
                        .version = actual_resolution.version,
                        .pkgbase = if (actual_resolution.aur_pkg) |p| p.pkgbase else null,
                        .aur_pkg = actual_resolution.aur_pkg,
                        .depth = depth,
                    });

                    // Determine AUR package info for dependency traversal.
                    // For targets that are satisfied/in repos, fetch from AUR
                    // so we can resolve their build dependencies.
                    var aur_pkg = actual_resolution.aur_pkg;
                    if (aur_pkg == null and self.targets.contains(actual_name)) {
                        if (try self.registry.resolveFromAur(actual_name)) |aur_res| {
                            aur_pkg = aur_res.aur_pkg;
                        }
                    }

                    // Update node metadata if we fetched AUR info after initial creation
                    if (aur_pkg) |pkg| {
                        if (node.meta.pkgbase == null) {
                            node.meta.pkgbase = pkg.pkgbase;
                        }
                        if ((node.meta.source == .repo_aur or node.meta.source == .satisfied_aur) and self.targets.contains(actual_name)) {
                            const dominated = if (node.meta.version) |local_ver|
                                alpm.vercmp(pkg.version, local_ver) > 0
                            else
                                false;
                            if (dominated or self.rebuild) {
                                node.meta.source = .aur;
                                node.meta.version = pkg.version;
                                node.meta.aur_pkg = pkg;
                            }
                        }
                    }

                    // Collect deps for next frontier
                    if (aur_pkg) |pkg| {
                        try self.collectDeps(&next_frontier, &visited, node, pkg.depends, depth);
                        try self.collectDeps(&next_frontier, &visited, node, pkg.makedepends, depth);
                    }
                }

                // Swap frontiers
                frontier.deinit(self.allocator);
                frontier = next_frontier;
                depth += 1;
            }
        }

        /// Collect dependencies: add edges and queue unseen names for next frontier.
        fn collectDeps(
            self: *Self,
            next_frontier: *std.ArrayListUnmanaged([]const u8),
            visited: *const std.StringHashMapUnmanaged(void),
            parent_node: *DepGraph.Node,
            deps: []const []const u8,
            depth: u32,
        ) !void {
            for (deps) |dep| {
                const dep_name = registry_mod.parseDep(dep).name;
                try parent_node.edges.put(self.allocator, dep_name, {});
                if (!visited.contains(dep_name)) {
                    try next_frontier.append(self.allocator, dep_name);
                } else {
                    // Update depth for already-visited nodes (diamond deps)
                    if (self.graph.getNode(dep_name)) |dep_node| {
                        if (depth + 1 > dep_node.meta.depth) dep_node.meta.depth = depth + 1;
                    }
                }
            }
        }

        // ── Phase 2: Topological Sort (Kahn's Algorithm) ────────────────

        fn topoSort(self: *Self) ![][]const u8 {
            const alloc = self.allocator;

            // Collect AUR node names
            var aur_nodes: std.ArrayListUnmanaged([]const u8) = .empty;
            defer aur_nodes.deinit(alloc);

            var graph_it = self.graph.nodes.iterator();
            while (graph_it.next()) |entry| {
                if (entry.value_ptr.meta.source == .aur) {
                    try aur_nodes.append(alloc, entry.key_ptr.*);
                }
            }

            if (aur_nodes.items.len == 0) {
                return alloc.alloc([]const u8, 0);
            }

            // Build reverse edges (dependency → dependents) and in-degrees.
            // Forward edges point dependent → dependency; we invert them
            // so Kahn's BFS can efficiently find who to unblock.
            var in_degree = std.StringHashMapUnmanaged(u32){};
            defer in_degree.deinit(alloc);
            var reverse = std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)){};
            defer {
                var it = reverse.valueIterator();
                while (it.next()) |list| list.deinit(alloc);
                reverse.deinit(alloc);
            }

            for (aur_nodes.items) |name| {
                try in_degree.put(alloc, name, 0);
                try reverse.put(alloc, name, .empty);
            }

            for (aur_nodes.items) |src_name| {
                const node = self.graph.getNode(src_name).?;
                for (node.edges.keys()) |dep_name| {
                    if (reverse.getPtr(dep_name)) |dependents| {
                        try dependents.append(alloc, src_name);
                        in_degree.getPtr(src_name).?.* += 1;
                    }
                }
            }

            // Seed with zero in-degree nodes, then BFS: the queue doubles
            // as the result since every dequeued node is in topological order.
            var order: std.ArrayListUnmanaged([]const u8) = .empty;

            for (aur_nodes.items) |name| {
                if (in_degree.get(name).? == 0) {
                    try order.append(alloc, name);
                }
            }

            var head: usize = 0;
            while (head < order.items.len) {
                const current = order.items[head];
                head += 1;

                for (reverse.get(current).?.items) |dependent| {
                    const deg = in_degree.getPtr(dependent).?;
                    deg.* -= 1;
                    if (deg.* == 0) {
                        try order.append(alloc, dependent);
                    }
                }
            }

            // Cycle detection
            if (order.items.len != aur_nodes.items.len) {
                return error.CircularDependency;
            }

            return try order.toOwnedSlice(alloc);
        }

        // ── Phase 3: Plan Assembly ───────────────────────────────────────

        fn assemblePlan(self: *Self, order: []const []const u8) !BuildPlan {
            const alloc = self.allocator;
            var build_order: std.ArrayListUnmanaged(BuildEntry) = .empty;
            var all_deps: std.ArrayListUnmanaged(DependencyEntry) = .empty;
            var repo_deps: std.ArrayListUnmanaged([]const u8) = .empty;

            // Track seen pkgbases for deduplication
            var seen_pkgbase = std.StringHashMapUnmanaged(void){};
            defer seen_pkgbase.deinit(alloc);

            // Build order: AUR packages, deduplicated by pkgbase
            for (order) |name| {
                const node = self.graph.getNode(name).?;
                const pkgbase = node.meta.pkgbase orelse name;

                if (!seen_pkgbase.contains(pkgbase)) {
                    try seen_pkgbase.put(alloc, pkgbase, {});
                    try build_order.append(alloc, .{
                        .name = name,
                        .pkgbase = pkgbase,
                        .version = node.meta.version orelse "unknown",
                        .is_target = self.targets.contains(name),
                    });
                }
            }

            // Single pass: collect all deps + classify repo deps/targets
            var repo_targets: std.ArrayListUnmanaged([]const u8) = .empty;
            var node_it = self.graph.nodes.iterator();
            while (node_it.next()) |entry| {
                const node = entry.value_ptr;
                const is_target = self.targets.contains(node.meta.name);
                try all_deps.append(alloc, .{
                    .name = node.meta.name,
                    .pkgbase = node.meta.pkgbase,
                    .source = node.meta.source,
                    .is_target = is_target,
                    .depth = node.meta.depth,
                });
                if (is_target and (node.meta.source == .repos or node.meta.source == .satisfied_repos)) {
                    try repo_targets.append(alloc, node.meta.name);
                } else if (node.meta.source == .repos) {
                    try repo_deps.append(alloc, node.meta.name);
                }
            }

            return .{
                .build_order = try build_order.toOwnedSlice(alloc),
                .all_deps = try all_deps.toOwnedSlice(alloc),
                .repo_deps = try repo_deps.toOwnedSlice(alloc),
                .repo_targets = try repo_targets.toOwnedSlice(alloc),
            };
        }
    };
}

// ── DepGraph ─────────────────────────────────────────────────────────────

const NodeMeta = struct {
    name: []const u8 = "",
    source: registry_mod.Source = .unknown,
    version: ?[]const u8 = null,
    pkgbase: ?[]const u8 = null,
    aur_pkg: ?*aur.Package = null,
    depth: u32 = 0,
};

const DepGraph = struct {
    nodes: std.StringHashMapUnmanaged(Node),
    allocator: Allocator,

    const Node = struct {
        meta: NodeMeta,
        /// Outgoing edges: packages this node depends on.
        edges: std.StringArrayHashMapUnmanaged(void),
    };

    fn init(allocator: Allocator) DepGraph {
        return .{
            .nodes = .empty,
            .allocator = allocator,
        };
    }

    fn deinit(self: *DepGraph) void {
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.edges.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
    }

    fn addNode(self: *DepGraph, name: []const u8, meta: NodeMeta) !*Node {
        const result = try self.nodes.getOrPut(self.allocator, name);
        if (!result.found_existing) {
            var m = meta;
            m.name = name;
            result.value_ptr.* = .{
                .meta = m,
                .edges = .empty,
            };
        }
        return result.value_ptr;
    }

    fn getNode(self: *DepGraph, name: []const u8) ?*Node {
        return self.nodes.getPtr(name);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

// ── Mock Registry ────────────────────────────────────────────────────────

const MockRegistry = struct {
    packages: std.StringHashMapUnmanaged(MockPackageInfo),
    aur_overrides: std.StringHashMapUnmanaged(MockPackageInfo),
    arena: std.heap.ArenaAllocator,

    const MockPackageInfo = struct {
        source: registry_mod.Source,
        version: []const u8,
        pkgbase: []const u8,
        depends: []const []const u8,
        makedepends: []const []const u8,
        aur_pkg: ?*aur.Package,
        provider: ?[]const u8 = null,
    };

    fn initEmpty() MockRegistry {
        return .{
            .packages = .empty,
            .aur_overrides = .empty,
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }

    fn deinitMock(self: *MockRegistry) void {
        self.packages.deinit(testing.allocator);
        self.aur_overrides.deinit(testing.allocator);
        self.arena.deinit();
    }

    fn addAurPackage(self: *MockRegistry, name: []const u8, depends: []const []const u8, makedepends: []const []const u8) void {
        self.addAurPackageWithBase(name, name, depends, makedepends);
    }

    fn addAurPackageWithBase(self: *MockRegistry, name: []const u8, pkgbase: []const u8, depends: []const []const u8, makedepends: []const []const u8) void {
        const alloc = self.arena.allocator();
        const pkg = alloc.create(aur.Package) catch unreachable;
        pkg.* = .{
            .id = 0,
            .name = name,
            .pkgbase = pkgbase,
            .pkgbase_id = 0,
            .version = "1.0-1",
            .description = null,
            .url = null,
            .url_path = null,
            .maintainer = null,
            .submitter = null,
            .votes = 0,
            .popularity = 0,
            .first_submitted = 0,
            .last_modified = 0,
            .out_of_date = null,
            .depends = depends,
            .makedepends = makedepends,
            .checkdepends = &.{},
            .optdepends = &.{},
            .provides = &.{},
            .conflicts = &.{},
            .replaces = &.{},
            .groups = &.{},
            .keywords = &.{},
            .licenses = &.{},
            .comaintainers = &.{},
        };
        self.packages.put(testing.allocator, name, .{
            .source = .aur,
            .version = "1.0-1",
            .pkgbase = pkgbase,
            .depends = depends,
            .makedepends = makedepends,
            .aur_pkg = pkg,
        }) catch unreachable;
    }

    /// Register a package as installed locally, but also available in AUR
    /// with dependency info. Simulates `resolve` → .satisfied_aur, `resolveFromAur` → .aur with deps.
    fn addSatisfiedWithAurDeps(self: *MockRegistry, name: []const u8, version: []const u8, depends: []const []const u8, makedepends: []const []const u8) void {
        // Primary entry: satisfied_aur (no aur_pkg)
        self.packages.put(testing.allocator, name, .{
            .source = .satisfied_aur,
            .version = version,
            .pkgbase = name,
            .depends = &.{},
            .makedepends = &.{},
            .aur_pkg = null,
        }) catch unreachable;

        // AUR override with dependency info
        const alloc = self.arena.allocator();
        const pkg = alloc.create(aur.Package) catch unreachable;
        pkg.* = .{
            .id = 0,
            .name = name,
            .pkgbase = name,
            .pkgbase_id = 0,
            .version = version,
            .description = null,
            .url = null,
            .url_path = null,
            .maintainer = null,
            .submitter = null,
            .votes = 0,
            .popularity = 0,
            .first_submitted = 0,
            .last_modified = 0,
            .out_of_date = null,
            .depends = depends,
            .makedepends = makedepends,
            .checkdepends = &.{},
            .optdepends = &.{},
            .provides = &.{},
            .conflicts = &.{},
            .replaces = &.{},
            .groups = &.{},
            .keywords = &.{},
            .licenses = &.{},
            .comaintainers = &.{},
        };
        self.aur_overrides.put(testing.allocator, name, .{
            .source = .aur,
            .version = version,
            .pkgbase = name,
            .depends = depends,
            .makedepends = makedepends,
            .aur_pkg = pkg,
        }) catch unreachable;
    }

    fn addRepoPackage(self: *MockRegistry, name: []const u8, version: []const u8) void {
        self.packages.put(testing.allocator, name, .{
            .source = .repos,
            .version = version,
            .pkgbase = name,
            .depends = &.{},
            .makedepends = &.{},
            .aur_pkg = null,
        }) catch unreachable;
    }

    /// Package available in aurpkgs but not installed (no AUR override).
    fn addRepoAur(self: *MockRegistry, name: []const u8, version: []const u8) void {
        self.packages.put(testing.allocator, name, .{
            .source = .repo_aur,
            .version = version,
            .pkgbase = name,
            .depends = &.{},
            .makedepends = &.{},
            .aur_pkg = null,
        }) catch unreachable;
    }

    /// Package in aurpkgs with a different (newer) version available in AUR.
    fn addRepoAurWithAurVersion(self: *MockRegistry, name: []const u8, local_version: []const u8, aur_version: []const u8, depends: []const []const u8, makedepends: []const []const u8) void {
        self.packages.put(testing.allocator, name, .{
            .source = .repo_aur,
            .version = local_version,
            .pkgbase = name,
            .depends = &.{},
            .makedepends = &.{},
            .aur_pkg = null,
        }) catch unreachable;

        const alloc = self.arena.allocator();
        const pkg = alloc.create(aur.Package) catch unreachable;
        pkg.* = .{
            .id = 0,
            .name = name,
            .pkgbase = name,
            .pkgbase_id = 0,
            .version = aur_version,
            .description = null,
            .url = null,
            .url_path = null,
            .maintainer = null,
            .submitter = null,
            .votes = 0,
            .popularity = 0,
            .first_submitted = 0,
            .last_modified = 0,
            .out_of_date = null,
            .depends = depends,
            .makedepends = makedepends,
            .checkdepends = &.{},
            .optdepends = &.{},
            .provides = &.{},
            .conflicts = &.{},
            .replaces = &.{},
            .groups = &.{},
            .keywords = &.{},
            .licenses = &.{},
            .comaintainers = &.{},
        };
        self.aur_overrides.put(testing.allocator, name, .{
            .source = .aur,
            .version = aur_version,
            .pkgbase = name,
            .depends = depends,
            .makedepends = makedepends,
            .aur_pkg = pkg,
        }) catch unreachable;
    }

    fn addSatisfied(self: *MockRegistry, name: []const u8, version: []const u8) void {
        self.packages.put(testing.allocator, name, .{
            .source = .satisfied_aur,
            .version = version,
            .pkgbase = name,
            .depends = &.{},
            .makedepends = &.{},
            .aur_pkg = null,
        }) catch unreachable;
    }

    fn addSatisfiedRepo(self: *MockRegistry, name: []const u8, version: []const u8) void {
        self.packages.put(testing.allocator, name, .{
            .source = .satisfied_repos,
            .version = version,
            .pkgbase = name,
            .depends = &.{},
            .makedepends = &.{},
            .aur_pkg = null,
        }) catch unreachable;
    }

    /// Register a virtual name that redirects to a provider package.
    /// Simulates "auracle" → "auracle-git" via provider resolution.
    fn addProvider(self: *MockRegistry, virtual_name: []const u8, provider_name: []const u8, source: registry_mod.Source, version: []const u8) void {
        self.packages.put(testing.allocator, virtual_name, .{
            .source = source,
            .version = version,
            .pkgbase = provider_name,
            .depends = &.{},
            .makedepends = &.{},
            .aur_pkg = null,
            .provider = provider_name,
        }) catch unreachable;
    }

    // ── Interface matching PackageRegistry ────────────────────────────

    pub fn prefetchAur(_: *MockRegistry, _: []const []const u8) !void {}

    pub fn resolveMany(self: *MockRegistry, dep_strings: []const []const u8) ![]registry_mod.Resolution {
        var results: std.ArrayListUnmanaged(registry_mod.Resolution) = .empty;
        errdefer results.deinit(testing.allocator);
        try results.ensureTotalCapacity(testing.allocator, dep_strings.len);
        for (dep_strings) |dep_str| {
            results.appendAssumeCapacity(try self.resolve(dep_str));
        }
        return try results.toOwnedSlice(testing.allocator);
    }

    pub fn resolve(self: *MockRegistry, dep_string: []const u8) !registry_mod.Resolution {
        const spec = registry_mod.parseDep(dep_string);
        const info = self.packages.get(spec.name) orelse {
            return .{ .name = spec.name, .source = .unknown };
        };
        return .{
            .name = spec.name,
            .source = info.source,
            .version = info.version,
            .aur_pkg = info.aur_pkg,
            .provider = info.provider,
        };
    }

    pub fn resolveFromAur(self: *MockRegistry, name: []const u8) !?registry_mod.Resolution {
        // Check AUR-specific entries first (for packages registered with addAurPackage)
        if (self.aur_overrides.get(name)) |aur_info| {
            return .{
                .name = name,
                .source = .aur,
                .version = aur_info.version,
                .aur_pkg = aur_info.aur_pkg,
            };
        }
        // Fall back to primary entry if it has AUR data
        const info = self.packages.get(name) orelse return null;
        if (info.aur_pkg == null) return null;
        return .{
            .name = name,
            .source = .aur,
            .version = info.version,
            .aur_pkg = info.aur_pkg,
        };
    }
};

const TestSolver = SolverImpl(MockRegistry);

// ── Lifecycle Tests ──────────────────────────────────────────────────────

test "Solver.init accepts allocator and registry reference" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();
}

// ── resolve() Core Tests ─────────────────────────────────────────────────

test "resolve returns BuildPlan for a single target with no dependencies" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("pkg", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"pkg"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expect(plan.build_order[0].is_target);
    try testing.expectEqualStrings("pkg", plan.build_order[0].name);
    try testing.expectEqual(@as(usize, 0), plan.repo_deps.len);
}

test "resolve orders dependencies before dependents" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("A", &.{"B"}, &.{});
    mock.addAurPackage("B", &.{"C"}, &.{});
    mock.addAurPackage("C", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"A"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), plan.build_order.len);
    try testing.expectEqualStrings("C", plan.build_order[0].name);
    try testing.expectEqualStrings("B", plan.build_order[1].name);
    try testing.expectEqualStrings("A", plan.build_order[2].name);
}

test "resolve classifies repo dependencies separately" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("A", &.{"repo-pkg"}, &.{});
    mock.addRepoPackage("repo-pkg", "1.0");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"A"});
    defer plan.deinit(testing.allocator);

    // repo-pkg in repo_deps, not build_order
    try testing.expectEqual(@as(usize, 1), plan.repo_deps.len);
    try testing.expectEqualStrings("repo-pkg", plan.repo_deps[0]);

    for (plan.build_order) |entry| {
        try testing.expect(!std.mem.eql(u8, entry.name, "repo-pkg"));
    }
}

test "resolve skips satisfied dependencies" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("A", &.{"installed-pkg"}, &.{});
    mock.addSatisfied("installed-pkg", "2.0");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"A"});
    defer plan.deinit(testing.allocator);

    // installed-pkg should not be in build_order or repo_deps
    for (plan.build_order) |entry| {
        try testing.expect(!std.mem.eql(u8, entry.name, "installed-pkg"));
    }
    try testing.expectEqual(@as(usize, 0), plan.repo_deps.len);

    // But it should be in all_deps
    var found = false;
    for (plan.all_deps) |dep| {
        if (std.mem.eql(u8, dep.name, "installed-pkg")) {
            try testing.expectEqual(registry_mod.Source.satisfied_aur, dep.source);
            found = true;
        }
    }
    try testing.expect(found);
}

test "resolve classifies repo targets separately from repo deps" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // expac is installed from official repos — target
    mock.addSatisfiedRepo("expac", "10.4");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"expac"});
    defer plan.deinit(testing.allocator);

    // Should be in repo_targets, not repo_deps or build_order
    try testing.expectEqual(@as(usize, 0), plan.build_order.len);
    try testing.expectEqual(@as(usize, 0), plan.repo_deps.len);
    try testing.expectEqual(@as(usize, 1), plan.repo_targets.len);
    try testing.expectEqualStrings("expac", plan.repo_targets[0]);
}

test "resolve classifies uninstalled repo targets into repo_targets" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // expac is in official repos but not installed — target
    mock.addRepoPackage("expac", "10.4");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"expac"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), plan.build_order.len);
    try testing.expectEqual(@as(usize, 0), plan.repo_deps.len);
    try testing.expectEqual(@as(usize, 1), plan.repo_targets.len);
    try testing.expectEqualStrings("expac", plan.repo_targets[0]);
}

test "resolve separates repo targets from repo deps in mixed plan" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // AUR target depends on repo dep; user also targets a repo package
    mock.addAurPackage("aurpkg", &.{"zlib"}, &.{});
    mock.addRepoPackage("zlib", "1.3");
    mock.addSatisfiedRepo("expac", "10.4");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{ "aurpkg", "expac" });
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expectEqual(@as(usize, 1), plan.repo_deps.len);
    try testing.expectEqualStrings("zlib", plan.repo_deps[0]);
    try testing.expectEqual(@as(usize, 1), plan.repo_targets.len);
    try testing.expectEqualStrings("expac", plan.repo_targets[0]);
}

test "resolve does not recurse into repo dependencies" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // foo (AUR) depends on zlib (repos)
    // If solver tried to recurse into zlib, it would look for zlib's deps
    // which don't exist in mock → would error. But it shouldn't recurse.
    mock.addAurPackage("foo", &.{"zlib"}, &.{});
    mock.addRepoPackage("zlib", "1.3.1");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"foo"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expectEqualStrings("foo", plan.build_order[0].name);
}

test "resolve marks target packages with is_target=true" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("target-a", &.{"dep"}, &.{});
    mock.addAurPackage("target-b", &.{"dep"}, &.{});
    mock.addAurPackage("dep", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{ "target-a", "target-b" });
    defer plan.deinit(testing.allocator);

    for (plan.build_order) |entry| {
        if (std.mem.eql(u8, entry.name, "target-a") or
            std.mem.eql(u8, entry.name, "target-b"))
        {
            try testing.expect(entry.is_target);
        } else {
            try testing.expect(!entry.is_target);
        }
    }
}

// ── Error Tests ──────────────────────────────────────────────────────────

test "resolve returns CircularDependency error on cycles" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("A", &.{"B"}, &.{});
    mock.addAurPackage("B", &.{"A"}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    try testing.expectError(error.CircularDependency, s.resolve(&.{"A"}));
}

test "resolve returns UnresolvableDependency for unknown packages" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("A", &.{"unknown-pkg"}, &.{});
    // "unknown-pkg" not registered → resolves as .unknown

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    try testing.expectError(error.UnresolvableDependency, s.resolve(&.{"A"}));
}

// ── pkgbase Deduplication Tests ──────────────────────────────────────────

test "resolve deduplicates packages sharing the same pkgbase" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackageWithBase("sub-a", "parent", &.{}, &.{});
    mock.addAurPackageWithBase("sub-b", "parent", &.{}, &.{});
    mock.addAurPackage("foo", &.{ "sub-a", "sub-b" }, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"foo"});
    defer plan.deinit(testing.allocator);

    var parent_count: usize = 0;
    for (plan.build_order) |entry| {
        if (std.mem.eql(u8, entry.pkgbase, "parent")) parent_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), parent_count);
}

test "resolve populates pkgbase field from AUR metadata" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackageWithBase("pkg-name", "pkg-base", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"pkg-name"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expectEqualStrings("pkg-base", plan.build_order[0].pkgbase);
}

// ── BuildPlan Structure Tests ────────────────────────────────────────────

test "BuildPlan.build_order contains only AUR packages" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("aur-pkg", &.{"repo-pkg"}, &.{});
    mock.addRepoPackage("repo-pkg", "1.0");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"aur-pkg"});
    defer plan.deinit(testing.allocator);

    for (plan.build_order) |entry| {
        // Find this entry in all_deps to verify source
        for (plan.all_deps) |dep| {
            if (std.mem.eql(u8, dep.name, entry.name)) {
                try testing.expectEqual(registry_mod.Source.aur, dep.source);
            }
        }
    }
}

test "BuildPlan.all_deps contains every discovered dependency" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("target", &.{ "aur-dep", "repo-dep", "satisfied-dep" }, &.{});
    mock.addAurPackage("aur-dep", &.{}, &.{});
    mock.addRepoPackage("repo-dep", "1.0");
    mock.addSatisfied("satisfied-dep", "2.0");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"target"});
    defer plan.deinit(testing.allocator);

    // all_deps should have target + 3 deps = 4
    try testing.expectEqual(@as(usize, 4), plan.all_deps.len);
    try testing.expect(plan.all_deps.len >= plan.build_order.len);
}

test "DependencyEntry.depth reflects distance from targets" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("target", &.{"dep1"}, &.{});
    mock.addAurPackage("dep1", &.{"dep2"}, &.{});
    mock.addAurPackage("dep2", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"target"});
    defer plan.deinit(testing.allocator);

    for (plan.all_deps) |dep| {
        if (std.mem.eql(u8, dep.name, "target")) {
            try testing.expectEqual(@as(u32, 0), dep.depth);
        } else if (std.mem.eql(u8, dep.name, "dep1")) {
            try testing.expectEqual(@as(u32, 1), dep.depth);
        } else if (std.mem.eql(u8, dep.name, "dep2")) {
            try testing.expectEqual(@as(u32, 2), dep.depth);
        }
    }
}

// ── Multiple Target Tests ────────────────────────────────────────────────

test "resolve handles multiple targets with shared dependencies" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("A", &.{"C"}, &.{});
    mock.addAurPackage("B", &.{"C"}, &.{});
    mock.addAurPackage("C", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{ "A", "B" });
    defer plan.deinit(testing.allocator);

    // C appears once in build_order
    var c_count: usize = 0;
    for (plan.build_order) |entry| {
        if (std.mem.eql(u8, entry.name, "C")) c_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), c_count);

    // C must come before A and B
    var c_idx: ?usize = null;
    var a_idx: ?usize = null;
    var b_idx: ?usize = null;
    for (plan.build_order, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, "C")) c_idx = i;
        if (std.mem.eql(u8, entry.name, "A")) a_idx = i;
        if (std.mem.eql(u8, entry.name, "B")) b_idx = i;
    }
    try testing.expect(c_idx.? < a_idx.?);
    try testing.expect(c_idx.? < b_idx.?);
}

test "resolve handles diamond dependency patterns" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // A → B, A → C, B → D, C → D
    mock.addAurPackage("A", &.{ "B", "C" }, &.{});
    mock.addAurPackage("B", &.{"D"}, &.{});
    mock.addAurPackage("C", &.{"D"}, &.{});
    mock.addAurPackage("D", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"A"});
    defer plan.deinit(testing.allocator);

    // D must come before B and C, which must come before A
    var indices = std.StringHashMapUnmanaged(usize){};
    defer indices.deinit(testing.allocator);

    for (plan.build_order, 0..) |entry, i| {
        try indices.put(testing.allocator, entry.name, i);
    }

    try testing.expect(indices.get("D").? < indices.get("B").?);
    try testing.expect(indices.get("D").? < indices.get("C").?);
    try testing.expect(indices.get("B").? < indices.get("A").?);
    try testing.expect(indices.get("C").? < indices.get("A").?);
}

test "resolve discovers deps of installed target via AUR fallback" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();

    // pacaur is installed but also in AUR with deps
    mock.addSatisfiedWithAurDeps("pacaur", "4.8.6-2", &.{ "auracle-git", "expac" }, &.{});
    mock.addAurPackage("auracle-git", &.{}, &.{});
    mock.addRepoPackage("expac", "10-3");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"pacaur"});
    defer plan.deinit(testing.allocator);

    // Should discover auracle-git (AUR dep) and expac (repo dep)
    try testing.expect(plan.all_deps.len >= 3); // pacaur + auracle-git + expac
    try testing.expectEqual(@as(usize, 1), plan.repo_deps.len);
    try testing.expectEqualStrings("expac", plan.repo_deps[0]);

    // auracle-git should be in build_order
    var found_auracle = false;
    for (plan.build_order) |entry| {
        if (std.mem.eql(u8, entry.name, "auracle-git")) found_auracle = true;
    }
    try testing.expect(found_auracle);
}

test "resolve handles makedepends in addition to depends" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("A", &.{"B"}, &.{"C"});
    mock.addAurPackage("B", &.{}, &.{});
    mock.addAurPackage("C", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"A"});
    defer plan.deinit(testing.allocator);

    // Both B and C must come before A
    var indices = std.StringHashMapUnmanaged(usize){};
    defer indices.deinit(testing.allocator);

    for (plan.build_order, 0..) |entry, i| {
        try indices.put(testing.allocator, entry.name, i);
    }

    try testing.expect(indices.get("B").? < indices.get("A").?);
    try testing.expect(indices.get("C").? < indices.get("A").?);
}

// ── repo_aur Version Check Tests ─────────────────────────────────────────

test "resolve reclassifies repo_aur target as aur when AUR version is newer" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // aurpkgs has 1.0, AUR has 2.0
    mock.addRepoAurWithAurVersion("pkg", "1.0-1", "2.0-1", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"pkg"});
    defer plan.deinit(testing.allocator);

    // Should be in build_order (reclassified to .aur)
    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expectEqualStrings("pkg", plan.build_order[0].name);

    // all_deps should show .aur source
    for (plan.all_deps) |dep| {
        if (std.mem.eql(u8, dep.name, "pkg")) {
            try testing.expectEqual(registry_mod.Source.aur, dep.source);
        }
    }
}

test "resolve keeps repo_aur target when aurpkgs version matches AUR" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // Same version in aurpkgs and AUR
    mock.addRepoAurWithAurVersion("pkg", "1.0-1", "1.0-1", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"pkg"});
    defer plan.deinit(testing.allocator);

    // Should NOT be in build_order (stays repo_aur)
    try testing.expectEqual(@as(usize, 0), plan.build_order.len);

    // all_deps should show .repo_aur source
    for (plan.all_deps) |dep| {
        if (std.mem.eql(u8, dep.name, "pkg")) {
            try testing.expectEqual(registry_mod.Source.repo_aur, dep.source);
        }
    }
}

test "rebuild reclassifies satisfied_aur target into build plan" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // pacaur is installed (satisfied_aur) with same version as AUR
    mock.addSatisfiedWithAurDeps("pacaur", "4.8.6-2", &.{"auracle-git"}, &.{});
    mock.addAurPackage("auracle-git", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    s.rebuild = true;
    defer s.deinit();

    const plan = try s.resolve(&.{"pacaur"});
    defer plan.deinit(testing.allocator);

    // pacaur should be in build_order despite being up-to-date
    var found_pacaur = false;
    for (plan.build_order) |entry| {
        if (std.mem.eql(u8, entry.name, "pacaur")) found_pacaur = true;
    }
    try testing.expect(found_pacaur);
}

test "resolve redirects virtual name to provider package" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // "auracle" is a virtual name provided by "auracle-git"
    mock.addProvider("auracle", "auracle-git", .satisfied_aur, "r427-1");
    mock.addSatisfiedWithAurDeps("auracle-git", "r427-1", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    s.rebuild = true;
    defer s.deinit();

    const plan = try s.resolve(&.{"auracle"});
    defer plan.deinit(testing.allocator);

    // Build plan should show "auracle-git", not "auracle"
    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expectEqualStrings("auracle-git", plan.build_order[0].name);
    try testing.expect(plan.build_order[0].is_target);
}

test "resolve does not version-check repo_aur dependencies" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("target", &.{"dep"}, &.{});
    // dep is in aurpkgs with old version, but it's not a target
    mock.addRepoAur("dep", "1.0-1");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"target"});
    defer plan.deinit(testing.allocator);

    // dep should stay repo_aur (no version check for non-targets)
    for (plan.all_deps) |d| {
        if (std.mem.eql(u8, d.name, "dep")) {
            try testing.expectEqual(registry_mod.Source.repo_aur, d.source);
        }
    }
}
