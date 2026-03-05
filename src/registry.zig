const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("aur.zig");
const pacman_mod = @import("pacman.zig");

// ── Public Types ─────────────────────────────────────────────────────────

pub const Source = enum {
    satisfied, // installed locally
    repos, // in official sync databases
    aur, // found in AUR
    unknown, // not found anywhere
};

pub const Resolution = struct {
    name: []const u8,
    source: Source,
    version: ?[]const u8 = null,
    aur_pkg: ?*aur.Package = null,
    provider: ?[]const u8 = null,
};

pub const DepSpec = struct {
    name: []const u8,
    constraint: ?pacman_mod.VersionConstraint = null,
};

// ── Production Type Alias ────────────────────────────────────────────────

pub const PackageRegistry = RegistryImpl(pacman_mod.Pacman, aur.Client);

// ── Generic Registry Implementation ──────────────────────────────────────

pub fn RegistryImpl(comptime PacmanT: type, comptime AurClientT: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        pacman: *PacmanT,
        aur_client: *AurClientT,
        cache: std.StringHashMapUnmanaged(Resolution),
        pending_aur: std.StringArrayHashMapUnmanaged(void),

        pub fn init(allocator: Allocator, pm: *PacmanT, ac: *AurClientT) Self {
            return .{
                .allocator = allocator,
                .pacman = pm,
                .aur_client = ac,
                .cache = .empty,
                .pending_aur = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.cache.deinit(self.allocator);
            self.pending_aur.deinit(self.allocator);
        }

        /// Resolve a single dependency string through the cascade:
        /// cache → installed → sync DBs → AUR → provider → unknown
        pub fn resolve(self: *Self, dep_string: []const u8) !Resolution {
            const spec = parseDep(dep_string);

            // Cache check (by name, not dep string)
            if (self.cache.get(spec.name)) |cached| {
                // Re-verify constraint for cached result
                if (spec.constraint) |c| {
                    if (cached.version) |v| {
                        if (!pacman_mod.checkVersion(v, c)) {
                            // Cached version doesn't satisfy this constraint
                            return .{
                                .name = spec.name,
                                .source = .unknown,
                                .version = cached.version,
                                .aur_pkg = cached.aur_pkg,
                            };
                        }
                    }
                }
                return cached;
            }

            // Tier 1: Installed locally?
            if (self.resolveLocal(spec.name, spec.constraint)) |res| {
                try self.cacheResult(spec.name, res);
                return res;
            }

            // Tier 2: In sync databases?
            if (self.resolveSync(spec.name, spec.constraint)) |res| {
                try self.cacheResult(spec.name, res);
                return res;
            }

            // Tier 3: In AUR?
            if (try self.resolveAur(spec.name)) |res| {
                try self.cacheResult(spec.name, res);
                return res;
            }

            // Tier 4: Provider resolution
            if (self.resolveProvider(spec.name)) |res| {
                try self.cacheResult(spec.name, res);
                return res;
            }

            // Not found anywhere
            const res: Resolution = .{ .name = spec.name, .source = .unknown };
            try self.cacheResult(spec.name, res);
            return res;
        }

        /// Batch resolve with deferred AUR batching.
        /// Local + sync lookups run first (cheap), then all remaining names
        /// are flushed as a single AUR multiInfo call.
        pub fn resolveMany(self: *Self, dep_strings: []const []const u8) ![]Resolution {
            var results: std.ArrayList(Resolution) = .empty;
            errdefer results.deinit(self.allocator);
            try results.ensureTotalCapacity(self.allocator, dep_strings.len);

            // Pass 1: resolve locally + sync, defer AUR
            for (dep_strings) |dep_str| {
                const spec = parseDep(dep_str);

                if (self.cache.get(spec.name)) |cached| {
                    results.appendAssumeCapacity(cached);
                    continue;
                }

                if (self.resolveLocal(spec.name, spec.constraint)) |res| {
                    try self.cacheResult(spec.name, res);
                    results.appendAssumeCapacity(res);
                    continue;
                }

                if (self.resolveSync(spec.name, spec.constraint)) |res| {
                    try self.cacheResult(spec.name, res);
                    results.appendAssumeCapacity(res);
                    continue;
                }

                // Defer to AUR batch
                try self.pending_aur.put(self.allocator, spec.name, {});
                results.appendAssumeCapacity(.{ .name = spec.name, .source = .unknown });
            }

            // Pass 2: flush all pending AUR lookups in one batch
            if (self.pending_aur.count() > 0) {
                try self.flushPendingAur();

                // Pass 3: fill in placeholders from cache (now populated by flush)
                for (results.items) |*res| {
                    if (res.source == .unknown) {
                        if (self.cache.get(res.name)) |cached| {
                            res.* = cached;
                        }
                    }
                }
            }

            return try results.toOwnedSlice(self.allocator);
        }

        /// Invalidate specific cache entries.
        /// Called between builds in a multi-package sync workflow
        /// after repo-add makes a package available in aurpkgs.
        pub fn invalidate(self: *Self, names: []const []const u8) void {
            for (names) |name| {
                _ = self.cache.remove(name);
            }
        }

        // ── Private Resolution Tiers ────────────────────────────────────

        fn resolveLocal(self: *Self, name: []const u8, constraint: ?pacman_mod.VersionConstraint) ?Resolution {
            if (!self.pacman.isInstalled(name)) return null;

            if (constraint) |c| {
                if (!self.pacman.satisfies(name, c)) return null;
            }

            return .{
                .name = name,
                .source = .satisfied,
                .version = self.pacman.installedVersion(name),
            };
        }

        fn resolveSync(self: *Self, name: []const u8, constraint: ?pacman_mod.VersionConstraint) ?Resolution {
            const version = self.pacman.syncVersion(name) orelse return null;

            if (constraint) |c| {
                if (!pacman_mod.checkVersion(version, c)) return null;
            }

            return .{
                .name = name,
                .source = .repos,
                .version = version,
            };
        }

        fn resolveAur(self: *Self, name: []const u8) !?Resolution {
            const pkg = try self.aur_client.info(name) orelse return null;
            return .{
                .name = pkg.name,
                .source = .aur,
                .version = pkg.version,
                .aur_pkg = pkg,
            };
        }

        fn resolveProvider(self: *Self, name: []const u8) ?Resolution {
            const provider = self.pacman.findProvider(name) orelse return null;
            const source: Source = if (self.pacman.isInstalled(provider.provider_name))
                .satisfied
            else
                .repos;
            return .{
                .name = name,
                .source = source,
                .version = provider.provider_version,
                .provider = provider.provider_name,
            };
        }

        fn flushPendingAur(self: *Self) !void {
            const names = self.pending_aur.keys();
            if (names.len == 0) return;

            const packages = try self.aur_client.multiInfo(names);
            defer self.allocator.free(packages);

            for (packages) |pkg| {
                try self.cacheResult(pkg.name, .{
                    .name = pkg.name,
                    .source = .aur,
                    .version = pkg.version,
                    .aur_pkg = pkg,
                });
            }

            self.pending_aur.clearRetainingCapacity();
        }

        fn cacheResult(self: *Self, name: []const u8, res: Resolution) !void {
            try self.cache.put(self.allocator, name, res);
        }
    };
}

// ── Pure Functions ───────────────────────────────────────────────────────

/// Parse a dependency string like "pkg>=1.0" into name + constraint.
/// Handles: >=, <=, =, >, <
/// Pure function — no state, no errors.
pub fn parseDep(dep_string: []const u8) DepSpec {
    // Order matters: check two-char operators before single-char
    const operators = [_]struct { str: []const u8, op: pacman_mod.CmpOp }{
        .{ .str = ">=", .op = .ge },
        .{ .str = "<=", .op = .le },
        .{ .str = "=", .op = .eq },
        .{ .str = ">", .op = .gt },
        .{ .str = "<", .op = .lt },
    };

    for (operators) |entry| {
        if (std.mem.indexOf(u8, dep_string, entry.str)) |pos| {
            return .{
                .name = dep_string[0..pos],
                .constraint = .{
                    .op = entry.op,
                    .version = dep_string[pos + entry.str.len ..],
                },
            };
        }
    }

    return .{ .name = dep_string };
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

// ── Mock Types ──────────────────────────────────────────────────────────

const MockPacman = struct {
    installed: std.StringHashMapUnmanaged([]const u8), // name → version
    sync: std.StringHashMapUnmanaged(SyncEntry), // name → {version, db_name}
    providers: std.StringHashMapUnmanaged(pacman_mod.ProviderMatch),

    const SyncEntry = struct {
        version: []const u8,
        db_name: []const u8,
    };

    fn initEmpty() MockPacman {
        return .{
            .installed = .empty,
            .sync = .empty,
            .providers = .empty,
        };
    }

    fn deinitMock(self: *MockPacman) void {
        self.installed.deinit(testing.allocator);
        self.sync.deinit(testing.allocator);
        self.providers.deinit(testing.allocator);
    }

    fn addInstalled(self: *MockPacman, name: []const u8, version: []const u8) void {
        self.installed.put(testing.allocator, name, version) catch unreachable;
    }

    fn addSync(self: *MockPacman, name: []const u8, version: []const u8, db_name: []const u8) void {
        self.sync.put(testing.allocator, name, .{ .version = version, .db_name = db_name }) catch unreachable;
    }

    fn addProvider(self: *MockPacman, dep: []const u8, match: pacman_mod.ProviderMatch) void {
        self.providers.put(testing.allocator, dep, match) catch unreachable;
    }

    // ── Methods matching Pacman interface ────────────────────────────

    pub fn isInstalled(self: MockPacman, name: []const u8) bool {
        return self.installed.contains(name);
    }

    pub fn installedVersion(self: MockPacman, name: []const u8) ?[]const u8 {
        return self.installed.get(name);
    }

    pub fn isInSyncDb(self: MockPacman, name: []const u8) bool {
        return self.sync.contains(name);
    }

    pub fn syncDbFor(self: MockPacman, name: []const u8) ?[]const u8 {
        const entry = self.sync.get(name) orelse return null;
        return entry.db_name;
    }

    pub fn syncVersion(self: MockPacman, name: []const u8) ?[]const u8 {
        const entry = self.sync.get(name) orelse return null;
        return entry.version;
    }

    pub fn satisfies(self: MockPacman, name: []const u8, constraint: pacman_mod.VersionConstraint) bool {
        const version = self.installed.get(name) orelse return false;
        return pacman_mod.checkVersion(version, constraint);
    }

    pub fn findProvider(self: MockPacman, dep: []const u8) ?pacman_mod.ProviderMatch {
        return self.providers.get(dep);
    }
};

const MockAurClient = struct {
    packages: std.StringHashMapUnmanaged(*aur.Package),
    multi_info_call_count: usize,
    info_call_count: usize,
    should_error: bool,
    arena: std.heap.ArenaAllocator,

    fn initEmpty() MockAurClient {
        return .{
            .packages = .empty,
            .multi_info_call_count = 0,
            .info_call_count = 0,
            .should_error = false,
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }

    fn deinitMock(self: *MockAurClient) void {
        self.packages.deinit(testing.allocator);
        self.arena.deinit();
    }

    fn addPackage(self: *MockAurClient, name: []const u8, version: []const u8) void {
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
            .provides = &.{},
            .conflicts = &.{},
            .replaces = &.{},
            .groups = &.{},
            .keywords = &.{},
            .licenses = &.{},
            .comaintainers = &.{},
        };
        self.packages.put(testing.allocator, name, pkg) catch unreachable;
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
};

const TestRegistry = RegistryImpl(MockPacman, MockAurClient);

// ── parseDep Pure Tests ─────────────────────────────────────────────────

test "parseDep: bare package name" {
    const spec = parseDep("zlib");
    try testing.expectEqualStrings("zlib", spec.name);
    try testing.expect(spec.constraint == null);
}

test "parseDep: >= constraint" {
    const spec = parseDep("zlib>=1.3");
    try testing.expectEqualStrings("zlib", spec.name);
    try testing.expectEqual(pacman_mod.CmpOp.ge, spec.constraint.?.op);
    try testing.expectEqualStrings("1.3", spec.constraint.?.version);
}

test "parseDep: <= constraint" {
    const spec = parseDep("pkg<=2.0");
    try testing.expectEqualStrings("pkg", spec.name);
    try testing.expectEqual(pacman_mod.CmpOp.le, spec.constraint.?.op);
    try testing.expectEqualStrings("2.0", spec.constraint.?.version);
}

test "parseDep: = constraint" {
    const spec = parseDep("exact=1.0-1");
    try testing.expectEqualStrings("exact", spec.name);
    try testing.expectEqual(pacman_mod.CmpOp.eq, spec.constraint.?.op);
    try testing.expectEqualStrings("1.0-1", spec.constraint.?.version);
}

test "parseDep: > and < constraints" {
    const gt = parseDep("foo>3.0");
    try testing.expectEqual(pacman_mod.CmpOp.gt, gt.constraint.?.op);

    const lt = parseDep("bar<1.0");
    try testing.expectEqual(pacman_mod.CmpOp.lt, lt.constraint.?.op);
}

test "parseDep: complex package name with hyphens" {
    const spec = parseDep("lib32-mesa>=24.0");
    try testing.expectEqualStrings("lib32-mesa", spec.name);
    try testing.expectEqual(pacman_mod.CmpOp.ge, spec.constraint.?.op);
    try testing.expectEqualStrings("24.0", spec.constraint.?.version);
}

// ── resolve() Single Lookup Tests ───────────────────────────────────────

test "resolve returns Source.satisfied for installed package" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    pm.addInstalled("zlib", "1.3.1-1");

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    const res = try reg.resolve("zlib");
    try testing.expectEqual(Source.satisfied, res.source);
    try testing.expectEqualStrings("zlib", res.name);
    try testing.expectEqualStrings("1.3.1-1", res.version.?);
}

test "resolve returns Source.repos for sync db package" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    pm.addSync("glibc", "2.39-1", "core");

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    const res = try reg.resolve("glibc");
    try testing.expectEqual(Source.repos, res.source);
    try testing.expectEqualStrings("2.39-1", res.version.?);
}

test "resolve returns Source.aur for AUR-only package" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();
    ac.addPackage("yay", "12.0-1");

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    const res = try reg.resolve("yay");
    try testing.expectEqual(Source.aur, res.source);
    try testing.expect(res.aur_pkg != null);
    try testing.expectEqualStrings("12.0-1", res.version.?);
}

test "resolve returns Source.unknown when not found anywhere" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    const res = try reg.resolve("nonexistent-pkg");
    try testing.expectEqual(Source.unknown, res.source);
}

test "resolve checks version constraint for installed package" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    pm.addInstalled("pkg", "0.5");
    pm.addSync("pkg", "1.0", "extra"); // Also in sync with higher version

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    // Installed 0.5 does NOT satisfy >=1.0, but sync 1.0 does
    const res = try reg.resolve("pkg>=1.0");
    try testing.expectEqual(Source.repos, res.source);
    try testing.expectEqualStrings("1.0", res.version.?);
}

test "resolve caches results by package name" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();
    ac.addPackage("foo", "1.0");

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    _ = try reg.resolve("foo");
    _ = try reg.resolve("foo"); // second call — should hit cache

    // AUR was only queried once
    try testing.expectEqual(@as(usize, 1), ac.info_call_count);
}

test "resolve re-checks constraint on cache hit" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    pm.addInstalled("pkg", "1.0");

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    // First: resolve("pkg") → satisfied (v1.0)
    const first = try reg.resolve("pkg");
    try testing.expectEqual(Source.satisfied, first.source);

    // Second: resolve("pkg>=2.0") → cache hit, but 1.0 < 2.0
    const second = try reg.resolve("pkg>=2.0");
    try testing.expectEqual(Source.unknown, second.source);
}

// ── Cascade Priority Tests ──────────────────────────────────────────────

test "installed packages take priority over sync databases" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    pm.addInstalled("pkg", "1.0");
    pm.addSync("pkg", "1.1", "extra");

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    const res = try reg.resolve("pkg");
    try testing.expectEqual(Source.satisfied, res.source);
}

test "sync databases take priority over AUR" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    pm.addSync("pkg", "1.0", "extra");

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();
    ac.addPackage("pkg", "1.0");

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    const res = try reg.resolve("pkg");
    try testing.expectEqual(Source.repos, res.source);
    // AUR should never have been queried
    try testing.expectEqual(@as(usize, 0), ac.info_call_count);
}

// ── resolveMany() Batch Tests ───────────────────────────────────────────

test "resolveMany returns results in input order" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    pm.addInstalled("installed-pkg", "1.0");
    pm.addSync("repo-pkg", "2.0", "extra");

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();
    ac.addPackage("aur-pkg", "3.0");

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    const results = try reg.resolveMany(&.{ "installed-pkg", "aur-pkg", "repo-pkg" });
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 3), results.len);
    try testing.expectEqual(Source.satisfied, results[0].source);
    try testing.expectEqual(Source.aur, results[1].source);
    try testing.expectEqual(Source.repos, results[2].source);
}

test "resolveMany batches AUR lookups into single multiInfo call" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();
    ac.addPackage("foo", "1.0");
    ac.addPackage("bar", "2.0");
    ac.addPackage("baz", "3.0");

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    const results = try reg.resolveMany(&.{ "foo", "bar", "baz" });
    defer testing.allocator.free(results);

    // All resolved as AUR
    for (results) |res| {
        try testing.expectEqual(Source.aur, res.source);
    }

    // Only ONE multiInfo call (not 3 individual info calls)
    try testing.expectEqual(@as(usize, 1), ac.multi_info_call_count);
    try testing.expectEqual(@as(usize, 0), ac.info_call_count);
}

test "resolveMany handles mix of sources" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    pm.addInstalled("local-pkg", "1.0");
    pm.addSync("sync-pkg", "2.0", "core");

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();
    ac.addPackage("aur-pkg", "3.0");

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    const results = try reg.resolveMany(&.{ "local-pkg", "sync-pkg", "aur-pkg", "missing" });
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 4), results.len);
    try testing.expectEqual(Source.satisfied, results[0].source);
    try testing.expectEqual(Source.repos, results[1].source);
    try testing.expectEqual(Source.aur, results[2].source);
    try testing.expectEqual(Source.unknown, results[3].source);
}

// ── Cache Invalidation Tests ────────────────────────────────────────────

test "invalidate removes specific packages from cache" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();
    ac.addPackage("pkg-a", "1.0");
    ac.addPackage("pkg-b", "2.0");

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    _ = try reg.resolve("pkg-a");
    _ = try reg.resolve("pkg-b");
    try testing.expectEqual(@as(usize, 2), ac.info_call_count);

    // Invalidate only pkg-a
    reg.invalidate(&.{"pkg-a"});

    // pkg-a requires re-query, pkg-b is still cached
    _ = try reg.resolve("pkg-a");
    _ = try reg.resolve("pkg-b");
    try testing.expectEqual(@as(usize, 3), ac.info_call_count); // only 1 more
}

// ── Error Propagation Tests ─────────────────────────────────────────────

test "resolve propagates NetworkError from AUR client" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();
    ac.should_error = true;

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    try testing.expectError(error.NetworkError, reg.resolve("any-pkg"));
}

test "resolve does not error on package not found" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    const res = try reg.resolve("nonexistent");
    try testing.expectEqual(Source.unknown, res.source);
}

// ── Provider Resolution Tests ───────────────────────────────────────────

test "resolve falls through to provider when direct lookups fail" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    pm.addInstalled("jre-openjdk", "21.0.1");
    pm.addProvider("java-runtime", .{
        .provider_name = "jre-openjdk",
        .provider_version = "21.0.1",
        .db_name = "extra",
    });

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    const res = try reg.resolve("java-runtime");
    try testing.expectEqual(Source.satisfied, res.source);
    try testing.expectEqualStrings("java-runtime", res.name);
    try testing.expectEqualStrings("jre-openjdk", res.provider.?);
}
