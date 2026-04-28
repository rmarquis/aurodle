const std = @import("std");
const Allocator = std.mem.Allocator;
const DepGraph = @import("graph.zig").DepGraph;

/// Kahn's algorithm topological sort over AUR nodes in the graph.
/// Returns an owned slice of node names in dependency-first order.
/// Returns error.CircularDependency if a cycle is detected.
pub fn topoSort(allocator: Allocator, graph: *DepGraph) ![][]const u8 {
    var aur_nodes: std.ArrayListUnmanaged([]const u8) = .empty;
    defer aur_nodes.deinit(allocator);

    var graph_it = graph.nodes.iterator();
    while (graph_it.next()) |entry| {
        if (entry.value_ptr.meta.source == .aur) {
            try aur_nodes.append(allocator, entry.key_ptr.*);
        }
    }

    if (aur_nodes.items.len == 0) {
        return allocator.alloc([]const u8, 0);
    }

    // Build reverse edges (dependency → dependents) and in-degrees.
    // Forward edges point dependent → dependency; we invert them
    // so Kahn's BFS can efficiently find who to unblock.
    var in_degree = std.StringHashMapUnmanaged(u32){};
    defer in_degree.deinit(allocator);
    var reverse = std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)){};
    defer {
        var it = reverse.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        reverse.deinit(allocator);
    }

    for (aur_nodes.items) |name| {
        try in_degree.put(allocator, name, 0);
        try reverse.put(allocator, name, .empty);
    }

    for (aur_nodes.items) |src_name| {
        const node = graph.getNode(src_name).?;
        for (node.edges.keys()) |raw_dep| {
            const dep_name = graph.resolveName(raw_dep);
            if (reverse.getPtr(dep_name)) |dependents| {
                try dependents.append(allocator, src_name);
                in_degree.getPtr(src_name).?.* += 1;
            }
        }
    }

    // Seed with zero in-degree nodes; BFS queue doubles as the result
    // since every dequeued node is in topological order.
    var order: std.ArrayListUnmanaged([]const u8) = .empty;

    for (aur_nodes.items) |name| {
        if (in_degree.get(name).? == 0) {
            try order.append(allocator, name);
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
                try order.append(allocator, dependent);
            }
        }
    }

    if (order.items.len != aur_nodes.items.len) {
        return error.CircularDependency;
    }

    return try order.toOwnedSlice(allocator);
}
