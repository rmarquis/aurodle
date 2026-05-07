const std = @import("std");
const testing = std.testing;

const registry = @import("../registry.zig");
const RegistryImpl = registry.RegistryImpl;
const Source = registry.Source;
const Resolution = registry.Resolution;

const pacman_mod = @import("../pacman.zig");
const color = @import("../color.zig");

const mocks_mod = @import("mocks.zig");
const MockPacman = mocks_mod.MockPacman;
const MockAurClient = mocks_mod.MockAurClient;

const TestRegistry = RegistryImpl(MockPacman, MockAurClient);

// ── resolve() Single Lookup Tests ───────────────────────────────────────

test "resolve returns Source.satisfied_aur for installed foreign package" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    pm.addInstalled("zlib", "1.3.1-1");

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    const res = try reg.resolve("zlib");
    try testing.expectEqual(Source.satisfied_aur, res.source);
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
    try testing.expectEqual(Source.satisfied_aur, first.source);

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
    try testing.expectEqual(Source.satisfied_repos, res.source);
}

test "installed package in aurpkgs is classified as satisfied_aur" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    pm.addInstalled("pacaur", "4.8.6-2");
    pm.addSync("pacaur", "4.8.6-2", "aurpkgs");

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    const res = try reg.resolve("pacaur");
    try testing.expectEqual(Source.satisfied_aur, res.source);
}

test "aurpkgs-only package is not found by resolveSync" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    pm.addSync("auracle", "1.0", "aurpkgs");

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();
    ac.addPackage("auracle", "1.0");

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    // Should skip aurpkgs in resolveSync and find it via AUR instead
    const res = try reg.resolve("auracle");
    try testing.expectEqual(Source.aur, res.source);
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
    try testing.expectEqual(Source.satisfied_aur, results[0].source);
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
    try testing.expectEqual(Source.satisfied_aur, results[0].source);
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

test "resolve falls through to pacman provider when direct lookups fail" {
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
    try testing.expectEqual(Source.satisfied_aur, res.source);
    try testing.expectEqualStrings("java-runtime", res.name);
    try testing.expectEqualStrings("jre-openjdk", res.provider.?);
}

test "resolve returns Source.repo_aur for uninstalled provider in aurpkgs" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    // auracle-git is in aurpkgs (not installed), provides "auracle"
    pm.addProvider("auracle", .{
        .provider_name = "auracle-git",
        .provider_version = "r427-1",
        .db_name = "aurpkgs",
    });

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    const res = try reg.resolve("auracle");
    try testing.expectEqual(Source.repo_aur, res.source);
    try testing.expectEqualStrings("auracle", res.name);
    try testing.expectEqualStrings("auracle-git", res.provider.?);
}

test "resolve finds AUR provider when package not found by name" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();
    // "auracle-git" provides "auracle"
    ac.addPackageWithProvides("auracle-git", "r427-1", &.{"auracle"});

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    const res = try reg.resolve("auracle");
    try testing.expectEqual(Source.aur, res.source);
    try testing.expectEqualStrings("auracle-git", res.name);
    try testing.expectEqualStrings("r427-1", res.version.?);
    try testing.expect(res.aur_pkg != null);
    try testing.expectEqualStrings("auracle-git", res.provider.?);
}

test "resolve prefers pacman provider over AUR provider" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    pm.addInstalled("auracle-local", "1.0");
    pm.addProvider("auracle", .{
        .provider_name = "auracle-local",
        .provider_version = "1.0",
        .db_name = "extra",
    });

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();
    ac.addPackageWithProvides("auracle-git", "r427-1", &.{"auracle"});

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    // Pacman provider (Tier 3) should win over AUR provider (Tier 5)
    const res = try reg.resolve("auracle");
    try testing.expectEqual(Source.satisfied_aur, res.source);
    try testing.expectEqualStrings("auracle-local", res.provider.?);
    // AUR search should not have been called
    try testing.expectEqual(@as(usize, 0), ac.search_call_count);
}

test "resolve returns unknown when no provider exists anywhere" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();

    const res = try reg.resolve("totally-missing");
    try testing.expectEqual(Source.unknown, res.source);
    // Should have tried AUR search as last resort
    try testing.expectEqual(@as(usize, 1), ac.search_call_count);
}

// ── Provider Selection Tests ────────────────────────────────────────────

fn testChooserSecond(_: []const u8, candidates: []const registry.ProviderCandidate, _: color.Style) ?usize {
    if (candidates.len >= 2) return 1;
    return 0;
}

fn testChooserFirst(_: []const u8, _: []const registry.ProviderCandidate, _: color.Style) ?usize {
    return 0;
}

var test_chooser_call_count: usize = 0;

fn testChooserCounting(_: []const u8, _: []const registry.ProviderCandidate, _: color.Style) ?usize {
    test_chooser_call_count += 1;
    return 0;
}

test "single provider does not invoke chooser" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    pm.addProvider("java-runtime", .{
        .provider_name = "jre-openjdk",
        .provider_version = "21.0.1",
        .db_name = "extra",
    });

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();

    test_chooser_call_count = 0;
    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();
    reg.provider_chooser = &testChooserCounting;

    const res = try reg.resolve("java-runtime");
    try testing.expectEqualStrings("jre-openjdk", res.provider.?);
    try testing.expectEqual(@as(usize, 0), test_chooser_call_count);
}

test "multiple providers invoke chooser and select correct one" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    const providers = [_]pacman_mod.ProviderMatch{
        .{ .provider_name = "jdk-openjdk", .provider_version = "21.0.1", .db_name = "extra" },
        .{ .provider_name = "jre-openjdk", .provider_version = "21.0.1", .db_name = "extra" },
    };
    pm.addProviders("java-runtime", &providers);

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();
    reg.provider_chooser = &testChooserSecond;

    const res = try reg.resolve("java-runtime");
    try testing.expectEqualStrings("jre-openjdk", res.provider.?);
    // Should have recorded the selection
    try testing.expectEqual(@as(usize, 1), reg.provider_selections.items.len);
    try testing.expectEqualStrings("java-runtime", reg.provider_selections.items[0].dep_name);
    try testing.expectEqualStrings("jre-openjdk", reg.provider_selections.items[0].chosen);
}

test "installed provider auto-selected without chooser" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    pm.addInstalled("jre-openjdk", "21.0.1");
    const providers = [_]pacman_mod.ProviderMatch{
        .{ .provider_name = "jdk-openjdk", .provider_version = "21.0.1", .db_name = "extra" },
        .{ .provider_name = "jre-openjdk", .provider_version = "21.0.1", .db_name = "extra" },
        .{ .provider_name = "jdk17-openjdk", .provider_version = "17.0.9", .db_name = "extra" },
    };
    pm.addProviders("java-runtime", &providers);

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();

    test_chooser_call_count = 0;
    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();
    reg.provider_chooser = &testChooserCounting;

    const res = try reg.resolve("java-runtime");
    try testing.expectEqualStrings("jre-openjdk", res.provider.?);
    try testing.expectEqual(Source.satisfied_aur, res.source);
    // Chooser should NOT have been called (auto-selected installed)
    try testing.expectEqual(@as(usize, 0), test_chooser_call_count);
}

test "provider choice is cached across resolve calls" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    const providers = [_]pacman_mod.ProviderMatch{
        .{ .provider_name = "jdk-openjdk", .provider_version = "21.0.1", .db_name = "extra" },
        .{ .provider_name = "jre-openjdk", .provider_version = "21.0.1", .db_name = "extra" },
    };
    pm.addProviders("java-runtime", &providers);

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();

    test_chooser_call_count = 0;
    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();
    reg.provider_chooser = &testChooserCounting;

    _ = try reg.resolve("java-runtime");
    // Invalidate the main cache to force re-resolution but keep provider_choices
    reg.invalidate(&.{"java-runtime"});
    _ = try reg.resolve("java-runtime");

    // Chooser called only once (second time used cached choice)
    try testing.expectEqual(@as(usize, 1), test_chooser_call_count);
}

test "multiple providers without chooser uses first" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();
    const providers = [_]pacman_mod.ProviderMatch{
        .{ .provider_name = "jdk-openjdk", .provider_version = "21.0.1", .db_name = "extra" },
        .{ .provider_name = "jre-openjdk", .provider_version = "21.0.1", .db_name = "extra" },
    };
    pm.addProviders("java-runtime", &providers);

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();

    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();
    // No chooser set — should auto-pick first

    const res = try reg.resolve("java-runtime");
    try testing.expectEqualStrings("jdk-openjdk", res.provider.?);
}

test "AUR multi-provider invokes chooser" {
    var pm = MockPacman.initEmpty();
    defer pm.deinitMock();

    var ac = MockAurClient.initEmpty();
    defer ac.deinitMock();
    ac.addPackageWithProvides("auracle-git", "r427-1", &.{"auracle"});
    ac.addPackageWithProvides("auracle-bin", "r400-1", &.{"auracle"});

    test_chooser_call_count = 0;
    var reg = TestRegistry.init(testing.allocator, &pm, &ac);
    defer reg.deinit();
    reg.provider_chooser = &testChooserCounting;

    const res = try reg.resolve("auracle");
    try testing.expectEqual(Source.aur, res.source);
    // Chooser was called for multiple AUR providers
    try testing.expectEqual(@as(usize, 1), test_chooser_call_count);
    // Result is one of the two providers
    try testing.expect(
        std.mem.eql(u8, res.name, "auracle-git") or std.mem.eql(u8, res.name, "auracle-bin"),
    );
    // Selection was recorded
    try testing.expectEqual(@as(usize, 1), reg.provider_selections.items.len);
    try testing.expectEqualStrings("auracle", reg.provider_selections.items[0].dep_name);
}
