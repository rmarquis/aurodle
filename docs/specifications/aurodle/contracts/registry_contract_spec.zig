// Contract specification for registry.zig — Unified Package Resolution Hub
//
// Verifies the formal contract for the multi-source package registry.
// The registry implements a cascade: installed → sync DBs → AUR,
// with deferred AUR batching for efficiency.
//
// Architecture: docs/architecture/class_registry.md
// Module: registry.Registry
//
// All tests use mock Pacman and AUR client injection.

const std = @import("std");
const testing = std.testing;

// TODO: Replace with real import when implementation exists
// const registry = @import("../../../../src/registry.zig");

// ============================================================================
// Lifecycle Contracts
// ============================================================================

test "Registry.init accepts allocator, pacman, and aur client" {
    // Contract: init(allocator, *Pacman, *aur.Client) returns a Registry.
    // The registry borrows references to pacman and aur — it does not
    // own them and must not deinit them.
    //
    // var reg = registry.Registry.init(testing.allocator, &pm, &aur_client);
    // defer reg.deinit();
}

test "Registry.deinit releases only its own allocations" {
    // Contract: deinit frees the internal cache but does not touch
    // the borrowed pacman or aur client references.
}

// ============================================================================
// resolve() Single Lookup Contracts
// ============================================================================

test "resolve returns Source.satisfied for installed package" {
    // Contract: resolve(name) returns Source.satisfied when the package
    // is installed locally. This is the first tier of the cascade.
    //
    // // Mock: pacman.isInstalled("pkg") = true
    // const res = try reg.resolve("pkg");
    // try testing.expectEqual(registry.Source.satisfied, res.source);
}

test "resolve returns Source.repos for official repo package" {
    // Contract: resolve(name) returns Source.repos when the package
    // is not installed but exists in an official sync database.
    //
    // // Mock: pacman.isInstalled("pkg") = false, isInSyncDb("pkg") = true
    // const res = try reg.resolve("pkg");
    // try testing.expectEqual(registry.Source.repos, res.source);
}

test "resolve returns Source.aur for AUR-only package" {
    // Contract: resolve(name) returns Source.aur when the package is
    // not installed, not in sync DBs, but found in AUR.
    //
    // // Mock: pacman returns false for both, aur.info("pkg") returns Package
    // const res = try reg.resolve("pkg");
    // try testing.expectEqual(registry.Source.aur, res.source);
    // try testing.expect(res.aur_pkg != null);
}

test "resolve returns Source.unknown when package not found anywhere" {
    // Contract: resolve(name) returns Source.unknown (not an error)
    // when the package doesn't exist in any source. The solver
    // decides whether to error on this.
    //
    // const res = try reg.resolve("nonexistent-pkg");
    // try testing.expectEqual(registry.Source.unknown, res.source);
}

test "resolve populates version field from the found source" {
    // Contract: Resolution.version is set to the version string
    // from whichever source the package was found in.
    //
    // const res = try reg.resolve("installed-pkg");
    // try testing.expect(res.version != null);
    // try testing.expect(res.version.?.len > 0);
}

test "resolve parses versioned dependency strings" {
    // Contract: resolve("pkg>=1.0") parses the constraint and checks
    // if the installed/available version satisfies it. A package may
    // be installed but not satisfy the constraint.
    //
    // // Mock: pacman.installedVersion("pkg") = "0.5"
    // const res = try reg.resolve("pkg>=1.0");
    // // Installed version 0.5 does NOT satisfy >=1.0, so keep looking
    // try testing.expect(res.source != .satisfied);
}

test "resolve caches results by package name" {
    // Contract: After resolving a package, subsequent resolve calls
    // with the same name return the cached result without querying
    // pacman or AUR again.
    //
    // const first = try reg.resolve("cached-pkg");
    // const second = try reg.resolve("cached-pkg");
    // try testing.expectEqual(first.source, second.source);
}

test "resolve re-checks constraint on cache hit" {
    // Contract: Cache is keyed by name, not by dep string. If "pkg"
    // is cached as version 1.0, and we resolve("pkg>=2.0"), the cache
    // hit must re-check the constraint against the cached version.
    //
    // // First: resolve("pkg") → satisfied (v1.0 installed)
    // // Second: resolve("pkg>=2.0") → cache hit, but 1.0 < 2.0
    // // Should NOT return .satisfied for the second call
}

// ============================================================================
// resolveMany() Batch Contracts
// ============================================================================

test "resolveMany resolves all names in a single call" {
    // Contract: resolveMany(names) returns a Resolution for each name.
    // Result slice length equals input length.
    //
    // const results = try reg.resolveMany(&.{ "pkg-a", "pkg-b", "pkg-c" });
    // try testing.expectEqual(@as(usize, 3), results.len);
}

test "resolveMany batches AUR lookups into single multiInfo call" {
    // Contract: For packages not found in installed or sync DBs,
    // resolveMany collects all pending names and issues a single
    // aur.multiInfo() call (not N individual info() calls).
    //
    // // Mock: all packages are AUR-only
    // // Verify: aur.multiInfo called exactly once with all names
    // _ = try reg.resolveMany(&.{ "aur-a", "aur-b", "aur-c" });
}

test "resolveMany returns results in input order" {
    // Contract: The i-th element of the result corresponds to the
    // i-th element of the input names, regardless of which source
    // each resolution came from.
    //
    // const results = try reg.resolveMany(&.{ "installed-pkg", "aur-pkg", "repo-pkg" });
    // try testing.expectEqual(registry.Source.satisfied, results[0].source);
    // try testing.expectEqual(registry.Source.aur, results[1].source);
    // try testing.expectEqual(registry.Source.repos, results[2].source);
}

// ============================================================================
// Cache Invalidation Contracts
// ============================================================================

test "invalidate removes specific packages from cache" {
    // Contract: invalidate(names) removes the named packages from the
    // internal cache. Subsequent resolve() calls will re-query.
    // Used after a successful build to re-discover the package in aurpkgs.
    //
    // _ = try reg.resolve("just-built-pkg"); // cached as AUR
    // reg.invalidate(&.{"just-built-pkg"});
    // // Next resolve should re-query and find it in aurpkgs sync DB
}

test "invalidate does not affect other cached entries" {
    // Contract: Invalidation is surgical — only the named packages
    // are removed. Other cache entries remain valid.
    //
    // _ = try reg.resolve("pkg-a");
    // _ = try reg.resolve("pkg-b");
    // reg.invalidate(&.{"pkg-a"});
    // // pkg-b is still cached
}

// ============================================================================
// Error Propagation Contracts
// ============================================================================

test "resolve propagates NetworkError from AUR client" {
    // Contract: Infrastructure errors from the AUR client (NetworkError,
    // RateLimited) propagate through resolve(). These are not "not found" —
    // they indicate a real failure.
    //
    // // Mock: aur.info returns error.NetworkError
    // const result = reg.resolve("any-pkg");
    // try testing.expectError(error.NetworkError, result);
}

test "resolve does not error on package not found" {
    // Contract: "Not found" is Source.unknown, not an error.
    // This allows the solver to collect all unknowns and report them
    // together instead of failing on the first one.
    //
    // const res = try reg.resolve("nonexistent");
    // try testing.expectEqual(registry.Source.unknown, res.source);
}

// ============================================================================
// Cascade Priority Contracts
// ============================================================================

test "installed packages take priority over sync databases" {
    // Contract: If a package is both installed AND in sync DBs,
    // resolve returns Source.satisfied (not Source.repos).
    // The cascade short-circuits at the first match.
}

test "sync databases take priority over AUR" {
    // Contract: If a package exists in both official repos and AUR,
    // resolve returns Source.repos. Official repos are always preferred.
    // This prevents AUR packages from shadowing official ones.
}

test "official repos take priority over aurpkgs" {
    // Contract: When a package exists in both an official repo and
    // the local aurpkgs repo, the official repo wins.
}
