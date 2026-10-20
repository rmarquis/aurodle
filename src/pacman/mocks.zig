/// Test doubles for the pacman BFS functions (findTransitiveProviderChoices,
/// transitiveRepoDeps): an in-memory package world with no libalpm handle.
///
/// Unlike registry/mocks.zig (which fakes the Pacman interface used by the
/// registry cascade), this mock also fakes the package/depends layer those
/// BFS walks traverse.
const std = @import("std");
const Allocator = std.mem.Allocator;
const pacman_mod = @import("../pacman.zig");

pub const MockPackage = struct {
    name: []const u8,
    version: []const u8 = "1.0-1",
    db_name: []const u8 = "extra",
    depends: []const []const u8 = &.{},
    /// Entries may be bare ("nodejs") or versioned ("nodejs=24.22.0"),
    /// mirroring libalpm's provides lists.
    provides: []const []const u8 = &.{},

    pub fn getName(self: MockPackage) []const u8 {
        return self.name;
    }

    pub fn getDepends(self: MockPackage) DepIterator {
        return .{ .deps = self.depends };
    }

    pub const DepIterator = struct {
        deps: []const []const u8,
        index: usize = 0,

        pub const Dep = struct { name: []const u8 };

        pub fn next(self: *DepIterator) ?Dep {
            if (self.index >= self.deps.len) return null;
            defer self.index += 1;
            return .{ .name = self.deps[self.index] };
        }
    };
};

/// Strip a trailing "=version" from a provides entry, as libalpm matches
/// unversioned deps against versioned provides.
fn providesName(entry: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, entry, '=')) |i| return entry[0..i];
    return entry;
}

fn pkgProvides(pkg: MockPackage, dep: []const u8) bool {
    if (std.mem.eql(u8, pkg.name, dep)) return true;
    for (pkg.provides) |entry| {
        if (std.mem.eql(u8, providesName(entry), dep)) return true;
    }
    return false;
}

pub const MockPacman = struct {
    /// Official sync-db packages.
    sync_pkgs: []const MockPackage = &.{},
    /// Installed packages (name and provides are consulted; version/depends
    /// are not needed by the BFS).
    local_pkgs: []const MockPackage = &.{},

    pub fn isInstalled(self: MockPacman, name: []const u8) bool {
        for (self.local_pkgs) |pkg| {
            if (std.mem.eql(u8, pkg.name, name)) return true;
        }
        return false;
    }

    pub fn satisfiesDep(self: MockPacman, dep: []const u8) bool {
        for (self.local_pkgs) |pkg| {
            if (pkgProvides(pkg, dep)) return true;
        }
        return false;
    }

    pub fn findAllOfficialProviders(
        self: MockPacman,
        allocator: Allocator,
        dep: []const u8,
    ) ![]pacman_mod.ProviderMatch {
        var matches: std.ArrayList(pacman_mod.ProviderMatch) = .empty;
        errdefer matches.deinit(allocator);
        for (self.sync_pkgs) |pkg| {
            if (pkgProvides(pkg, dep)) {
                try matches.append(allocator, .{
                    .provider_name = pkg.name,
                    .provider_version = pkg.version,
                    .db_name = pkg.db_name,
                });
            }
        }
        return try matches.toOwnedSlice(allocator);
    }

    pub fn findInOfficialDbs(self: MockPacman, name: []const u8) ?MockPackage {
        for (self.sync_pkgs) |pkg| {
            if (std.mem.eql(u8, pkg.name, name)) return pkg;
        }
        return null;
    }

    pub fn findSyncPkgForDep(self: MockPacman, dep: []const u8) ?MockPackage {
        for (self.sync_pkgs) |pkg| {
            if (pkgProvides(pkg, dep)) return pkg;
        }
        return null;
    }
};
