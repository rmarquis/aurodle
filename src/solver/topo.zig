const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_mod = @import("graph.zig");
const DepGraph = graph_mod.DepGraph;

// A package that gets built (source .aur) is built with the rest of its
// pkgbase: makepkg builds the whole pkgbase at once, so the pkgbase needs
// the dependencies of every one of its packages. Ordering therefore works
// on build units: a pkgbase for built packages, the package itself for
// everything else (repo, local-repo and installed packages are leaves to
// the build).

fn isBuilt(node: *const DepGraph.Node) bool {
    return node.meta.source == .aur;
}

/// The pkgbase of a built package, null otherwise.
fn buildBase(node: *const DepGraph.Node) ?[]const u8 {
    if (!isBuilt(node)) return null;
    return node.meta.pkgbase orelse node.meta.name;
}

/// Built packages grouped by pkgbase, each group sorted by name so the
/// order does not depend on hash map iteration.
const Bases = struct {
    members: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty,

    fn init(allocator: Allocator, graph: *DepGraph) !Bases {
        var self: Bases = .{};
        errdefer self.deinit(allocator);
        var it = graph.nodes.valueIterator();
        while (it.next()) |node| {
            const base = buildBase(node) orelse continue;
            const gop = try self.members.getOrPut(allocator, base);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, node.meta.name);
        }
        for (self.members.values()) |*list| {
            std.mem.sort([]const u8, list.items, {}, lessThan);
        }
        return self;
    }

    fn deinit(self: *Bases, allocator: Allocator) void {
        for (self.members.values()) |*list| list.deinit(allocator);
        self.members.deinit(allocator);
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }
};

/// Fail with error.CircularDependency if the pkgbases to build depend on
/// each other in a cycle, including a cycle that only appears at pkgbase
/// level (one package of B needs X, and X needs another package of B).
/// Dependencies between packages of the same pkgbase are not cycles.
pub fn checkBuildCycles(allocator: Allocator, graph: *DepGraph) !void {
    var bases = try Bases.init(allocator, graph);
    defer bases.deinit(allocator);
    const count = bases.members.count();
    if (count == 0) return;

    // For each pkgbase, the distinct pkgbases it needs built first, and the
    // reverse: the pkgbases waiting on it.
    const in_degree = try allocator.alloc(u32, count);
    defer allocator.free(in_degree);
    @memset(in_degree, 0);
    const dependents = try allocator.alloc(std.ArrayListUnmanaged(usize), count);
    defer {
        for (dependents) |*list| list.deinit(allocator);
        allocator.free(dependents);
    }
    @memset(dependents, .empty);

    var needs: std.AutoArrayHashMapUnmanaged(usize, void) = .empty;
    defer needs.deinit(allocator);
    for (bases.members.values(), 0..) |members, i| {
        needs.clearRetainingCapacity();
        for (members.items) |name| {
            for (graph.getNode(name).?.edges.keys()) |raw_dep| {
                const dep = graph.getNode(raw_dep) orelse continue;
                const dep_base = buildBase(dep) orelse continue;
                const j = bases.members.getIndex(dep_base).?;
                if (j != i) try needs.put(allocator, j, {});
            }
        }
        in_degree[i] = @intCast(needs.count());
        for (needs.keys()) |j| try dependents[j].append(allocator, i);
    }

    // Kahn's algorithm: every pkgbase gets processed unless some are in a cycle.
    var queue: std.ArrayListUnmanaged(usize) = .empty;
    defer queue.deinit(allocator);
    for (in_degree, 0..) |deg, i| {
        if (deg == 0) try queue.append(allocator, i);
    }
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        for (dependents[queue.items[head]].items) |i| {
            in_degree[i] -= 1;
            if (in_degree[i] == 0) try queue.append(allocator, i);
        }
    }
    if (queue.items.len != count) return error.CircularDependency;
}

/// Depth-first post-order over every node in the graph: each package comes
/// after all of its dependencies. Walks from `roots` in the given order, and
/// each node's dependencies in declaration order, so the result depends only
/// on the input, and a target's dependency chain sits just before it.
///
/// The packages of a pkgbase that gets built are kept together, after the
/// dependencies of all of them, so the first appearance of a pkgbase is a
/// valid point to build it.
///
/// Repo and installed nodes are leaves to the build but still listed.
/// Cycles are tolerated by skipping edges to visited nodes;
/// checkBuildCycles rejects cycles among the pkgbases to build.
pub fn postOrder(allocator: Allocator, graph: *DepGraph, roots: []const []const u8) ![][]const u8 {
    var walk: PostOrderWalk = .{
        .allocator = allocator,
        .graph = graph,
        .bases = try Bases.init(allocator, graph),
    };
    defer walk.deinit();
    errdefer walk.order.deinit(allocator);

    for (roots) |root| try walk.visit(root);
    // Every node is reachable from a target; this only guards that invariant.
    var it = graph.nodes.keyIterator();
    while (it.next()) |name| try walk.visit(name.*);

    return walk.order.toOwnedSlice(allocator);
}

const PostOrderWalk = struct {
    allocator: Allocator,
    graph: *DepGraph,
    bases: Bases,
    /// Pkgbases to build and other packages are keyed apart, as a package
    /// name may also be some other pkgbase's name.
    visited_bases: std.StringHashMapUnmanaged(void) = .empty,
    visited: std.StringHashMapUnmanaged(void) = .empty,
    order: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *PostOrderWalk) void {
        self.bases.deinit(self.allocator);
        self.visited_bases.deinit(self.allocator);
        self.visited.deinit(self.allocator);
    }

    fn visit(self: *PostOrderWalk, raw_name: []const u8) Allocator.Error!void {
        const node = self.graph.getNode(raw_name) orelse return;
        // Marked on entry, so a cycle stops at the node already on the stack.
        const members: []const []const u8 = if (buildBase(node)) |base| blk: {
            if ((try self.visited_bases.getOrPut(self.allocator, base)).found_existing) return;
            break :blk self.bases.members.get(base).?.items;
        } else blk: {
            if ((try self.visited.getOrPut(self.allocator, node.meta.name)).found_existing) return;
            break :blk (&node.meta.name)[0..1];
        };

        for (members) |name| {
            for (self.graph.getNode(name).?.edges.keys()) |dep| try self.visit(dep);
        }
        try self.order.appendSlice(self.allocator, members);
    }
};
