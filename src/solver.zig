const std = @import("std");
const Allocator = std.mem.Allocator;
const registry_mod = @import("registry.zig");
const aur = @import("aur.zig");

// ── Public Types ─────────────────────────────────────────────────────────

pub const DepType = enum {
    target,
    depends,
    makedepends,
};

pub const BuildEntry = struct {
    name: []const u8,
    pkgbase: []const u8,
    version: []const u8,
    is_target: bool,
};

pub const DependencyEntry = struct {
    name: []const u8,
    source: registry_mod.Source,
    is_target: bool,
    depth: u32,
};

pub const BuildPlan = struct {
    build_order: []BuildEntry,
    all_deps: []DependencyEntry,
    repo_deps: [][]const u8,

    pub fn deinit(self: BuildPlan, allocator: Allocator) void {
        allocator.free(self.build_order);
        allocator.free(self.all_deps);
        allocator.free(self.repo_deps);
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
        visiting: std.StringHashMapUnmanaged(void),

        pub fn init(allocator: Allocator, reg: *RegistryT) Self {
            return .{
                .allocator = allocator,
                .registry = reg,
                .graph = DepGraph.init(allocator),
                .targets = .empty,
                .visiting = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.graph.deinit();
            self.targets.deinit(self.allocator);
            self.visiting.deinit(self.allocator);
        }

        /// Resolve a set of target packages into a BuildPlan.
        /// Three-phase pipeline: discovery → topological sort → plan assembly.
        pub fn resolve(self: *Self, target_names: []const []const u8) !BuildPlan {
            // Record targets
            for (target_names) |name| {
                try self.targets.put(self.allocator, name, {});
            }

            // Phase 1: Discovery — recursive DFS with cycle detection
            for (target_names) |name| {
                try self.discover(name, 0);
            }

            // Phase 2: Topological sort — Kahn's algorithm on AUR nodes
            const order = try self.topoSort();
            defer self.allocator.free(order);

            // Phase 3: Plan assembly — pkgbase dedup + classification
            return self.assemblePlan(order);
        }

        // ── Phase 1: Discovery ───────────────────────────────────────────

        fn discover(self: *Self, name: []const u8, depth: u32) !void {
            // Cycle detection: on current DFS path?
            if (self.visiting.contains(name)) {
                return error.CircularDependency;
            }

            // Already fully processed?
            if (self.graph.getNode(name)) |node| {
                if (node.fully_resolved) return;
            }

            // Mark as visiting (gray)
            try self.visiting.put(self.allocator, name, {});
            defer _ = self.visiting.remove(name);

            // Classify via registry
            const resolution = try self.registry.resolve(name);

            const meta = NodeMeta{
                .source = resolution.source,
                .version = resolution.version,
                .pkgbase = if (resolution.aur_pkg) |p| p.pkgbase else null,
                .aur_pkg = resolution.aur_pkg,
                .depth = depth,
                .dep_type = if (self.targets.contains(name)) .target else .depends,
            };

            try self.graph.addNode(name, meta);

            // Fail fast on unknown
            if (resolution.source == .unknown) {
                return error.UnresolvableDependency;
            }

            // Determine AUR package info for recursion.
            // For AUR packages resolved directly, we already have it.
            // For targets or aurpkgs providers without aur_pkg, fetch from AUR.
            const aur_pkg: ?*aur.Package = if (resolution.aur_pkg) |pkg|
                pkg
            else if (self.targets.contains(name) or resolution.source == .aur)
                if (try self.registry.resolveFromAur(name)) |aur_res| aur_res.aur_pkg else null
            else
                null;

            // Recurse into dependencies if we have AUR package info.
            // For non-target deps, repo/satisfied packages are handled
            // transitively by pacman and won't have aur_pkg set.
            if (aur_pkg) |pkg| {
                // Follow depends
                for (pkg.depends) |dep| {
                    const dep_name = registry_mod.parseDep(dep).name;
                    try self.discover(dep_name, depth + 1);
                    try self.graph.addEdge(name, dep_name);
                }

                // Follow makedepends
                for (pkg.makedepends) |dep| {
                    const dep_name = registry_mod.parseDep(dep).name;
                    try self.discover(dep_name, depth + 1);
                    try self.graph.addEdge(name, dep_name);
                }
            }

            // Mark fully resolved (black)
            if (self.graph.getNode(name)) |node| {
                node.fully_resolved = true;
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

            // Compute in-degrees: for each AUR node, count how many AUR
            // dependencies it has. Our edges point dependent → dependency,
            // so in_degree[src] += 1 for each AUR dep in src's edge list.
            var in_degree = std.StringHashMapUnmanaged(u32){};
            defer in_degree.deinit(alloc);

            for (aur_nodes.items) |name| {
                try in_degree.put(alloc, name, 0);
            }

            for (aur_nodes.items) |src_name| {
                const node = self.graph.getNode(src_name).?;
                for (node.edges.keys()) |dep_name| {
                    if (in_degree.contains(dep_name)) {
                        if (in_degree.getPtr(src_name)) |deg| {
                            deg.* += 1;
                        }
                    }
                }
            }

            // Seed queue with zero in-degree nodes (no AUR prerequisites)
            var queue: std.ArrayListUnmanaged([]const u8) = .empty;
            defer queue.deinit(alloc);

            for (aur_nodes.items) |name| {
                if (in_degree.get(name).? == 0) {
                    try queue.append(alloc, name);
                }
            }

            var result: std.ArrayListUnmanaged([]const u8) = .empty;

            // BFS
            var head: usize = 0;
            while (head < queue.items.len) {
                const current = queue.items[head];
                head += 1;

                try result.append(alloc, current);

                // For each AUR node that depends on `current`, decrement in-degree
                for (aur_nodes.items) |name| {
                    if (std.mem.eql(u8, name, current)) continue;
                    const node = self.graph.getNode(name).?;
                    if (node.edges.contains(current)) {
                        const deg = in_degree.getPtr(name).?;
                        deg.* -= 1;
                        if (deg.* == 0) {
                            try queue.append(alloc, name);
                        }
                    }
                }
            }

            // Cycle detection
            if (result.items.len != aur_nodes.items.len) {
                return error.CircularDependency;
            }

            return try result.toOwnedSlice(alloc);
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

            // All deps: every node in the graph
            var node_it = self.graph.nodes.iterator();
            while (node_it.next()) |entry| {
                const node = entry.value_ptr;
                try all_deps.append(alloc, .{
                    .name = node.meta.name,
                    .source = node.meta.source,
                    .is_target = self.targets.contains(node.meta.name),
                    .depth = node.meta.depth,
                });
            }

            // Repo deps: packages from sync DBs
            var repo_it = self.graph.nodes.iterator();
            while (repo_it.next()) |entry| {
                if (entry.value_ptr.meta.source == .repos) {
                    try repo_deps.append(alloc, entry.value_ptr.meta.name);
                }
            }

            return .{
                .build_order = try build_order.toOwnedSlice(alloc),
                .all_deps = try all_deps.toOwnedSlice(alloc),
                .repo_deps = try repo_deps.toOwnedSlice(alloc),
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
    dep_type: DepType = .depends,
};

const DepGraph = struct {
    nodes: std.StringHashMapUnmanaged(Node),
    allocator: Allocator,

    const Node = struct {
        meta: NodeMeta,
        /// Outgoing edges: packages this node depends on.
        edges: std.StringArrayHashMapUnmanaged(void),
        fully_resolved: bool,
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

    fn addNode(self: *DepGraph, name: []const u8, meta: NodeMeta) !void {
        const result = try self.nodes.getOrPut(self.allocator, name);
        if (!result.found_existing) {
            var m = meta;
            m.name = name;
            result.value_ptr.* = .{
                .meta = m,
                .edges = .empty,
                .fully_resolved = false,
            };
        }
    }

    fn addEdge(self: *DepGraph, from: []const u8, to: []const u8) !void {
        if (self.nodes.getPtr(from)) |node| {
            try node.edges.put(self.allocator, to, {});
        }
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

    // ── Interface matching PackageRegistry ────────────────────────────

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
