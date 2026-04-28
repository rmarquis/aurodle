/// Test doubles for registry tests: a fake pacman handle and a fake AUR client
/// that are entirely in-memory and require no libalpm handle, no HTTP calls,
/// and no filesystem access.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const aur = @import("../aur.zig");
const pacman_mod = @import("../pacman.zig");

pub const MockPacman = struct {
    installed: std.StringHashMapUnmanaged([]const u8), // name → version
    sync: std.StringHashMapUnmanaged(SyncEntry), // name → {version, db_name}
    providers: std.StringHashMapUnmanaged(pacman_mod.ProviderMatch),
    /// Multi-provider map: dep_name → list of all providers
    all_providers: std.StringHashMapUnmanaged([]const pacman_mod.ProviderMatch) = .empty,
    aur_repo_name: []const u8 = "aurpkgs",

    const SyncEntry = struct {
        version: []const u8,
        db_name: []const u8,
    };

    pub fn initEmpty() MockPacman {
        return .{
            .installed = .empty,
            .sync = .empty,
            .providers = .empty,
        };
    }

    pub fn deinitMock(self: *MockPacman) void {
        self.installed.deinit(testing.allocator);
        self.sync.deinit(testing.allocator);
        self.providers.deinit(testing.allocator);
        self.all_providers.deinit(testing.allocator);
    }

    pub fn addInstalled(self: *MockPacman, name: []const u8, version: []const u8) void {
        self.installed.put(testing.allocator, name, version) catch unreachable;
    }

    pub fn addSync(self: *MockPacman, name: []const u8, version: []const u8, db_name: []const u8) void {
        self.sync.put(testing.allocator, name, .{ .version = version, .db_name = db_name }) catch unreachable;
    }

    pub fn addProvider(self: *MockPacman, dep: []const u8, match: pacman_mod.ProviderMatch) void {
        self.providers.put(testing.allocator, dep, match) catch unreachable;
    }

    pub fn addProviders(self: *MockPacman, dep: []const u8, matches: []const pacman_mod.ProviderMatch) void {
        self.all_providers.put(testing.allocator, dep, matches) catch unreachable;
        if (matches.len > 0) {
            self.providers.put(testing.allocator, dep, matches[0]) catch unreachable;
        }
    }

    // ── Methods matching Pacman interface ─────────────────────────────────

    pub fn isAurRepo(self: MockPacman, db_name: []const u8) bool {
        return std.mem.eql(u8, db_name, self.aur_repo_name);
    }

    pub fn isInstalled(self: MockPacman, name: []const u8) bool {
        return self.installed.contains(name);
    }

    pub fn installedVersion(self: MockPacman, name: []const u8) ?[]const u8 {
        return self.installed.get(name);
    }

    pub fn isInSyncDb(self: MockPacman, name: []const u8) bool {
        return self.sync.contains(name);
    }

    pub fn isInOfficialSyncDb(self: MockPacman, name: []const u8) bool {
        const entry = self.sync.get(name) orelse return false;
        return !self.isAurRepo(entry.db_name);
    }

    pub fn syncDbFor(self: MockPacman, name: []const u8) ?[]const u8 {
        const entry = self.sync.get(name) orelse return null;
        return entry.db_name;
    }

    pub fn syncVersion(self: MockPacman, name: []const u8) ?[]const u8 {
        const entry = self.sync.get(name) orelse return null;
        return entry.version;
    }

    pub fn officialSyncVersion(self: MockPacman, name: []const u8) ?[]const u8 {
        const entry = self.sync.get(name) orelse return null;
        if (self.isAurRepo(entry.db_name)) return null;
        return entry.version;
    }

    pub fn satisfies(self: MockPacman, name: []const u8, constraint: pacman_mod.VersionConstraint) bool {
        const version = self.installed.get(name) orelse return false;
        return pacman_mod.checkVersion(version, constraint);
    }

    pub fn findLocalSatisfier(self: MockPacman, dep: []const u8) ?[]const u8 {
        if (self.installed.contains(dep)) return dep;
        if (self.providers.get(dep)) |match| {
            if (self.installed.contains(match.provider_name)) return match.provider_name;
        }
        return null;
    }

    pub fn findProvider(self: MockPacman, dep: []const u8) ?pacman_mod.ProviderMatch {
        return self.providers.get(dep);
    }

    pub fn findAllProviders(self: *MockPacman, allocator: Allocator, dep: []const u8) ![]pacman_mod.ProviderMatch {
        if (self.all_providers.get(dep)) |matches| {
            return try allocator.dupe(pacman_mod.ProviderMatch, matches);
        }
        if (self.providers.get(dep)) |match| {
            const result = try allocator.alloc(pacman_mod.ProviderMatch, 1);
            result[0] = match;
            return result;
        }
        return try allocator.alloc(pacman_mod.ProviderMatch, 0);
    }
};

pub const MockAurClient = struct {
    packages: std.StringHashMapUnmanaged(*aur.Package),
    /// Maps a "provides" name to the provider package name.
    aur_providers: std.StringHashMapUnmanaged([]const u8),
    multi_info_call_count: usize,
    info_call_count: usize,
    search_call_count: usize,
    should_error: bool,
    arena: std.heap.ArenaAllocator,

    pub fn initEmpty() MockAurClient {
        return .{
            .packages = .empty,
            .aur_providers = .empty,
            .multi_info_call_count = 0,
            .info_call_count = 0,
            .search_call_count = 0,
            .should_error = false,
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }

    pub fn deinitMock(self: *MockAurClient) void {
        self.packages.deinit(testing.allocator);
        self.aur_providers.deinit(testing.allocator);
        self.arena.deinit();
    }

    pub fn addPackage(self: *MockAurClient, name: []const u8, version: []const u8) void {
        self.addPackageWithProvides(name, version, &.{});
    }

    pub fn addPackageWithProvides(self: *MockAurClient, name: []const u8, version: []const u8, provides: []const []const u8) void {
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
            .depends = &.{},
            .makedepends = &.{},
            .checkdepends = &.{},
            .optdepends = &.{},
            .provides = provides,
            .conflicts = &.{},
            .replaces = &.{},
            .groups = &.{},
            .keywords = &.{},
            .licenses = &.{},
            .comaintainers = &.{},
        };
        self.packages.put(testing.allocator, name, pkg) catch unreachable;

        for (provides) |prov| {
            self.aur_providers.put(testing.allocator, prov, name) catch unreachable;
        }
    }

    pub fn info(self: *MockAurClient, name: []const u8) !?*aur.Package {
        self.info_call_count += 1;
        if (self.should_error) return error.NetworkError;
        return self.packages.get(name);
    }

    pub fn multiInfo(self: *MockAurClient, names: []const []const u8) ![]const *aur.Package {
        self.multi_info_call_count += 1;
        if (self.should_error) return error.NetworkError;

        var results: std.ArrayList(*aur.Package) = .empty;
        defer results.deinit(testing.allocator);

        for (names) |name| {
            if (self.packages.get(name)) |pkg| {
                try results.append(testing.allocator, pkg);
            }
        }

        return try results.toOwnedSlice(testing.allocator);
    }

    pub fn search(self: *MockAurClient, query: []const u8, by: aur.SearchField) ![]const *aur.Package {
        self.search_call_count += 1;
        if (self.should_error) return error.NetworkError;

        _ = by;
        var results: std.ArrayList(*aur.Package) = .empty;
        defer results.deinit(testing.allocator);

        var it = self.packages.valueIterator();
        while (it.next()) |pkg_ptr| {
            const pkg = pkg_ptr.*;
            for (pkg.provides) |prov| {
                if (std.mem.eql(u8, prov, query)) {
                    try results.append(testing.allocator, pkg);
                    break;
                }
            }
        }

        return try results.toOwnedSlice(testing.allocator);
    }
};
