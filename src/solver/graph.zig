const std = @import("std");
const Allocator = std.mem.Allocator;
const registry_mod = @import("../registry.zig");
const aur = @import("../aur.zig");

pub const NodeMeta = struct {
    name: []const u8 = "",
    source: registry_mod.Source = .unknown,
    version: ?[]const u8 = null,
    pkgbase: ?[]const u8 = null,
    aur_pkg: ?*aur.Package = null,
    depth: u32 = 0,
};

/// Directed dependency graph with alias (virtual-name → real-name) resolution.
/// Nodes represent packages; edges point from dependent to dependency.
pub const DepGraph = struct {
    nodes: std.StringHashMapUnmanaged(Node),
    /// Maps virtual/provided names to actual node names (e.g. "auracle" → "auracle-git").
    aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
    allocator: Allocator,

    pub const Node = struct {
        meta: NodeMeta,
        /// Outgoing edges: packages this node depends on.
        edges: std.StringArrayHashMapUnmanaged(void),
    };

    pub fn init(allocator: Allocator) DepGraph {
        return .{
            .nodes = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DepGraph) void {
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.edges.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.aliases.deinit(self.allocator);
    }

    /// Add a node for `name` with the given metadata. Idempotent: returns the
    /// existing node pointer if `name` is already present.
    pub fn addNode(self: *DepGraph, name: []const u8, meta: NodeMeta) !*Node {
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

    /// Register a virtual name as an alias for an actual node name.
    pub fn addAlias(self: *DepGraph, virtual_name: []const u8, actual_name: []const u8) !void {
        try self.aliases.put(self.allocator, virtual_name, actual_name);
    }

    /// Look up a node by name, following aliases if needed.
    pub fn getNode(self: *DepGraph, name: []const u8) ?*Node {
        if (self.nodes.getPtr(name)) |node| return node;
        const actual = self.aliases.get(name) orelse return null;
        return self.nodes.getPtr(actual);
    }

    /// Resolve a name through aliases (for edge lookups during topological sort).
    pub fn resolveName(self: *DepGraph, name: []const u8) []const u8 {
        return self.aliases.get(name) orelse name;
    }

    /// Update a node's depth to the maximum of its current value and `depth`.
    pub fn updateDepth(self: *DepGraph, name: []const u8, depth: u32) void {
        if (self.getNode(name)) |node| {
            if (depth > node.meta.depth) node.meta.depth = depth;
        }
    }
};
