//! Transitive official-repo dependency walks for the build plan: which
//! repo packages an install pulls in, and where a virtual dependency needs
//! the user to choose a provider.
//!
//! Generic over `pm` so tests can use an in-memory package world
//! (pacman/mocks.zig). `pm` must provide isInstalled, satisfiesDep,
//! findInOfficialDbs, findSyncPkgForDep and findAllOfficialProviders, as
//! Pacman does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ProviderCandidate = @import("../provider.zig").ProviderCandidate;

/// A virtual dep (e.g. "jack") with multiple uninstalled providers in official repos.
/// Returned by findTransitiveProviderChoices for interactive selection.
pub const SyncProviderChoice = struct {
    dep_name: []const u8, // virtual dep name, borrowed from alpm memory
    candidates: []ProviderCandidate, // all uninstalled providers; caller owns slice
};

/// Compute the full set of official-repo packages that would need to be
/// installed when installing `root_names`, following runtime `depends`
/// transitively and excluding packages already installed locally.
///
/// `provider_choices` maps virtual dep names (e.g. "jack") to the chosen
/// provider package name (e.g. "pipewire-jack"). When a dep is present in
/// the map the chosen package is used; otherwise first-satisfier wins.
///
/// Deps already satisfied by an installed package (by name or provides)
/// are excluded — installing a repo provider would conflict with the
/// installed satisfier (e.g. nodejs-lts-jod vs nodejs-lts-krypton).
///
/// Caller owns the returned slice (strings themselves are borrowed from
/// libalpm memory and remain valid until Pacman.deinit).
pub fn transitiveRepoDeps(
    pm: anytype,
    allocator: Allocator,
    root_names: []const []const u8,
    provider_choices: std.StringHashMapUnmanaged([]const u8),
) ![][]const u8 {
    var result = std.StringArrayHashMapUnmanaged(void){};
    defer result.deinit(allocator);

    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    defer queue.deinit(allocator);

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    for (root_names) |name| {
        if (!(try seen.getOrPut(allocator, name)).found_existing) {
            try queue.append(allocator, name);
        }
    }

    var head: usize = 0;
    while (head < queue.items.len) {
        const dep_str = queue.items[head];
        head += 1;

        // Satisfied by an installed package (by name or via provides) —
        // do not pull in a repo provider that would conflict with it.
        if (pm.satisfiesDep(dep_str)) continue;

        const pkg = (if (provider_choices.get(dep_str)) |chosen_name|
            pm.findInOfficialDbs(chosen_name)
        else
            pm.findSyncPkgForDep(dep_str)) orelse continue;
        const pkg_name = pkg.getName();

        try seen.put(allocator, pkg_name, {});

        if (pm.isInstalled(pkg_name)) continue;

        if (!(try result.getOrPut(allocator, pkg_name)).found_existing) {
            var dep_it = pkg.getDepends();
            while (dep_it.next()) |dep| {
                if (!(try seen.getOrPut(allocator, dep.name)).found_existing) {
                    try queue.append(allocator, dep.name);
                }
            }
        }
    }

    return try allocator.dupe([]const u8, result.keys());
}

/// Walk the transitive repo dep closure of `root_names` and return a
/// `SyncProviderChoice` for each virtual dep that has more than one
/// uninstalled provider in official repos.
///
/// Deps already satisfied by an installed package (by name or provides)
/// are skipped — no choice is needed and offering one would propose
/// providers that conflict with the installed satisfier.
///
/// BFS uses first-satisfier order; the returned choices are in BFS
/// encounter order.  Caller owns the slice and each `candidates` slice
/// inside it.
pub fn findTransitiveProviderChoices(
    pm: anytype,
    allocator: Allocator,
    root_names: []const []const u8,
) ![]SyncProviderChoice {
    var choices: std.ArrayListUnmanaged(SyncProviderChoice) = .empty;
    errdefer {
        for (choices.items) |ch| allocator.free(ch.candidates);
        choices.deinit(allocator);
    }

    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    for (root_names) |name| {
        if (!(try seen.getOrPut(allocator, name)).found_existing) {
            try queue.append(allocator, name);
        }
    }

    var head: usize = 0;
    while (head < queue.items.len) {
        const dep_str = queue.items[head];
        head += 1;

        // Already satisfied by an installed package (by name or via
        // provides, e.g. nodejs-lts-krypton provides nodejs) — nothing
        // to choose or install.
        if (pm.satisfiesDep(dep_str)) continue;

        const all = try pm.findAllOfficialProviders(allocator, dep_str);
        defer allocator.free(all);

        var uninstalled: std.ArrayListUnmanaged(ProviderCandidate) = .empty;
        defer uninstalled.deinit(allocator);
        for (all) |p| {
            if (!pm.isInstalled(p.name)) {
                try uninstalled.append(allocator, p);
            }
        }

        if (uninstalled.items.len == 0) continue;

        const first_name = uninstalled.items[0].name;
        try seen.put(allocator, first_name, {});

        if (uninstalled.items.len > 1) {
            var claimed = false;
            const candidates = try uninstalled.toOwnedSlice(allocator);
            errdefer if (!claimed) allocator.free(candidates);
            try choices.append(allocator, .{ .dep_name = dep_str, .candidates = candidates });
            claimed = true;
        }

        const pkg = pm.findInOfficialDbs(first_name) orelse continue;
        if (pm.isInstalled(first_name)) continue;

        var dep_it = pkg.getDepends();
        while (dep_it.next()) |dep| {
            if (!(try seen.getOrPut(allocator, dep.name)).found_existing) {
                try queue.append(allocator, dep.name);
            }
        }
    }

    return try choices.toOwnedSlice(allocator);
}
