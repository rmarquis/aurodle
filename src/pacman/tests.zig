const std = @import("std");
const testing = std.testing;
const pacman = @import("../pacman.zig");
const alpm = @import("../alpm.zig");
const pacman_conf = @import("../pacman_conf.zig");
const repo_conf = @import("../repo_conf.zig");

const Pacman = pacman.Pacman;

// ── Integration Tests (require real pacman database) ─────────────────────

test "Pacman.init and deinit on Arch system" {
    if (!pacman_conf.isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(testing.allocator, repo_conf.DEFAULT_REPO_NAME);
    defer pm.deinit();

    // Should have at least one sync db (core/extra)
    try testing.expect(pm.sync_dbs.len > 0);
}

test "isInstalled returns true for pacman itself" {
    if (!pacman_conf.isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(testing.allocator, repo_conf.DEFAULT_REPO_NAME);
    defer pm.deinit();

    try testing.expect(pm.isInstalled("pacman"));
    try testing.expect(!pm.isInstalled("zzz-not-installed-pkg-12345"));
}

test "installedVersion returns version for installed package" {
    if (!pacman_conf.isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(testing.allocator, repo_conf.DEFAULT_REPO_NAME);
    defer pm.deinit();

    const ver = pm.installedVersion("pacman");
    try testing.expect(ver != null);
    try testing.expect(ver.?.len > 0);

    try testing.expect(pm.installedVersion("zzz-not-installed") == null);
}

test "installedPkgbase returns the satisfier's pkgbase, by name or provision" {
    if (!pacman_conf.isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(testing.allocator, repo_conf.DEFAULT_REPO_NAME);
    defer pm.deinit();

    try testing.expectEqualStrings("pacman", pm.installedPkgbase("pacman").?);
    // `sh` is a provision of bash.
    try testing.expectEqualStrings("bash", pm.installedPkgbase("sh").?);
    try testing.expect(pm.installedPkgbase("zzz-not-installed") == null);
}

test "aurRepoPkgbase returns null for packages outside the local AUR repository" {
    if (!pacman_conf.isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(testing.allocator, repo_conf.DEFAULT_REPO_NAME);
    defer pm.deinit();

    try testing.expect(pm.aurRepoPkgbase("pacman") == null);
    try testing.expect(pm.aurRepoPkgbase("zzz-not-installed") == null);
}

test "aurRepoDepends is empty for packages outside the local AUR repository" {
    if (!pacman_conf.isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(testing.allocator, repo_conf.DEFAULT_REPO_NAME);
    defer pm.deinit();

    try testing.expectEqual(@as(usize, 0), (try pm.aurRepoDepends("pacman")).len);
    try testing.expectEqual(@as(usize, 0), (try pm.aurRepoDepends("zzz-not-installed")).len);
}

test "depString renders the name, plus the constraint when there is one" {
    const dep = alpm.Dependency{ .name = "foo", .version = "", .desc = null, .name_hash = 0, .mod = .any };
    try testing.expectEqualStrings("foo", try pacman.depString(testing.allocator, dep));

    const cases = [_]struct { mod: alpm.DepMod, want: []const u8 }{
        .{ .mod = .eq, .want = "foo=1:2.0-1" },
        .{ .mod = .ge, .want = "foo>=1:2.0-1" },
        .{ .mod = .le, .want = "foo<=1:2.0-1" },
        .{ .mod = .gt, .want = "foo>1:2.0-1" },
        .{ .mod = .lt, .want = "foo<1:2.0-1" },
    };
    for (cases) |case| {
        const str = try pacman.depString(testing.allocator, .{ .name = "foo", .version = "1:2.0-1", .desc = null, .name_hash = 0, .mod = case.mod });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(case.want, str);
    }
}

test "isInSyncDb finds official packages" {
    if (!pacman_conf.isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(testing.allocator, repo_conf.DEFAULT_REPO_NAME);
    defer pm.deinit();

    // glibc is always in an official sync db
    try testing.expect(pm.isInSyncDb("glibc"));
    try testing.expect(!pm.isInSyncDb("zzz-definitely-not-in-repos"));
}

test "syncDbFor returns correct repository name" {
    if (!pacman_conf.isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(testing.allocator, repo_conf.DEFAULT_REPO_NAME);
    defer pm.deinit();

    // glibc is in core
    const repo = pm.syncDbFor("glibc");
    try testing.expect(repo != null);
    // Don't assert exact repo name — it varies between core/extra

    try testing.expect(pm.syncDbFor("zzz-not-real") == null);
}

test "satisfies checks installed version against constraint" {
    if (!pacman_conf.isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(testing.allocator, repo_conf.DEFAULT_REPO_NAME);
    defer pm.deinit();

    // pacman is definitely installed with version >= 1.0
    try testing.expect(pm.satisfies("pacman", .{ .op = .ge, .version = "1.0" }));
    // But probably not version 99.0
    try testing.expect(!pm.satisfies("pacman", .{ .op = .ge, .version = "99.0" }));
    // Not-installed package can't satisfy anything
    try testing.expect(!pm.satisfies("zzz-not-installed", .{ .op = .eq, .version = "1.0" }));
}

test "satisfiesDep checks dependency string against installed packages" {
    if (!pacman_conf.isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(testing.allocator, repo_conf.DEFAULT_REPO_NAME);
    defer pm.deinit();

    try testing.expect(pm.satisfiesDep("glibc"));
    try testing.expect(!pm.satisfiesDep("zzz-not-real-dep-12345"));
}

test "findProvider finds package providing dependency" {
    if (!pacman_conf.isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(testing.allocator, repo_conf.DEFAULT_REPO_NAME);
    defer pm.deinit();

    // glibc is a direct package name — should be found
    const result = pm.findProvider("glibc");
    try testing.expect(result != null);
    try testing.expectEqualStrings("glibc", result.?.name);

    // Nonexistent provider
    try testing.expect(pm.findProvider("zzz-nonexistent-virtual-dep") == null);
}

test "allForeignPackages returns packages not in official repos" {
    if (!pacman_conf.isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(testing.allocator, repo_conf.DEFAULT_REPO_NAME);
    defer pm.deinit();

    const foreign = try pm.allForeignPackages();
    defer testing.allocator.free(foreign);

    // Verify: no foreign package should be in an official sync db
    for (foreign) |pkg| {
        try testing.expect(pkg.name.len > 0);
        try testing.expect(pkg.version.len > 0);

        // Check it's truly not in official repos
        const in_official = blk: {
            for (pm.official_dbs) |db| {
                if (db.getPackage(pkg.name) != null) break :blk true;
            }
            break :blk false;
        };
        try testing.expect(!in_official);
    }
}

test "repoDepSizes returns nonzero sizes for real packages" {
    if (!pacman_conf.isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(testing.allocator, repo_conf.DEFAULT_REPO_NAME);
    defer pm.deinit();

    // glibc is always in sync dbs and installed
    const names = &[_][]const u8{"glibc"};
    const sizes = pm.repoDepSizes(names);
    try testing.expect(sizes.download > 0);
    try testing.expect(sizes.install > 0);
    // has_upgrades is only true when versions differ (not for same-version reinstalls)
}

test "repoDepSizes returns zeros for unknown packages" {
    if (!pacman_conf.isArchLinux()) return error.SkipZigTest;

    var pm = try Pacman.init(testing.allocator, repo_conf.DEFAULT_REPO_NAME);
    defer pm.deinit();

    const names = &[_][]const u8{"zzz-nonexistent-pkg-99999"};
    const sizes = pm.repoDepSizes(names);
    try testing.expectEqual(@as(i64, 0), sizes.download);
    try testing.expectEqual(@as(i64, 0), sizes.install);
    try testing.expect(!sizes.has_upgrades);
}

// ── Transitive dep BFS (mock pacman, no libalpm handle) ────────────────────

const mocks_mod = @import("mocks.zig");
const repo_deps = @import("repo_deps.zig");
const MockPacman = mocks_mod.MockPacman;
const MockPackage = mocks_mod.MockPackage;

// Regression: nodejs-lts-krypton (installed, provides nodejs=24.22.0) vs
// uninstalled repo providers nodejs/nodejs-lts-iron/nodejs-lts-jod. The dep
// is already satisfied — the BFS must neither prompt nor schedule a
// conflicting provider for installation.
const nodejs_world = MockPacman{
    .sync_pkgs = &.{
        .{ .name = "npm", .depends = &.{"nodejs"} },
        .{ .name = "nodejs" },
        .{ .name = "nodejs-lts-iron", .provides = &.{"nodejs"} },
        .{ .name = "nodejs-lts-jod", .provides = &.{"nodejs"} },
        .{ .name = "nodejs-lts-krypton", .provides = &.{ "nodejs=24.22.0", "nodejs-lts" } },
    },
    .local_pkgs = &.{
        .{ .name = "nodejs-lts-krypton", .provides = &.{ "nodejs=24.22.0", "nodejs-lts" } },
    },
};

test "findTransitiveProviderChoices: installed provides-satisfier suppresses provider choice" {
    const choices = try repo_deps.findTransitiveProviderChoices(&nodejs_world, testing.allocator, &.{"npm"});
    defer {
        for (choices) |ch| testing.allocator.free(ch.candidates);
        testing.allocator.free(choices);
    }

    try testing.expectEqual(@as(usize, 0), choices.len);
}

test "findTransitiveProviderChoices: unsatisfied virtual dep still offers a choice" {
    const world = MockPacman{ .sync_pkgs = nodejs_world.sync_pkgs };

    const choices = try repo_deps.findTransitiveProviderChoices(&world, testing.allocator, &.{"npm"});
    defer {
        for (choices) |ch| testing.allocator.free(ch.candidates);
        testing.allocator.free(choices);
    }

    try testing.expectEqual(@as(usize, 1), choices.len);
    try testing.expectEqualStrings("nodejs", choices[0].dep_name);
    try testing.expectEqual(@as(usize, 4), choices[0].candidates.len);
}

test "transitiveRepoDeps: installed provides-satisfier excludes conflicting provider" {
    const deps = try repo_deps.transitiveRepoDeps(&nodejs_world, testing.allocator, &.{"npm"}, .empty);
    defer testing.allocator.free(deps);

    try testing.expectEqualSlices([]const u8, &.{"npm"}, deps);
}

test "transitiveRepoDeps: unsatisfied virtual dep resolves to first-satisfier" {
    const world = MockPacman{ .sync_pkgs = nodejs_world.sync_pkgs };

    const deps = try repo_deps.transitiveRepoDeps(&world, testing.allocator, &.{"npm"}, .empty);
    defer testing.allocator.free(deps);

    try testing.expectEqualSlices([]const u8, &.{ "npm", "nodejs" }, deps);
}
