/// Test doubles for solver tests: a fake installed-package set and a fake
/// package registry that are entirely in-memory and require no AUR HTTP calls,
/// no libalpm handle, and no filesystem access.
const std = @import("std");
const testing = std.testing;
const registry_mod = @import("../registry.zig");
const aur = @import("../aur.zig");
const pacman_mod = @import("../pacman.zig");

pub const MockInstalledSet = struct {
    installed: std.StringHashMapUnmanaged(void) = .empty,
    providers: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn addInstalled(self: *MockInstalledSet, name: []const u8) void {
        self.installed.put(testing.allocator, name, {}) catch unreachable;
    }

    /// Register that `provider_name` provides `dep_name` (for findProvider lookups).
    pub fn addProvider(self: *MockInstalledSet, dep_name: []const u8, provider_name: []const u8) void {
        self.providers.put(testing.allocator, dep_name, provider_name) catch unreachable;
    }

    pub fn isInstalled(self: MockInstalledSet, name: []const u8) bool {
        return self.installed.contains(name);
    }

    pub fn findProvider(self: MockInstalledSet, dep: []const u8) ?pacman_mod.ProviderMatch {
        const provider_name = self.providers.get(dep) orelse return null;
        return .{ .provider_name = provider_name, .provider_version = "", .db_name = "aurpkgs" };
    }

    fn deinit(self: *MockInstalledSet) void {
        self.installed.deinit(testing.allocator);
        self.providers.deinit(testing.allocator);
    }
};

pub const MockRegistry = struct {
    packages: std.StringHashMapUnmanaged(MockPackageInfo),
    aur_overrides: std.StringHashMapUnmanaged(MockPackageInfo),
    /// Names that resolveMany returns as .unknown but resolve() finds
    /// via provider (simulates AUR provider search fallback).
    deferred_providers: std.StringHashMapUnmanaged(MockPackageInfo) = .empty,
    arena: std.heap.ArenaAllocator,
    pacman: *MockInstalledSet = undefined,

    const MockPackageInfo = struct {
        source: registry_mod.Source,
        version: []const u8,
        pkgbase: []const u8,
        depends: []const []const u8,
        makedepends: []const []const u8,
        aur_pkg: ?*aur.Package,
        provider: ?[]const u8 = null,
    };

    pub fn initEmpty() MockRegistry {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const pm = arena.allocator().create(MockInstalledSet) catch unreachable;
        pm.* = .{};
        return .{
            .packages = .empty,
            .aur_overrides = .empty,
            .arena = arena,
            .pacman = pm,
        };
    }

    pub fn deinitMock(self: *MockRegistry) void {
        self.packages.deinit(testing.allocator);
        self.aur_overrides.deinit(testing.allocator);
        self.deferred_providers.deinit(testing.allocator);
        self.pacman.deinit();
        self.arena.deinit();
    }

    pub fn addAurPackage(self: *MockRegistry, name: []const u8, depends: []const []const u8, makedepends: []const []const u8) void {
        self.addAurPackageWithBase(name, name, depends, makedepends);
    }

    pub fn addAurPackageWithConflicts(self: *MockRegistry, name: []const u8, depends: []const []const u8, conflicts: []const []const u8) void {
        self.addAurPackageFull(name, depends, conflicts, &.{});
    }

    pub fn addAurPackageFullWithReplaces(self: *MockRegistry, name: []const u8, depends: []const []const u8, conflicts: []const []const u8, provides: []const []const u8, replaces: []const []const u8) void {
        const alloc = self.arena.allocator();
        const pkg = alloc.create(aur.Package) catch unreachable;
        pkg.* = .{
            .id = 0,
            .name = name,
            .pkgbase = name,
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
            .makedepends = &.{},
            .checkdepends = &.{},
            .optdepends = &.{},
            .provides = provides,
            .conflicts = conflicts,
            .replaces = replaces,
            .groups = &.{},
            .keywords = &.{},
            .licenses = &.{},
            .comaintainers = &.{},
        };
        self.packages.put(testing.allocator, name, .{
            .source = .aur,
            .version = "1.0-1",
            .pkgbase = name,
            .depends = depends,
            .makedepends = &.{},
            .aur_pkg = pkg,
        }) catch unreachable;
    }

    pub fn addAurPackageFull(self: *MockRegistry, name: []const u8, depends: []const []const u8, conflicts: []const []const u8, provides: []const []const u8) void {
        const alloc = self.arena.allocator();
        const pkg = alloc.create(aur.Package) catch unreachable;
        pkg.* = .{
            .id = 0,
            .name = name,
            .pkgbase = name,
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
            .makedepends = &.{},
            .checkdepends = &.{},
            .optdepends = &.{},
            .provides = provides,
            .conflicts = conflicts,
            .replaces = &.{},
            .groups = &.{},
            .keywords = &.{},
            .licenses = &.{},
            .comaintainers = &.{},
        };
        self.packages.put(testing.allocator, name, .{
            .source = .aur,
            .version = "1.0-1",
            .pkgbase = name,
            .depends = depends,
            .makedepends = &.{},
            .aur_pkg = pkg,
        }) catch unreachable;
    }

    pub fn addAurPackageWithBase(self: *MockRegistry, name: []const u8, pkgbase: []const u8, depends: []const []const u8, makedepends: []const []const u8) void {
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
    pub fn addSatisfiedWithAurDeps(self: *MockRegistry, name: []const u8, version: []const u8, depends: []const []const u8, makedepends: []const []const u8) void {
        self.packages.put(testing.allocator, name, .{
            .source = .satisfied_aur,
            .version = version,
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

    /// Like addSatisfiedWithAurDeps but with separate installed and AUR versions.
    pub fn addSatisfiedWithAurDepsVersioned(self: *MockRegistry, name: []const u8, installed_version: []const u8, aur_version: []const u8, depends: []const []const u8, makedepends: []const []const u8) void {
        self.packages.put(testing.allocator, name, .{
            .source = .satisfied_aur,
            .version = installed_version,
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

    pub fn addRepoPackage(self: *MockRegistry, name: []const u8, version: []const u8) void {
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
    pub fn addRepoAur(self: *MockRegistry, name: []const u8, version: []const u8) void {
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
    pub fn addRepoAurWithAurVersion(self: *MockRegistry, name: []const u8, local_version: []const u8, aur_version: []const u8, depends: []const []const u8, makedepends: []const []const u8) void {
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

    pub fn addSatisfied(self: *MockRegistry, name: []const u8, version: []const u8) void {
        self.packages.put(testing.allocator, name, .{
            .source = .satisfied_aur,
            .version = version,
            .pkgbase = name,
            .depends = &.{},
            .makedepends = &.{},
            .aur_pkg = null,
        }) catch unreachable;
    }

    pub fn addSatisfiedRepo(self: *MockRegistry, name: []const u8, version: []const u8) void {
        self.packages.put(testing.allocator, name, .{
            .source = .satisfied_repos,
            .version = version,
            .pkgbase = name,
            .depends = &.{},
            .makedepends = &.{},
            .aur_pkg = null,
        }) catch unreachable;
    }

    /// Register a virtual name that resolveMany returns as .unknown but
    /// resolve() finds via AUR provider search (e.g. "auracle" → "auracle-git"
    /// when auracle-git is not installed but exists in AUR).
    pub fn addDeferredProvider(self: *MockRegistry, virtual_name: []const u8, provider_name: []const u8) void {
        const alloc = self.arena.allocator();
        const pkg = alloc.create(aur.Package) catch unreachable;
        pkg.* = .{
            .id = 0,
            .name = provider_name,
            .pkgbase = provider_name,
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
            .depends = &.{},
            .makedepends = &.{},
            .checkdepends = &.{},
            .optdepends = &.{},
            .provides = &.{virtual_name},
            .conflicts = &.{},
            .replaces = &.{},
            .groups = &.{},
            .keywords = &.{},
            .licenses = &.{},
            .comaintainers = &.{},
        };
        self.deferred_providers.put(testing.allocator, virtual_name, .{
            .source = .aur,
            .version = "1.0-1",
            .pkgbase = provider_name,
            .depends = &.{},
            .makedepends = &.{},
            .aur_pkg = pkg,
            .provider = provider_name,
        }) catch unreachable;
    }

    /// Register a virtual name that redirects to a provider package.
    /// Simulates "auracle" → "auracle-git" via provider resolution.
    pub fn addProvider(self: *MockRegistry, virtual_name: []const u8, provider_name: []const u8, source: registry_mod.Source, version: []const u8) void {
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

    // ── Interface matching PackageRegistry ────────────────────────────────

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
            if (self.deferred_providers.get(spec.name)) |dp| {
                return .{
                    .name = spec.name,
                    .source = dp.source,
                    .version = dp.version,
                    .aur_pkg = dp.aur_pkg,
                    .provider = dp.provider,
                };
            }
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
        if (self.aur_overrides.get(name)) |aur_info| {
            return .{
                .name = name,
                .source = .aur,
                .version = aur_info.version,
                .aur_pkg = aur_info.aur_pkg,
            };
        }
        if (self.deferred_providers.get(name)) |dp| {
            return .{
                .name = dp.aur_pkg.?.name,
                .source = .aur,
                .version = dp.version,
                .aur_pkg = dp.aur_pkg,
                .provider = dp.provider,
            };
        }
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
