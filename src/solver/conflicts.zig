const std = @import("std");
const Allocator = std.mem.Allocator;
const DepGraph = @import("graph.zig").DepGraph;
const registry_mod = @import("../registry.zig");

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

/// Scan AUR nodes for declared conflicts against other graph nodes and
/// installed packages. Provides-aware: if A conflicts with virtual name
/// "libfoo" and B provides "libfoo", that is an AUR↔AUR conflict.
pub fn detectConflicts(
    comptime PacmanT: type,
    allocator: Allocator,
    graph: *DepGraph,
    pacman: *PacmanT,
) ![]Conflict {
    var conflicts: std.ArrayListUnmanaged(Conflict) = .empty;

    // Build reverse provides map: provided_name → provider_node_name
    // for all AUR packages in the graph.
    var provides_map = std.StringHashMapUnmanaged([]const u8){};
    defer provides_map.deinit(allocator);
    {
        var it = graph.nodes.iterator();
        while (it.next()) |gentry| {
            const pkg = gentry.value_ptr.meta.aur_pkg orelse continue;
            for (pkg.provides) |prov| {
                const prov_name = registry_mod.parseDep(prov).name;
                try provides_map.put(allocator, prov_name, gentry.value_ptr.meta.name);
            }
        }
    }

    // Track seen AUR↔AUR pairs to deduplicate bidirectional conflicts.
    // Key: "smaller\x00larger" canonical pair.
    var seen_pairs = std.StringHashMapUnmanaged(void){};
    defer {
        var it = seen_pairs.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        seen_pairs.deinit(allocator);
    }

    var graph_it = graph.nodes.iterator();
    while (graph_it.next()) |entry| {
        const node = entry.value_ptr;

        if (node.meta.aur_pkg) |pkg| {
            for (pkg.conflicts) |conflict_dep| {
                const conflict_name = registry_mod.parseDep(conflict_dep).name;
                if (std.mem.eql(u8, conflict_name, node.meta.name)) continue;

                // Resolve conflict target: direct graph node or provides lookup.
                // Use n.meta.name (not conflict_name) so alias "auracle" → "auracle-git"
                // yields "auracle-git", letting the self-conflict check below suppress
                // auracle-git conflicting with its own provided name "auracle".
                const resolved_name = if (graph.getNode(conflict_name)) |n|
                    n.meta.name
                else if (provides_map.get(conflict_name)) |provider|
                    provider
                else
                    conflict_name;

                if (!std.mem.eql(u8, resolved_name, node.meta.name)) {
                    if (graph.getNode(resolved_name)) |conflict_node| {
                        if (conflict_node.meta.aur_pkg != null) {
                            _ = try addConflictPair(allocator, &seen_pairs, &conflicts, node.meta.name, resolved_name);
                            continue;
                        }
                    }
                }

                try checkInstalledConflict(PacmanT, allocator, &conflicts, pacman, node.meta.name, conflict_name, .aur_installed);
            }

            for (pkg.replaces) |replace_dep| {
                const replace_name = registry_mod.parseDep(replace_dep).name;
                if (std.mem.eql(u8, replace_name, node.meta.name)) continue;
                try checkInstalledConflict(PacmanT, allocator, &conflicts, pacman, node.meta.name, replace_name, .aur_replaces);
            }
        }

        if (node.meta.source == .repos) {
            try checkRepoVsInstalled(PacmanT, allocator, &conflicts, graph, pacman, node.meta.name);
        }
    }

    return try conflicts.toOwnedSlice(allocator);
}

fn addConflictPair(
    allocator: Allocator,
    seen_pairs: *std.StringHashMapUnmanaged(void),
    conflicts: *std.ArrayListUnmanaged(Conflict),
    pkg_name: []const u8,
    resolved_name: []const u8,
) !bool {
    const is_lt = std.mem.order(u8, pkg_name, resolved_name) == .lt;
    const a = if (is_lt) pkg_name else resolved_name;
    const b = if (is_lt) resolved_name else pkg_name;
    const pair_key = try std.mem.concat(allocator, u8, &.{ a, "\x00", b });
    const gop = try seen_pairs.getOrPut(allocator, pair_key);
    if (gop.found_existing) {
        allocator.free(pair_key);
        return true;
    }
    try conflicts.append(allocator, .{
        .package = pkg_name,
        .conflicts_with = resolved_name,
        .kind = .aur_aur,
    });
    return false;
}

fn checkInstalledConflict(
    comptime PacmanT: type,
    allocator: Allocator,
    conflicts: *std.ArrayListUnmanaged(Conflict),
    pacman: *PacmanT,
    pkg_name: []const u8,
    dep_name: []const u8,
    kind: Conflict.Kind,
) !void {
    if (pacman.isInstalled(dep_name)) {
        try conflicts.append(allocator, .{
            .package = pkg_name,
            .conflicts_with = dep_name,
            .kind = kind,
        });
    } else if (@hasDecl(PacmanT, "findProvider")) {
        if (pacman.findProvider(dep_name)) |provider| {
            if (std.mem.eql(u8, provider.provider_name, pkg_name)) return;
            if (pacman.isInstalled(provider.provider_name)) {
                try conflicts.append(allocator, .{
                    .package = pkg_name,
                    .conflicts_with = provider.provider_name,
                    .kind = kind,
                });
            }
        }
    }
}

fn checkRepoVsInstalled(
    comptime PacmanT: type,
    allocator: Allocator,
    conflicts: *std.ArrayListUnmanaged(Conflict),
    graph: *DepGraph,
    pacman: *PacmanT,
    name: []const u8,
) !void {
    if (@hasDecl(PacmanT, "syncPkgConflictsWithInstalled")) {
        if (pacman.syncPkgConflictsWithInstalled(name)) |installed_name| {
            if (graph.getNode(installed_name) == null) {
                try conflicts.append(allocator, .{ .package = name, .conflicts_with = installed_name, .kind = .repo_installed });
            }
        }
    }
    if (@hasDecl(PacmanT, "syncPkgReplacesInstalled")) {
        if (pacman.syncPkgReplacesInstalled(name)) |installed_name| {
            if (graph.getNode(installed_name) == null) {
                try conflicts.append(allocator, .{ .package = name, .conflicts_with = installed_name, .kind = .repo_replaces });
            }
        }
    }
}
