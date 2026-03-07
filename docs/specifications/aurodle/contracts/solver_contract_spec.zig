// Contract specification for solver.zig — Dependency Resolution + Topological Sort
//
// Verifies the formal contract for the three-phase dependency resolver:
//   Phase 1: Discovery (DFS with cycle detection)
//   Phase 2: Topological Sort (Kahn's algorithm)
//   Phase 3: Plan Assembly (pkgbase dedup, classification)
//
// Architecture: docs/architecture/class_solver.md
// Module: solver.Solver
//
// All tests use mock Registry injection.

const std = @import("std");
const testing = std.testing;

// TODO: Replace with real import when implementation exists
// const solver = @import("../../../../src/solver.zig");

// ============================================================================
// Lifecycle Contracts
// ============================================================================

test "Solver.init accepts allocator and registry reference" {
    // Contract: init(allocator, *Registry) returns a Solver.
    // The solver borrows the registry — does not own it.
    //
    // var s = solver.Solver.init(testing.allocator, &mock_registry);
    // defer s.deinit();
}

// ============================================================================
// resolve() Core Contracts
// ============================================================================

test "resolve returns BuildPlan for a single target with no dependencies" {
    // Contract: resolve(["pkg"]) returns a BuildPlan with:
    //   - build_order containing exactly one entry (the target)
    //   - build_order[0].is_target == true
    //   - repo_deps is empty
    //
    // Mock: registry.resolve("pkg") → Source.aur, no depends
    //
    // const plan = try s.resolve(&.{"pkg"});
    // try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    // try testing.expect(plan.build_order[0].is_target);
    // try testing.expectEqual(@as(usize, 0), plan.repo_deps.len);
}

test "resolve orders dependencies before dependents" {
    // Contract: For a chain A → B → C (A depends on B, B depends on C),
    // build_order must be [C, B, A]. Dependencies are built first.
    //
    // Mock: A.depends = ["B"], B.depends = ["C"], C.depends = []
    //
    // const plan = try s.resolve(&.{"A"});
    // try testing.expectEqualStrings("C", plan.build_order[0].name);
    // try testing.expectEqualStrings("B", plan.build_order[1].name);
    // try testing.expectEqualStrings("A", plan.build_order[2].name);
}

test "resolve classifies repo dependencies separately" {
    // Contract: Dependencies found in official repos appear in repo_deps,
    // NOT in build_order. Only AUR packages need building.
    //
    // Mock: A.depends = ["repo-pkg"], registry classifies "repo-pkg" as Source.repos
    //
    // const plan = try s.resolve(&.{"A"});
    // // repo-pkg should be in repo_deps, not build_order
    // try testing.expect(plan.repo_deps.len > 0);
    // for (plan.build_order) |entry| {
    //     try testing.expect(!std.mem.eql(u8, entry.name, "repo-pkg"));
    // }
}

test "resolve skips satisfied dependencies" {
    // Contract: Dependencies already installed (Source.satisfied_repo or
    // Source.satisfied_aur) do not appear in build_order or repo_deps.
    // They appear in all_deps with their satisfied source for display.
    //
    // Mock: A.depends = ["installed-pkg"], registry classifies as .satisfied_repo
    //
    // const plan = try s.resolve(&.{"A"});
    // for (plan.build_order) |entry| {
    //     try testing.expect(!std.mem.eql(u8, entry.name, "installed-pkg"));
    // }
}

test "resolve does not recurse into repo dependencies" {
    // Contract: When a dependency is classified as Source.repos, the
    // solver does NOT fetch its dependencies from AUR. Repo package
    // dependencies are handled by pacman during installation.
    //
    // Mock: A → repo-pkg (Source.repos), repo-pkg depends on X
    // The resolver should NOT attempt to resolve X.
}

test "resolve marks target packages with is_target=true" {
    // Contract: Packages explicitly passed as targets have
    // BuildEntry.is_target == true. Transitive dependencies have false.
    //
    // const plan = try s.resolve(&.{ "target-a", "target-b" });
    // for (plan.build_order) |entry| {
    //     if (std.mem.eql(u8, entry.name, "target-a") or
    //         std.mem.eql(u8, entry.name, "target-b"))
    //     {
    //         try testing.expect(entry.is_target);
    //     }
    // }
}

// ============================================================================
// Error Contracts
// ============================================================================

test "resolve returns CircularDependency error on cycles" {
    // Contract: When a circular dependency is detected (A → B → A),
    // resolve returns error.CircularDependency. Detection happens
    // during Phase 2 (Kahn's algorithm: remaining nodes with edges).
    //
    // Mock: A.depends = ["B"], B.depends = ["A"]
    //
    // const result = s.resolve(&.{"A"});
    // try testing.expectError(error.CircularDependency, result);
}

test "resolve returns UnresolvableDependency for unknown packages" {
    // Contract: When a dependency is classified as Source.unknown,
    // resolve fails immediately with UnresolvableDependency.
    // Fail-fast during Phase 1 discovery.
    //
    // Mock: A.depends = ["unknown-pkg"], registry returns .unknown
    //
    // const result = s.resolve(&.{"A"});
    // try testing.expectError(error.UnresolvableDependency, result);
}

// ============================================================================
// pkgbase Deduplication Contracts
// ============================================================================

test "resolve deduplicates packages sharing the same pkgbase" {
    // Contract: Split packages (e.g., python-attrs and python-attrs-tests)
    // share a pkgbase. The build_order should contain only one entry
    // per pkgbase, not one per pkgname.
    //
    // Mock: "sub-a" pkgbase="parent", "sub-b" pkgbase="parent"
    //
    // const plan = try s.resolve(&.{ "sub-a", "sub-b" });
    // // build_order should have exactly 1 entry for pkgbase "parent"
    // var parent_count: usize = 0;
    // for (plan.build_order) |entry| {
    //     if (std.mem.eql(u8, entry.pkgbase, "parent")) parent_count += 1;
    // }
    // try testing.expectEqual(@as(usize, 1), parent_count);
}

test "resolve populates pkgbase field from AUR metadata" {
    // Contract: Each BuildEntry has pkgbase populated from the
    // AUR Package metadata. This is used for git clone URLs.
    //
    // const plan = try s.resolve(&.{"any-aur-pkg"});
    // for (plan.build_order) |entry| {
    //     try testing.expect(entry.pkgbase.len > 0);
    // }
}

// ============================================================================
// BuildPlan Structure Contracts
// ============================================================================

test "BuildPlan.build_order contains only AUR packages" {
    // Contract: Every entry in build_order has source == .aur.
    // Repo packages and satisfied dependencies are excluded.
}

test "BuildPlan.all_deps contains every discovered dependency" {
    // Contract: all_deps includes ALL dependencies from the traversal,
    // regardless of source. Used for the buildorder display command.
    //
    // const plan = try s.resolve(&.{"A"});
    // // all_deps should include repo deps, satisfied deps, and AUR deps
    // try testing.expect(plan.all_deps.len >= plan.build_order.len);
}

test "DependencyEntry.depth reflects distance from targets" {
    // Contract: Target packages have depth 0. Direct dependencies
    // have depth 1. Transitive dependencies have depth 2+.
    //
    // Mock: target → dep1 → dep2
    //
    // const plan = try s.resolve(&.{"target"});
    // for (plan.all_deps) |dep| {
    //     if (std.mem.eql(u8, dep.name, "target")) {
    //         try testing.expectEqual(@as(u32, 0), dep.depth);
    //     }
    // }
}

// ============================================================================
// Multiple Target Contracts
// ============================================================================

test "resolve handles multiple targets with shared dependencies" {
    // Contract: When targets A and B both depend on C, C appears
    // once in build_order (not duplicated).
    //
    // Mock: A → C, B → C
    //
    // const plan = try s.resolve(&.{ "A", "B" });
    // var c_count: usize = 0;
    // for (plan.build_order) |entry| {
    //     if (std.mem.eql(u8, entry.name, "C")) c_count += 1;
    // }
    // try testing.expectEqual(@as(usize, 1), c_count);
}

test "resolve handles diamond dependency patterns" {
    // Contract: Diamond: A → B, A → C, B → D, C → D.
    // D appears once, built before B and C, which are built before A.
    //
    // const plan = try s.resolve(&.{"A"});
    // // D must come before B and C in build_order
    // // B and C must come before A
}

test "resolve handles makedepends in addition to depends" {
    // Contract: Both depends and makedepends are traversed during
    // discovery. Both contribute to build ordering constraints.
    //
    // Mock: A.depends = ["B"], A.makedepends = ["C"]
    // Both B and C appear before A in build_order.
}
