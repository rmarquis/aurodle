//! Provider lookup over sync databases: which packages are called, or
//! provide, a given name. Answered by scanning the package caches, or by
//! ProvidesIndex once a resolution has made enough lookups to pay for it.
//! Pacman (pacman.zig) decides which databases to search and when to use
//! the index.

const std = @import("std");
const Allocator = std.mem.Allocator;
const alpm = @import("../alpm.zig");
const ProviderCandidate = @import("../provider.zig").ProviderCandidate;

/// Every sync package indexed under its own name and each name it
/// provides, so provider lookups cost a hash lookup instead of a walk over
/// all ~15k packages and their provides lists. Entries for a name keep the
/// scan order: official databases in pacman.conf order, then the AUR repo,
/// each in package cache order. Strings are borrowed from libalpm and stay
/// valid until Pacman.deinit.
/// Not thread-safe.
pub const ProvidesIndex = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Entry)) = .empty,
    built: bool = false,
    /// Lookups answered by scanning while the index was not built.
    lookups: u32 = 0,

    /// One scan of every sync package takes about 1 ms; building the
    /// index about 8 ms.
    pub const scan_lookups = 8;

    const Entry = struct {
        match: ProviderCandidate,
        /// False for the local AUR repository.
        official: bool,
    };

    pub fn create(allocator: Allocator) !*ProvidesIndex {
        const index = try allocator.create(ProvidesIndex);
        index.* = .{ .allocator = allocator, .arena = .init(allocator) };
        return index;
    }

    pub fn destroy(self: *ProvidesIndex) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn reset(self: *ProvidesIndex) void {
        _ = self.arena.reset(.free_all);
        self.map = .empty;
        self.built = false;
        self.lookups = 0;
    }

    pub fn build(self: *ProvidesIndex, official_dbs: []const alpm.Database, aurpkgs_db: ?alpm.Database) !void {
        for (official_dbs) |db| try self.addDb(db, true);
        if (aurpkgs_db) |db| try self.addDb(db, false);
        self.built = true;
    }

    fn addDb(self: *ProvidesIndex, db: alpm.Database, official: bool) !void {
        var it = db.getPkgcache();
        while (it.next()) |pkg| {
            const entry: Entry = .{ .match = providerMatchFromPkg(pkg, db), .official = official };
            try self.add(pkg.getName(), entry);
            var prov_it = pkg.getProvides();
            while (prov_it.next()) |prov| try self.add(prov.name, entry);
        }
    }

    fn add(self: *ProvidesIndex, name: []const u8, entry: Entry) !void {
        const arena = self.arena.allocator();
        const gop = try self.map.getOrPut(arena, name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const list = gop.value_ptr;
        // A package listing a name twice (or providing its own name)
        // is still one provider.
        if (list.items.len > 0 and list.items[list.items.len - 1].match.name.ptr == entry.match.name.ptr) return;
        try list.append(arena, entry);
    }

    pub fn get(self: *const ProvidesIndex, name: []const u8) []const Entry {
        const list = self.map.get(name) orelse return &.{};
        return list.items;
    }

    /// Providers of `name`, optionally official ones only. Caller owns
    /// the slice.
    pub fn collect(self: *const ProvidesIndex, allocator: Allocator, name: []const u8, official_only: bool) ![]ProviderCandidate {
        var matches: std.ArrayList(ProviderCandidate) = .empty;
        errdefer matches.deinit(allocator);
        for (self.get(name)) |entry| {
            if (official_only and !entry.official) continue;
            try matches.append(allocator, entry.match);
        }
        return try matches.toOwnedSlice(allocator);
    }
};

/// Search a single database for a package that provides `dep`.
pub fn findProviderInDb(db: alpm.Database, dep: []const u8) ?ProviderCandidate {
    var it = db.getPkgcache();
    while (it.next()) |pkg| {
        if (packageMatchesDep(pkg, dep)) return providerMatchFromPkg(pkg, db);
    }
    return null;
}

/// Collect ALL packages in a single database that provide `dep`.
pub fn findAllProvidersInDb(allocator: Allocator, db: alpm.Database, dep: []const u8, matches: *std.ArrayList(ProviderCandidate)) !void {
    var it = db.getPkgcache();
    while (it.next()) |pkg| {
        if (packageMatchesDep(pkg, dep)) {
            try matches.append(allocator, providerMatchFromPkg(pkg, db));
        }
    }
}

fn packageMatchesDep(pkg: alpm.AlpmPackage, dep: []const u8) bool {
    if (std.mem.eql(u8, pkg.getName(), dep)) return true;
    var dep_it = pkg.getProvides();
    while (dep_it.next()) |prov| {
        if (std.mem.eql(u8, prov.name, dep)) return true;
    }
    return false;
}

fn providerMatchFromPkg(pkg: alpm.AlpmPackage, db: alpm.Database) ProviderCandidate {
    return .{
        .name = pkg.getName(),
        .version = pkg.getVersion(),
        .db_name = db.getName(),
    };
}
