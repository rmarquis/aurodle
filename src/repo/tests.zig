const std = @import("std");
const testing = std.testing;
const repo = @import("../repo.zig");
const utils = @import("../utils.zig");

const Repository = repo.Repository;
const DEFAULT_REPO_NAME = repo.DEFAULT_REPO_NAME;
const dirExists = utils.dirExists;

fn getTmpPath(tmp: std.testing.TmpDir) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.realPathFile(tmp.dir, testing.io, ".", &buf);
    return try testing.allocator.dupe(u8, buf[0..n]);
}

// ── parsePackageFilename Tests ───────────────────────────────────────────

test "parsePackageFilename: simple name" {
    const result = repo.parsePackageFilename("yay-12.3.5-1-x86_64.pkg.tar.zst").?;
    try testing.expectEqualStrings("yay", result.name);
    try testing.expectEqualStrings("12.3.5-1", result.version);
}

test "parsePackageFilename: hyphenated name" {
    const result = repo.parsePackageFilename("lib32-mesa-24.0.1-1-x86_64.pkg.tar.zst").?;
    try testing.expectEqualStrings("lib32-mesa", result.name);
    try testing.expectEqualStrings("24.0.1-1", result.version);
}

test "parsePackageFilename: multi-hyphen name" {
    const result = repo.parsePackageFilename("python-my-lib-0.1.0-1-any.pkg.tar.zst").?;
    try testing.expectEqualStrings("python-my-lib", result.name);
    try testing.expectEqualStrings("0.1.0-1", result.version);
}

test "parsePackageFilename: epoch version" {
    const result = repo.parsePackageFilename("python-3:3.12.1-1-x86_64.pkg.tar.zst").?;
    try testing.expectEqualStrings("python", result.name);
    try testing.expectEqualStrings("3:3.12.1-1", result.version);
}

test "parsePackageFilename: xz compression" {
    const result = repo.parsePackageFilename("xorg-x11-utils-7.5-1-x86_64.pkg.tar.xz").?;
    try testing.expectEqualStrings("xorg-x11-utils", result.name);
    try testing.expectEqualStrings("7.5-1", result.version);
}

test "parsePackageFilename: invalid input returns null" {
    try testing.expect(repo.parsePackageFilename("not-a-package.txt") == null);
    try testing.expect(repo.parsePackageFilename("") == null);
    try testing.expect(repo.parsePackageFilename("a.pkg.tar.zst") == null); // too few hyphens
}

// ── Repository Tests ─────────────────────────────────────────────────────

test "configInstructions contains required elements" {
    const instructions = Repository.configInstructions();
    try testing.expect(std.mem.indexOf(u8, instructions, "SigLevel") != null);
    try testing.expect(std.mem.indexOf(u8, instructions, "Server = file://") != null);
    try testing.expect(std.mem.indexOf(u8, instructions, "PKGDEST=") != null);
}

test "ensureExists creates directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer testing.allocator.free(tmp_path);

    var r = try Repository.initWithRoot(testing.allocator, testing.io, tmp_path);
    defer r.deinit();

    try r.ensureExists();
    try testing.expect(dirExists(r.repo_dir));
}

test "ensureExists is idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer testing.allocator.free(tmp_path);

    var r = try Repository.initWithRoot(testing.allocator, testing.io, tmp_path);
    defer r.deinit();

    try r.ensureExists();
    try r.ensureExists(); // second call should not error
    try r.ensureExists(); // third call should not error

    try testing.expect(dirExists(r.repo_dir));
}

test "findBuiltPackages finds matching files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer testing.allocator.free(tmp_path);

    // Create fake package files
    try std.Io.Dir.writeFile(tmp.dir, testing.io, .{ .sub_path = "yay-12.3.5-1-x86_64.pkg.tar.zst", .data = "fake" });
    try std.Io.Dir.writeFile(tmp.dir, testing.io, .{ .sub_path = "paru-2.0.3-1-x86_64.pkg.tar.zst", .data = "fake" });
    try std.Io.Dir.writeFile(tmp.dir, testing.io, .{ .sub_path = "README.md", .data = "not a package" });

    var r = try Repository.initWithRoot(testing.allocator, testing.io, tmp_path);
    defer r.deinit();

    const found = try r.findBuiltPackages(tmp_path);
    defer {
        for (found) |p| testing.allocator.free(p);
        testing.allocator.free(found);
    }

    try testing.expectEqual(@as(usize, 2), found.len);
}

test "findBuiltPackages returns empty for nonexistent directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer testing.allocator.free(tmp_path);

    var r = try Repository.initWithRoot(testing.allocator, testing.io, tmp_path);
    defer r.deinit();

    const not_exist = try std.fs.path.join(testing.allocator, &.{ tmp_path, "nonexistent" });
    defer testing.allocator.free(not_exist);

    const found = try r.findBuiltPackages(not_exist);
    defer testing.allocator.free(found);

    try testing.expectEqual(@as(usize, 0), found.len);
}

test "addBuiltPackages finds and registers split packages in repo dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer testing.allocator.free(tmp_path);

    var r = try Repository.initWithRoot(testing.allocator, testing.io, tmp_path);
    defer r.deinit();
    r.skip_repo_add = true;

    try r.ensureExists();

    // Place packages directly in repo dir (as makepkg with PKGDEST would)
    const repo_dir = r.repo_dir;
    const pkg_a = try std.fs.path.join(testing.allocator, &.{ repo_dir, "python-attrs-23.1-1-any.pkg.tar.zst" });
    defer testing.allocator.free(pkg_a);
    const pkg_b = try std.fs.path.join(testing.allocator, &.{ repo_dir, "python-attrs-tests-23.1-1-any.pkg.tar.zst" });
    defer testing.allocator.free(pkg_b);

    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), std.Options.debug_io, .{ .sub_path = pkg_a, .data = "pkg-a" });
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), std.Options.debug_io, .{ .sub_path = pkg_b, .data = "pkg-b" });

    const added = try r.addBuiltPackages();
    defer {
        for (added) |p| testing.allocator.free(p);
        testing.allocator.free(added);
    }

    try testing.expectEqual(@as(usize, 2), added.len);
}

test "addBuiltPackages returns PackageNotFound for empty repo dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer testing.allocator.free(tmp_path);

    var r = try Repository.initWithRoot(testing.allocator, testing.io, tmp_path);
    defer r.deinit();
    r.skip_repo_add = true;

    try r.ensureExists();

    try testing.expectError(error.PackageNotFound, r.addBuiltPackages());
}

test "listPackages returns parsed packages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer testing.allocator.free(tmp_path);

    var r = try Repository.initWithRoot(testing.allocator, testing.io, tmp_path);
    defer r.deinit();

    try r.ensureExists();

    // Create package files in the repo directory
    var repo_dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), testing.io, r.repo_dir, .{});
    defer repo_dir.close(testing.io);
    try std.Io.Dir.writeFile(repo_dir, testing.io, .{ .sub_path = "yay-12.3.5-1-x86_64.pkg.tar.zst", .data = "pkg" });
    try std.Io.Dir.writeFile(repo_dir, testing.io, .{ .sub_path = "paru-2.0.3-1-x86_64.pkg.tar.zst", .data = "pkg" });

    const pkgs = try r.listPackages();
    defer {
        for (pkgs) |pkg| {
            testing.allocator.free(pkg.name);
            testing.allocator.free(pkg.version);
            testing.allocator.free(pkg.filename);
        }
        testing.allocator.free(pkgs);
    }

    try testing.expectEqual(@as(usize, 2), pkgs.len);
}

test "listPackages returns empty for empty repo" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer testing.allocator.free(tmp_path);

    var r = try Repository.initWithRoot(testing.allocator, testing.io, tmp_path);
    defer r.deinit();

    try r.ensureExists();

    const pkgs = try r.listPackages();
    defer testing.allocator.free(pkgs);

    try testing.expectEqual(@as(usize, 0), pkgs.len);
}

test "listPackages skips database files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer testing.allocator.free(tmp_path);

    var r = try Repository.initWithRoot(testing.allocator, testing.io, tmp_path);
    defer r.deinit();

    try r.ensureExists();

    var repo_dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), testing.io, r.repo_dir, .{});
    defer repo_dir.close(testing.io);
    try std.Io.Dir.writeFile(repo_dir, testing.io, .{ .sub_path = DEFAULT_REPO_NAME ++ ".db.tar.xz", .data = "db" });
    try std.Io.Dir.writeFile(repo_dir, testing.io, .{ .sub_path = DEFAULT_REPO_NAME ++ ".files.tar.xz", .data = "files" });
    try std.Io.Dir.writeFile(repo_dir, testing.io, .{ .sub_path = "yay-12.3.5-1-x86_64.pkg.tar.zst", .data = "pkg" });

    const pkgs = try r.listPackages();
    defer {
        for (pkgs) |pkg| {
            testing.allocator.free(pkg.name);
            testing.allocator.free(pkg.version);
            testing.allocator.free(pkg.filename);
        }
        testing.allocator.free(pkgs);
    }

    try testing.expectEqual(@as(usize, 1), pkgs.len);
    try testing.expectEqualStrings("yay", pkgs[0].name);
}

test "clean identifies stale clones" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer testing.allocator.free(tmp_path);

    var r = try Repository.initWithRoot(testing.allocator, testing.io, tmp_path);
    defer r.deinit();

    try r.ensureExists();

    // Create clone directories
    const yay_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "yay" });
    defer testing.allocator.free(yay_path);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), testing.io, yay_path);
    const paru_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "paru" });
    defer testing.allocator.free(paru_path);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), testing.io, paru_path);

    // "paru" is uninstalled — should be cleaned
    const result = try r.clean(&.{"paru"});
    defer r.freeCleanResult(result);

    try testing.expectEqual(@as(usize, 1), result.removed_clones.len);
    try testing.expectEqualStrings("paru", result.removed_clones[0]);
}

test "clean skips repo directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer testing.allocator.free(tmp_path);

    var r = try Repository.initWithRoot(testing.allocator, testing.io, tmp_path);
    defer r.deinit();

    try r.ensureExists();

    // Even if the repo name were passed as uninstalled, the directory should be skipped
    const result = try r.clean(&.{DEFAULT_REPO_NAME});
    defer r.freeCleanResult(result);

    // repo dir should not appear as stale clones
    for (result.removed_clones) |name| {
        try testing.expect(!std.mem.eql(u8, name, DEFAULT_REPO_NAME));
    }
}

test "clean identifies stale package files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer testing.allocator.free(tmp_path);

    var r = try Repository.initWithRoot(testing.allocator, testing.io, tmp_path);
    defer r.deinit();
    r.skip_repo_add = true;

    try r.ensureExists();

    // Create package files in repo dir
    var repo_dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), testing.io, r.repo_dir, .{});
    defer repo_dir.close(testing.io);
    try std.Io.Dir.writeFile(repo_dir, testing.io, .{ .sub_path = "yay-12.3.5-1-x86_64.pkg.tar.zst", .data = "pkg" });
    try std.Io.Dir.writeFile(repo_dir, testing.io, .{ .sub_path = "paru-2.0.3-1-x86_64.pkg.tar.zst", .data = "pkg" });

    // "paru" is uninstalled
    const result = try r.clean(&.{"paru"});
    defer r.freeCleanResult(result);

    try testing.expectEqual(@as(usize, 1), result.removed_packages.len);
    try testing.expectEqualStrings("paru-2.0.3-1-x86_64.pkg.tar.zst", result.removed_packages[0]);
    try testing.expectEqual(@as(usize, 0), result.removed_clones.len);
}

test "clean with no uninstalled packages finds nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer testing.allocator.free(tmp_path);

    var r = try Repository.initWithRoot(testing.allocator, testing.io, tmp_path);
    defer r.deinit();

    try r.ensureExists();

    // Create a clone dir and a package file
    const yay_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "yay" });
    defer testing.allocator.free(yay_path);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), testing.io, yay_path);

    var repo_dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), testing.io, r.repo_dir, .{});
    defer repo_dir.close(testing.io);
    try std.Io.Dir.writeFile(repo_dir, testing.io, .{ .sub_path = "yay-12.3.5-1-x86_64.pkg.tar.zst", .data = "pkg" });

    // Empty uninstalled list — everything is still installed
    const result = try r.clean(&.{});
    defer r.freeCleanResult(result);

    try testing.expectEqual(@as(usize, 0), result.removed_clones.len);
    try testing.expectEqual(@as(usize, 0), result.removed_packages.len);
}

test "cleanAll removes all clones and packages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer testing.allocator.free(tmp_path);

    var r = try Repository.initWithRoot(testing.allocator, testing.io, tmp_path);
    defer r.deinit();

    try r.ensureExists();

    // Create clone dirs
    const yay_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "yay" });
    defer testing.allocator.free(yay_path);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), testing.io, yay_path);

    const paru_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "paru" });
    defer testing.allocator.free(paru_path);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), testing.io, paru_path);

    // Create package files
    var repo_dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), testing.io, r.repo_dir, .{});
    defer repo_dir.close(testing.io);
    try std.Io.Dir.writeFile(repo_dir, testing.io, .{ .sub_path = "yay-12.3.5-1-x86_64.pkg.tar.zst", .data = "pkg" });
    try std.Io.Dir.writeFile(repo_dir, testing.io, .{ .sub_path = "paru-2.0.3-1-x86_64.pkg.tar.zst", .data = "pkg" });

    const result = try r.cleanAll();
    defer r.freeCleanResult(result);

    try testing.expectEqual(@as(usize, 2), result.removed_clones.len);
    try testing.expectEqual(@as(usize, 2), result.removed_packages.len);
}

test "cleanAll with empty repo finds nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer testing.allocator.free(tmp_path);

    var r = try Repository.initWithRoot(testing.allocator, testing.io, tmp_path);
    defer r.deinit();

    try r.ensureExists();

    const result = try r.cleanAll();
    defer r.freeCleanResult(result);

    try testing.expectEqual(@as(usize, 0), result.removed_clones.len);
    try testing.expectEqual(@as(usize, 0), result.removed_packages.len);
}

test "Repository paths are correct" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try getTmpPath(tmp);
    defer testing.allocator.free(tmp_path);

    var r = try Repository.initWithRoot(testing.allocator, testing.io, tmp_path);
    defer r.deinit();

    try testing.expect(std.mem.endsWith(u8, r.repo_dir, "/" ++ DEFAULT_REPO_NAME));
    try testing.expect(std.mem.endsWith(u8, r.db_path, "/" ++ DEFAULT_REPO_NAME ++ "/" ++ DEFAULT_REPO_NAME ++ ".db.tar.xz"));
}
