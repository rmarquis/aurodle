const std = @import("std");
const testing = std.testing;
const solver_mod = @import("../solver.zig");
const registry_mod = @import("../registry.zig");
const mocks_mod = @import("mocks.zig");

const SolverImpl = solver_mod.SolverImpl;
const BuildPlan = solver_mod.BuildPlan;
const BuildEntry = solver_mod.BuildEntry;
const Conflict = solver_mod.Conflict;
const MockRegistry = mocks_mod.MockRegistry;
const MockInstalledSet = mocks_mod.MockInstalledSet;

const TestSolver = SolverImpl(MockRegistry);

// ── Lifecycle Tests ──────────────────────────────────────────────────────

test "Solver.init accepts allocator and registry reference" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();
}

// ── resolve() Core Tests ─────────────────────────────────────────────────

test "resolve returns BuildPlan for a single target with no dependencies" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("pkg", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"pkg"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expect(plan.build_order[0].is_target);
    try testing.expectEqualStrings("pkg", plan.build_order[0].name);
    try testing.expectEqual(@as(usize, 0), plan.repo_deps.len);
}

test "resolve orders dependencies before dependents" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("A", &.{"B"}, &.{});
    mock.addAurPackage("B", &.{"C"}, &.{});
    mock.addAurPackage("C", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"A"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), plan.build_order.len);
    try testing.expectEqualStrings("C", plan.build_order[0].name);
    try testing.expectEqualStrings("B", plan.build_order[1].name);
    try testing.expectEqualStrings("A", plan.build_order[2].name);
}

test "resolve classifies repo dependencies separately" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("A", &.{"repo-pkg"}, &.{});
    mock.addRepoPackage("repo-pkg", "1.0");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"A"});
    defer plan.deinit(testing.allocator);

    // repo-pkg in repo_deps, not build_order
    try testing.expectEqual(@as(usize, 1), plan.repo_deps.len);
    try testing.expectEqualStrings("repo-pkg", plan.repo_deps[0]);

    for (plan.build_order) |entry| {
        try testing.expect(!std.mem.eql(u8, entry.name, "repo-pkg"));
    }
}

test "resolve skips satisfied dependencies" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("A", &.{"installed-pkg"}, &.{});
    mock.addSatisfied("installed-pkg", "2.0");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"A"});
    defer plan.deinit(testing.allocator);

    // installed-pkg should not be in build_order or repo_deps
    for (plan.build_order) |entry| {
        try testing.expect(!std.mem.eql(u8, entry.name, "installed-pkg"));
    }
    try testing.expectEqual(@as(usize, 0), plan.repo_deps.len);

    // But it should be in all_deps
    var found = false;
    for (plan.all_deps) |dep| {
        if (std.mem.eql(u8, dep.name, "installed-pkg")) {
            try testing.expectEqual(registry_mod.Source.satisfied_aur, dep.source);
            found = true;
        }
    }
    try testing.expect(found);
}

test "resolve classifies repo targets separately from repo deps" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // expac is installed from official repos — target
    mock.addSatisfiedRepo("expac", "10.4");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"expac"});
    defer plan.deinit(testing.allocator);

    // Should be in repo_targets, not repo_deps or build_order
    try testing.expectEqual(@as(usize, 0), plan.build_order.len);
    try testing.expectEqual(@as(usize, 0), plan.repo_deps.len);
    try testing.expectEqual(@as(usize, 1), plan.repo_targets.len);
    try testing.expectEqualStrings("expac", plan.repo_targets[0]);
}

test "resolve classifies uninstalled repo targets into repo_targets" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // expac is in official repos but not installed — target
    mock.addRepoPackage("expac", "10.4");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"expac"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), plan.build_order.len);
    try testing.expectEqual(@as(usize, 0), plan.repo_deps.len);
    try testing.expectEqual(@as(usize, 1), plan.repo_targets.len);
    try testing.expectEqualStrings("expac", plan.repo_targets[0]);
}

test "resolve separates repo targets from repo deps in mixed plan" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // AUR target depends on repo dep; user also targets a repo package
    mock.addAurPackage("aurpkg", &.{"zlib"}, &.{});
    mock.addRepoPackage("zlib", "1.3");
    mock.addSatisfiedRepo("expac", "10.4");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{ "aurpkg", "expac" });
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expectEqual(@as(usize, 1), plan.repo_deps.len);
    try testing.expectEqualStrings("zlib", plan.repo_deps[0]);
    try testing.expectEqual(@as(usize, 1), plan.repo_targets.len);
    try testing.expectEqualStrings("expac", plan.repo_targets[0]);
}

test "resolve does not recurse into repo dependencies" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // foo (AUR) depends on zlib (repos)
    // If solver tried to recurse into zlib, it would look for zlib's deps
    // which don't exist in mock → would error. But it shouldn't recurse.
    mock.addAurPackage("foo", &.{"zlib"}, &.{});
    mock.addRepoPackage("zlib", "1.3.1");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"foo"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expectEqualStrings("foo", plan.build_order[0].name);
}

test "resolve marks target packages with is_target=true" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("target-a", &.{"dep"}, &.{});
    mock.addAurPackage("target-b", &.{"dep"}, &.{});
    mock.addAurPackage("dep", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{ "target-a", "target-b" });
    defer plan.deinit(testing.allocator);

    for (plan.build_order) |entry| {
        if (std.mem.eql(u8, entry.name, "target-a") or
            std.mem.eql(u8, entry.name, "target-b"))
        {
            try testing.expect(entry.is_target);
        } else {
            try testing.expect(!entry.is_target);
        }
    }
}

// ── Error Tests ──────────────────────────────────────────────────────────

test "resolve returns CircularDependency error on cycles" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("A", &.{"B"}, &.{});
    mock.addAurPackage("B", &.{"A"}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    try testing.expectError(error.CircularDependency, s.resolve(&.{"A"}));
}

test "resolve returns UnresolvableDependency for unknown packages" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("A", &.{"unknown-pkg"}, &.{});
    // "unknown-pkg" not registered → resolves as .unknown

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    try testing.expectError(error.UnresolvableDependency, s.resolve(&.{"A"}));
}

// ── pkgbase Deduplication Tests ──────────────────────────────────────────

test "resolve deduplicates packages sharing the same pkgbase" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackageWithBase("sub-a", "parent", &.{}, &.{});
    mock.addAurPackageWithBase("sub-b", "parent", &.{}, &.{});
    mock.addAurPackage("foo", &.{ "sub-a", "sub-b" }, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"foo"});
    defer plan.deinit(testing.allocator);

    var parent_count: usize = 0;
    for (plan.build_order) |entry| {
        if (std.mem.eql(u8, entry.pkgbase, "parent")) parent_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), parent_count);
}

test "resolve populates pkgbase field from AUR metadata" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackageWithBase("pkg-name", "pkg-base", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"pkg-name"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expectEqualStrings("pkg-base", plan.build_order[0].pkgbase);
}

// ── BuildPlan Structure Tests ────────────────────────────────────────────

test "BuildPlan.build_order contains only AUR packages" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("aur-pkg", &.{"repo-pkg"}, &.{});
    mock.addRepoPackage("repo-pkg", "1.0");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"aur-pkg"});
    defer plan.deinit(testing.allocator);

    for (plan.build_order) |entry| {
        // Find this entry in all_deps to verify source
        for (plan.all_deps) |dep| {
            if (std.mem.eql(u8, dep.name, entry.name)) {
                try testing.expectEqual(registry_mod.Source.aur, dep.source);
            }
        }
    }
}

test "BuildPlan.all_deps contains every discovered dependency" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("target", &.{ "aur-dep", "repo-dep", "satisfied-dep" }, &.{});
    mock.addAurPackage("aur-dep", &.{}, &.{});
    mock.addRepoPackage("repo-dep", "1.0");
    mock.addSatisfied("satisfied-dep", "2.0");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"target"});
    defer plan.deinit(testing.allocator);

    // all_deps should have target + 3 deps = 4
    try testing.expectEqual(@as(usize, 4), plan.all_deps.len);
    try testing.expect(plan.all_deps.len >= plan.build_order.len);
}

test "DependencyEntry.depth reflects distance from targets" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("target", &.{"dep1"}, &.{});
    mock.addAurPackage("dep1", &.{"dep2"}, &.{});
    mock.addAurPackage("dep2", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"target"});
    defer plan.deinit(testing.allocator);

    for (plan.all_deps) |dep| {
        if (std.mem.eql(u8, dep.name, "target")) {
            try testing.expectEqual(@as(u32, 0), dep.depth);
        } else if (std.mem.eql(u8, dep.name, "dep1")) {
            try testing.expectEqual(@as(u32, 1), dep.depth);
        } else if (std.mem.eql(u8, dep.name, "dep2")) {
            try testing.expectEqual(@as(u32, 2), dep.depth);
        }
    }
}

// ── Multiple Target Tests ────────────────────────────────────────────────

test "resolve handles multiple targets with shared dependencies" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("A", &.{"C"}, &.{});
    mock.addAurPackage("B", &.{"C"}, &.{});
    mock.addAurPackage("C", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{ "A", "B" });
    defer plan.deinit(testing.allocator);

    // C appears once in build_order
    var c_count: usize = 0;
    for (plan.build_order) |entry| {
        if (std.mem.eql(u8, entry.name, "C")) c_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), c_count);

    // C must come before A and B
    var c_idx: ?usize = null;
    var a_idx: ?usize = null;
    var b_idx: ?usize = null;
    for (plan.build_order, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, "C")) c_idx = i;
        if (std.mem.eql(u8, entry.name, "A")) a_idx = i;
        if (std.mem.eql(u8, entry.name, "B")) b_idx = i;
    }
    try testing.expect(c_idx.? < a_idx.?);
    try testing.expect(c_idx.? < b_idx.?);
}

test "resolve handles diamond dependency patterns" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // A → B, A → C, B → D, C → D
    mock.addAurPackage("A", &.{ "B", "C" }, &.{});
    mock.addAurPackage("B", &.{"D"}, &.{});
    mock.addAurPackage("C", &.{"D"}, &.{});
    mock.addAurPackage("D", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"A"});
    defer plan.deinit(testing.allocator);

    // D must come before B and C, which must come before A
    var indices = std.StringHashMapUnmanaged(usize){};
    defer indices.deinit(testing.allocator);

    for (plan.build_order, 0..) |entry, i| {
        try indices.put(testing.allocator, entry.name, i);
    }

    try testing.expect(indices.get("D").? < indices.get("B").?);
    try testing.expect(indices.get("D").? < indices.get("C").?);
    try testing.expect(indices.get("B").? < indices.get("A").?);
    try testing.expect(indices.get("C").? < indices.get("A").?);
}

test "resolve discovers deps of installed target via AUR fallback" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();

    // pacaur is installed but also in AUR with deps
    mock.addSatisfiedWithAurDeps("pacaur", "4.8.6-2", &.{ "auracle-git", "expac" }, &.{});
    mock.addAurPackage("auracle-git", &.{}, &.{});
    mock.addRepoPackage("expac", "10-3");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"pacaur"});
    defer plan.deinit(testing.allocator);

    // Should discover auracle-git (AUR dep) and expac (repo dep)
    try testing.expect(plan.all_deps.len >= 3); // pacaur + auracle-git + expac
    try testing.expectEqual(@as(usize, 1), plan.repo_deps.len);
    try testing.expectEqualStrings("expac", plan.repo_deps[0]);

    // auracle-git should be in build_order
    var found_auracle = false;
    for (plan.build_order) |entry| {
        if (std.mem.eql(u8, entry.name, "auracle-git")) found_auracle = true;
    }
    try testing.expect(found_auracle);
}

test "resolve handles makedepends in addition to depends" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("A", &.{"B"}, &.{"C"});
    mock.addAurPackage("B", &.{}, &.{});
    mock.addAurPackage("C", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"A"});
    defer plan.deinit(testing.allocator);

    // Both B and C must come before A
    var indices = std.StringHashMapUnmanaged(usize){};
    defer indices.deinit(testing.allocator);

    for (plan.build_order, 0..) |entry, i| {
        try indices.put(testing.allocator, entry.name, i);
    }

    try testing.expect(indices.get("B").? < indices.get("A").?);
    try testing.expect(indices.get("C").? < indices.get("A").?);
}

// ── repo_aur Version Check Tests ─────────────────────────────────────────

test "resolve reclassifies repo_aur target as aur when AUR version is newer" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // aurpkgs has 1.0, AUR has 2.0
    mock.addRepoAurWithAurVersion("pkg", "1.0-1", "2.0-1", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"pkg"});
    defer plan.deinit(testing.allocator);

    // Should be in build_order (reclassified to .aur)
    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expectEqualStrings("pkg", plan.build_order[0].name);

    // all_deps should show .aur source
    for (plan.all_deps) |dep| {
        if (std.mem.eql(u8, dep.name, "pkg")) {
            try testing.expectEqual(registry_mod.Source.aur, dep.source);
        }
    }
}

test "resolve keeps repo_aur target when aurpkgs version matches AUR" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // Same version in aurpkgs and AUR
    mock.addRepoAurWithAurVersion("pkg", "1.0-1", "1.0-1", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"pkg"});
    defer plan.deinit(testing.allocator);

    // Should NOT be in build_order (stays repo_aur)
    try testing.expectEqual(@as(usize, 0), plan.build_order.len);

    // all_deps should show .repo_aur source
    for (plan.all_deps) |dep| {
        if (std.mem.eql(u8, dep.name, "pkg")) {
            try testing.expectEqual(registry_mod.Source.repo_aur, dep.source);
        }
    }
}

test "resolve reclassifies repo_aur VCS target even when version matches" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // VCS package: same version in aurpkgs and AUR (static AUR version is meaningless)
    mock.addRepoAurWithAurVersion("pacaur-git", "4.0.0-1", "4.0.0-1", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"pacaur-git"});
    defer plan.deinit(testing.allocator);

    // VCS target should be reclassified to .aur and appear in build_order
    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expectEqualStrings("pacaur-git", plan.build_order[0].name);
}

test "resolve reclassifies repo_aur VCS target with no AUR data" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // VCS package in local aurpkgs repo but not published to the real AUR —
    // resolveFromAur returns null, so aur_pkg stays null throughout.
    mock.addRepoAur("aurodle-git", "r100-1");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"aurodle-git"});
    defer plan.deinit(testing.allocator);

    // VCS target must be rebuilt even without AUR metadata
    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expectEqualStrings("aurodle-git", plan.build_order[0].name);
}

test "rebuild reclassifies satisfied_aur target into build plan" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // pacaur is installed (satisfied_aur) with same version as AUR
    mock.addSatisfiedWithAurDeps("pacaur", "4.8.6-2", &.{"auracle-git"}, &.{});
    mock.addAurPackage("auracle-git", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    s.rebuild = true;
    defer s.deinit();

    const plan = try s.resolve(&.{"pacaur"});
    defer plan.deinit(testing.allocator);

    // pacaur should be in build_order despite being up-to-date
    var found_pacaur = false;
    for (plan.build_order) |entry| {
        if (std.mem.eql(u8, entry.name, "pacaur")) found_pacaur = true;
    }
    try testing.expect(found_pacaur);
}

test "resolve prefers AUR exact name over provider redirect for targets" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // "pacaur" exists as a provider redirect to "pacaur-git" (e.g. pacaur-git installed, provides pacaur)
    mock.addProvider("pacaur", "pacaur-git", .satisfied_aur, "4.8.6-2");
    // But "pacaur" also exists as a real AUR package
    mock.addAurPackage("pacaur", &.{"auracle-git"}, &.{});
    mock.addAurPackage("auracle-git", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"pacaur"});
    defer plan.deinit(testing.allocator);

    // Should build "pacaur" (the real AUR package), not redirect to "pacaur-git"
    var found_pacaur = false;
    var found_pacaur_git = false;
    for (plan.build_order) |entry| {
        if (std.mem.eql(u8, entry.name, "pacaur")) found_pacaur = true;
        if (std.mem.eql(u8, entry.name, "pacaur-git")) found_pacaur_git = true;
    }
    try testing.expect(found_pacaur);
    try testing.expect(!found_pacaur_git);
}

test "resolve still redirects virtual name when target not in AUR" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // "auracle" is a virtual name, only provided by "auracle-git", not in AUR itself
    mock.addProvider("auracle", "auracle-git", .satisfied_aur, "r427-1");
    mock.addSatisfiedWithAurDeps("auracle-git", "r427-1", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    s.rebuild = true;
    defer s.deinit();

    const plan = try s.resolve(&.{"auracle"});
    defer plan.deinit(testing.allocator);

    // Should redirect to "auracle-git" since "auracle" doesn't exist in AUR
    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expectEqualStrings("auracle-git", plan.build_order[0].name);
    try testing.expect(plan.build_order[0].is_target);
}

test "resolve redirects deferred AUR provider dependency to real name" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // pacaur depends on "auracle" but only "auracle-git" exists in AUR
    mock.addAurPackage("pacaur", &.{"auracle"}, &.{});
    mock.addAurPackage("auracle-git", &.{}, &.{});
    // auracle is NOT in packages (unknown to resolveMany) but found via AUR provider search
    mock.addDeferredProvider("auracle", "auracle-git");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"pacaur"});
    defer plan.deinit(testing.allocator);

    // Build order should show "auracle-git", not "auracle"
    try testing.expectEqual(@as(usize, 2), plan.build_order.len);
    // auracle-git must come before pacaur (dependency ordering)
    try testing.expectEqualStrings("auracle-git", plan.build_order[0].name);
    try testing.expectEqualStrings("pacaur", plan.build_order[1].name);
    // pacaur must know it depends on auracle-git (for sync DB refresh)
    try testing.expect(plan.build_order[1].aur_dep_bases.len > 0);
    var has_auracle_git_dep = false;
    for (plan.build_order[1].aur_dep_bases) |dep_base| {
        if (std.mem.eql(u8, dep_base, "auracle-git")) has_auracle_git_dep = true;
    }
    try testing.expect(has_auracle_git_dep);
}

test "resolve redirects virtual name to provider package" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // "auracle" is a virtual name provided by "auracle-git"
    mock.addProvider("auracle", "auracle-git", .satisfied_aur, "r427-1");
    mock.addSatisfiedWithAurDeps("auracle-git", "r427-1", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    s.rebuild = true;
    defer s.deinit();

    const plan = try s.resolve(&.{"auracle"});
    defer plan.deinit(testing.allocator);

    // Build plan should show "auracle-git", not "auracle"
    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expectEqualStrings("auracle-git", plan.build_order[0].name);
    try testing.expect(plan.build_order[0].is_target);
}

test "resolve redirects to provider when installed pkg provides target and AUR also has that provider" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // "aurodle-git" is installed and provides "aurodle" via local pacman
    mock.addProvider("aurodle", "aurodle-git", .satisfied_aur, "r246.21fa2dd-1");
    // AUR also knows "aurodle" is provided by "aurodle-git" (resolveFromAur finds this)
    mock.addDeferredProvider("aurodle", "aurodle-git");
    // "aurodle-git" itself exists in AUR
    mock.addAurPackage("aurodle-git", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"aurodle"});
    defer plan.deinit(testing.allocator);

    // Must show "aurodle-git" in the build plan, not "aurodle"
    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expectEqualStrings("aurodle-git", plan.build_order[0].name);
    try testing.expect(plan.build_order[0].is_target);
}

test "resolve discovers dependencies of provider-redirected packages" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // pacaur depends on "auracle", which is provided by "auracle-git"
    mock.addAurPackage("pacaur", &.{"auracle"}, &.{});
    // auracle-git has its own AUR deps (meson) and repo deps (expac)
    mock.addSatisfiedWithAurDeps("auracle-git", "r427-1", &.{"dep-a"}, &.{"dep-b"});
    mock.addProvider("auracle", "auracle-git", .satisfied_aur, "r427-1");
    mock.addRepoPackage("dep-a", "1.0");
    mock.addRepoPackage("dep-b", "1.0");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"pacaur"});
    defer plan.deinit(testing.allocator);

    // auracle-git's deps (dep-a, dep-b) must appear in repo_deps
    try testing.expect(plan.repo_deps.len >= 2);
    var found_a = false;
    var found_b = false;
    for (plan.repo_deps) |dep| {
        if (std.mem.eql(u8, dep, "dep-a")) found_a = true;
        if (std.mem.eql(u8, dep, "dep-b")) found_b = true;
    }
    try testing.expect(found_a);
    try testing.expect(found_b);
}

test "resolve discovers deps of deferred AUR provider (search returns empty deps)" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // pacaur depends on "auracle" (virtual name, not in AUR by exact name)
    mock.addAurPackage("pacaur", &.{"auracle"}, &.{});
    // "auracle" found via AUR provider search → auracle-git (search returns empty deps)
    mock.addDeferredProvider("auracle", "auracle-git");
    // auracle-git info (full metadata) has real deps
    mock.addSatisfiedWithAurDeps("auracle-git", "r427-1", &.{"dep-a"}, &.{"dep-b"});
    mock.addRepoPackage("dep-a", "1.0");
    mock.addRepoPackage("dep-b", "1.0");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"pacaur"});
    defer plan.deinit(testing.allocator);

    // auracle-git's deps must appear in repo_deps
    var found_a = false;
    var found_b = false;
    for (plan.repo_deps) |dep| {
        if (std.mem.eql(u8, dep, "dep-a")) found_a = true;
        if (std.mem.eql(u8, dep, "dep-b")) found_b = true;
    }
    try testing.expect(found_a);
    try testing.expect(found_b);
}

test "resolve does not version-check repo_aur dependencies" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("target", &.{"dep"}, &.{});
    // dep is in aurpkgs with old version, but it's not a target
    mock.addRepoAur("dep", "1.0-1");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"target"});
    defer plan.deinit(testing.allocator);

    // dep should stay repo_aur (no version check for non-targets)
    for (plan.all_deps) |d| {
        if (std.mem.eql(u8, d.name, "dep")) {
            try testing.expectEqual(registry_mod.Source.repo_aur, d.source);
        }
    }
}

// ── Conflict Detection Tests ─────────────────────────────────────────────

test "detectConflicts finds AUR↔AUR conflict" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackageWithConflicts("foo", &.{}, &.{"bar"});
    mock.addAurPackage("bar", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{ "foo", "bar" });
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.conflicts.len);
    try testing.expectEqual(Conflict.Kind.aur_aur, plan.conflicts[0].kind);
    try testing.expectEqualStrings("foo", plan.conflicts[0].package);
    try testing.expectEqualStrings("bar", plan.conflicts[0].conflicts_with);
}

test "detectConflicts finds AUR↔installed conflict" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // foo conflicts with "old-pkg" which is installed but not in the graph
    mock.addAurPackageWithConflicts("foo", &.{}, &.{"old-pkg"});
    mock.pacman.addInstalled("old-pkg");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"foo"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.conflicts.len);
    try testing.expectEqual(Conflict.Kind.aur_installed, plan.conflicts[0].kind);
    try testing.expectEqualStrings("foo", plan.conflicts[0].package);
    try testing.expectEqualStrings("old-pkg", plan.conflicts[0].conflicts_with);
}

test "detectConflicts ignores self-conflicts" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // -git package conflicting with its own name (common pattern)
    mock.addAurPackageWithConflicts("foo-git", &.{}, &.{"foo-git"});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"foo-git"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), plan.conflicts.len);
}

test "detectConflicts deduplicates bidirectional conflicts" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // Both packages declare conflict with each other
    mock.addAurPackageWithConflicts("foo", &.{}, &.{"bar"});
    mock.addAurPackageWithConflicts("bar", &.{}, &.{"foo"});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{ "foo", "bar" });
    defer plan.deinit(testing.allocator);

    // Should produce exactly one conflict, not two
    try testing.expectEqual(@as(usize, 1), plan.conflicts.len);
    try testing.expectEqual(Conflict.Kind.aur_aur, plan.conflicts[0].kind);
}

test "detectConflicts returns empty when no conflicts" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("foo", &.{}, &.{});
    mock.addAurPackage("bar", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{ "foo", "bar" });
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), plan.conflicts.len);
}

test "detectConflicts handles multiple conflicts from same package" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // foo conflicts with both bar and baz
    mock.addAurPackageWithConflicts("foo", &.{}, &.{ "bar", "baz" });
    mock.addAurPackage("bar", &.{}, &.{});
    mock.addAurPackage("baz", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{ "foo", "bar", "baz" });
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), plan.conflicts.len);
}

test "detectConflicts parses version constraints from conflict entries" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // conflict declared as "bar>=1.0" — should still match node "bar"
    mock.addAurPackageWithConflicts("foo", &.{}, &.{"bar>=1.0"});
    mock.addAurPackage("bar", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{ "foo", "bar" });
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.conflicts.len);
    try testing.expectEqualStrings("bar", plan.conflicts[0].conflicts_with);
}

test "detectConflicts finds conflict via provides" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // foo conflicts with "jack", bar provides "jack"
    mock.addAurPackageWithConflicts("foo", &.{}, &.{"jack"});
    mock.addAurPackageFull("bar", &.{}, &.{}, &.{"jack"});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{ "foo", "bar" });
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.conflicts.len);
    try testing.expectEqual(Conflict.Kind.aur_aur, plan.conflicts[0].kind);
    // conflicts_with should be the actual provider package name, not the virtual name
    try testing.expectEqualStrings("bar", plan.conflicts[0].conflicts_with);
}

test "detectConflicts skips self-conflict via provides" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // foo-git provides "foo" and conflicts with "foo" — not a real conflict
    mock.addAurPackageFull("foo-git", &.{}, &.{"foo"}, &.{"foo"});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"foo-git"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), plan.conflicts.len);
}

test "detectConflicts skips self-conflict via alias (provider redirect)" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // pacaur depends on "foo"; "foo" doesn't exist standalone but foo-git provides it.
    // foo-git also conflicts with "foo" (standard -git PKGBUILD pattern).
    // After solving pacaur, an alias "foo" → "foo-git" is registered.
    // detectConflicts must not report foo-git conflicting with itself via that alias.
    mock.addAurPackageFull("foo-git", &.{}, &.{"foo"}, &.{"foo"});
    mock.addProvider("foo", "foo-git", .aur, "r1-1");
    mock.addAurPackage("pacaur", &.{"foo"}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"pacaur"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), plan.conflicts.len);
}

test "detectConflicts finds installed conflict even when provides resolves to self" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // foo-git provides "foo" and conflicts with "foo", and "foo" IS installed
    mock.addAurPackageFull("foo-git", &.{}, &.{"foo"}, &.{"foo"});
    mock.pacman.addInstalled("foo");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"foo-git"});
    defer plan.deinit(testing.allocator);

    // Should detect AUR↔installed conflict (foo-git conflicts with installed "foo")
    try testing.expectEqual(@as(usize, 1), plan.conflicts.len);
    try testing.expectEqual(Conflict.Kind.aur_installed, plan.conflicts[0].kind);
    try testing.expectEqualStrings("foo-git", plan.conflicts[0].package);
    try testing.expectEqualStrings("foo", plan.conflicts[0].conflicts_with);
}

test "detectConflicts provides with versioned provides string" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // foo conflicts with "libgl", bar provides "libgl=1.0"
    mock.addAurPackageWithConflicts("foo", &.{}, &.{"libgl"});
    mock.addAurPackageFull("bar", &.{}, &.{}, &.{"libgl=1.0"});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{ "foo", "bar" });
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.conflicts.len);
    try testing.expectEqualStrings("bar", plan.conflicts[0].conflicts_with);
}

test "detectConflicts skips self-conflict via installed provider (VCS rebuild)" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // auracle-git provides+conflicts "auracle", and auracle-git is installed
    // (it is the installed provider of "auracle"). Rebuilding auracle-git
    // should NOT produce a self-conflict.
    mock.addAurPackageFull("auracle-git", &.{}, &.{"auracle"}, &.{"auracle"});
    mock.pacman.addInstalled("auracle-git");
    mock.pacman.addProvider("auracle", "auracle-git");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"auracle-git"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), plan.conflicts.len);
}

test "detectConflicts finds AUR replaces installed" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // new-pkg replaces old-pkg which is installed
    mock.addAurPackageFullWithReplaces("new-pkg", &.{}, &.{}, &.{}, &.{"old-pkg"});
    mock.pacman.addInstalled("old-pkg");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"new-pkg"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.conflicts.len);
    try testing.expectEqual(Conflict.Kind.aur_replaces, plan.conflicts[0].kind);
    try testing.expectEqualStrings("new-pkg", plan.conflicts[0].package);
    try testing.expectEqualStrings("old-pkg", plan.conflicts[0].conflicts_with);
}

test "detectConflicts ignores self-replacement" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // Package replaces its own name (no-op)
    mock.addAurPackageFullWithReplaces("foo", &.{}, &.{}, &.{}, &.{"foo"});
    mock.pacman.addInstalled("foo");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"foo"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), plan.conflicts.len);
}

test "detectConflicts replaces does not trigger when target not installed" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // new-pkg replaces old-pkg but old-pkg is not installed
    mock.addAurPackageFullWithReplaces("new-pkg", &.{}, &.{}, &.{}, &.{"old-pkg"});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"new-pkg"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), plan.conflicts.len);
}

test "detectConflicts replaces via installed provider" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // new-pkg replaces "virtual-dep", which is provided by "old-provider" (installed)
    mock.addAurPackageFullWithReplaces("new-pkg", &.{}, &.{}, &.{}, &.{"virtual-dep"});
    mock.pacman.addInstalled("old-provider");
    mock.pacman.addProvider("virtual-dep", "old-provider");

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"new-pkg"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.conflicts.len);
    try testing.expectEqual(Conflict.Kind.aur_replaces, plan.conflicts[0].kind);
    try testing.expectEqualStrings("old-provider", plan.conflicts[0].conflicts_with);
}

test "ignored dependency returns IgnoredDependency error" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // foo depends on bar, but bar is ignored
    mock.addAurPackage("foo", &.{"bar"}, &.{});
    mock.addAurPackage("bar", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();
    s.ignore = &.{"bar"};

    try testing.expectError(error.IgnoredDependency, s.resolve(&.{"foo"}));
}

test "ignored package does not affect targets (filtered upstream)" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackage("foo", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();
    // foo is in ignore list but also a target — targets are filtered
    // before reaching the solver, so the solver never sees it as ignored.
    // This test verifies that targets bypass the ignore check.
    s.ignore = &.{"foo"};

    const plan = try s.resolve(&.{"foo"});
    defer plan.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
}

test "needed prevents rebuild of satisfied_aur target at same version" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // pacaur is installed (satisfied_aur) with same version as AUR
    mock.addSatisfiedWithAurDeps("pacaur", "4.8.6-2", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    s.rebuild = true;
    s.needed = true;
    defer s.deinit();

    const plan = try s.resolve(&.{"pacaur"});
    defer plan.deinit(testing.allocator);

    // --needed overrides --rebuild: pacaur should NOT be in build_order
    try testing.expectEqual(@as(usize, 0), plan.build_order.len);
}

test "needed allows build when AUR version is newer" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // pacaur installed at 4.8.5, AUR has 4.8.6
    mock.addSatisfiedWithAurDepsVersioned("pacaur", "4.8.5-1", "4.8.6-1", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    s.needed = true;
    defer s.deinit();

    const plan = try s.resolve(&.{"pacaur"});
    defer plan.deinit(testing.allocator);

    // AUR version is newer, so it should be in build_order even with --needed
    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expectEqualStrings("pacaur", plan.build_order[0].name);
}

test "split package: multiple targets from same pkgbase all tracked as targets" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // qt6-base and qt6-tools both have pkgbase "qt6"
    mock.addAurPackageWithBase("qt6-base", "qt6", &.{}, &.{});
    mock.addAurPackageWithBase("qt6-tools", "qt6", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{ "qt6-base", "qt6-tools" });
    defer plan.deinit(testing.allocator);

    // Only one build entry (one makepkg invocation for pkgbase "qt6")
    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expectEqualStrings("qt6", plan.build_order[0].pkgbase);
    try testing.expect(plan.build_order[0].is_target);

    // Both target names must be tracked for installation
    try testing.expectEqual(@as(usize, 2), plan.build_order[0].target_names.len);
    // Order depends on BFS traversal; check both names are present
    var found_base = false;
    var found_tools = false;
    for (plan.build_order[0].target_names) |tname| {
        if (std.mem.eql(u8, tname, "qt6-base")) found_base = true;
        if (std.mem.eql(u8, tname, "qt6-tools")) found_tools = true;
    }
    try testing.expect(found_base);
    try testing.expect(found_tools);
}

test "split package: single target from split pkgbase tracks only that target" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    mock.addAurPackageWithBase("qt6-base", "qt6", &.{}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{"qt6-base"});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.build_order.len);
    try testing.expectEqual(@as(usize, 1), plan.build_order[0].target_names.len);
    try testing.expectEqualStrings("qt6-base", plan.build_order[0].target_names[0]);
}

test "split package: non-target dep sharing pkgbase with target" {
    var mock = MockRegistry.initEmpty();
    defer mock.deinitMock();
    // "app" depends on "qt6-tools", user targets "qt6-base" and "app"
    // qt6-base and qt6-tools share pkgbase "qt6"
    mock.addAurPackageWithBase("qt6-base", "qt6", &.{}, &.{});
    mock.addAurPackageWithBase("qt6-tools", "qt6", &.{}, &.{});
    mock.addAurPackage("app", &.{"qt6-tools"}, &.{});

    var s = TestSolver.init(testing.allocator, &mock);
    defer s.deinit();

    const plan = try s.resolve(&.{ "qt6-base", "app" });
    defer plan.deinit(testing.allocator);

    // Two build entries: one for qt6 pkgbase, one for app
    try testing.expectEqual(@as(usize, 2), plan.build_order.len);

    // Find the qt6 entry
    var qt6_entry: ?BuildEntry = null;
    for (plan.build_order) |entry| {
        if (std.mem.eql(u8, entry.pkgbase, "qt6")) qt6_entry = entry;
    }
    try testing.expect(qt6_entry != null);

    // qt6-base is a target, qt6-tools is a dep (not a target)
    // Only qt6-base should appear in target_names
    try testing.expectEqual(@as(usize, 1), qt6_entry.?.target_names.len);
    try testing.expectEqualStrings("qt6-base", qt6_entry.?.target_names[0]);
}
