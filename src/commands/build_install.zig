/// Installation phase: everything that invokes pacman or touches pacman's
/// state (sync DB refresh, cache purge, provider selection, credential setup).
const std = @import("std");
const Allocator = std.mem.Allocator;
const repo_mod = @import("../repo.zig");
const utils = @import("../utils.zig");
const registry_mod = @import("../registry.zig");
const pacman_mod = @import("../pacman.zig");
const plan_mod = @import("../plan.zig");
const color = @import("../color.zig");
const types = @import("types.zig");
const build_ctx = @import("build_context.zig");

const BuildContext = build_ctx.BuildContext;

/// Acquire privilege credentials and start the keepalive thread.
/// Called after the user has confirmed the plan and reviewed PKGBUILDs,
/// so we don't prompt for a password if they're going to bail out anyway.
/// Returns an ExitCode if acquisition failed, null on success.
pub fn acquireAuth(self: *BuildContext) !?types.ExitCode {
    const auth = self.auth;
    const ec = self.stderr_color;
    const cred_exit = auth.acquireCredentials() catch |err| {
        self.err_writer.print("{s}error:{s} credential acquisition failed: {}\n", .{ ec.red, ec.reset, err }) catch {};
        return .general_error;
    };
    if (cred_exit != 0) {
        self.err_writer.print("{s}error:{s} credential acquisition failed\n", .{ ec.red, ec.reset }) catch {};
        return .general_error;
    }
    auth.startKeepalive();
    return null;
}

/// Interactively select a provider for each virtual dep choice, remembering
/// packages already chosen so that subsequent deps auto-select without prompting.
/// E.g. choosing `ffmpeg` for `libavcodec.so` auto-picks it for `libavdevice.so`.
pub fn selectRepoDepsProviders(
    allocator: Allocator,
    choices: []const pacman_mod.SyncProviderChoice,
    noconfirm: bool,
    c: color.Style,
    chosen_providers: *std.StringHashMapUnmanaged([]const u8),
    providers_to_install: *std.ArrayListUnmanaged([]const u8),
) !void {
    var chosen_pkgs: std.StringHashMapUnmanaged(void) = .empty;
    defer chosen_pkgs.deinit(allocator);

    for (choices) |choice| {
        var auto_idx: ?usize = null;
        for (choice.candidates, 0..) |m, i| {
            if (chosen_pkgs.contains(m.name)) {
                auto_idx = i;
                break;
            }
        }

        const chosen_idx = if (auto_idx) |i| i else blk: {
            if (noconfirm) break :blk @as(usize, 0);
            const idx = utils.promptProviderChoice(choice.dep_name, choice.candidates, c);
            break :blk idx orelse 0;
        };

        const chosen_name = choice.candidates[chosen_idx].name;
        try chosen_providers.put(allocator, choice.dep_name, chosen_name);
        if (!(try chosen_pkgs.getOrPut(allocator, chosen_name)).found_existing) {
            try providers_to_install.append(allocator, chosen_name);
        }
    }
}

/// Install AUR targets (from aurpkgs) and repo targets (from their sync db)
/// in a single `pacman -S` transaction.
/// Returns false if pacman exits non-zero (the error is already printed).
pub fn installAllTargets(self: *BuildContext, aurpkgs_names: []const []const u8, repo_names: []const []const u8) !bool {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(self.allocator);

    try argv.appendSlice(self.allocator, &.{ "pacman", "-S" });

    if (self.flags.asdeps) {
        try argv.append(self.allocator, "--asdeps");
    } else if (self.flags.asexplicit) {
        try argv.append(self.allocator, "--asexplicit");
    }

    if (self.flags.needed) {
        try argv.append(self.allocator, "--needed");
    }

    // Always pass --noconfirm and --ask 36: the user already confirmed via
    // aurodle's "Proceed with installation?" prompt, so pacman should not
    // re-prompt. --ask 36 = 4 (auto-accept conflicts) + 32 (auto-accept replacements).
    try argv.appendSlice(self.allocator, &.{ "--noconfirm", "--ask", "36" });

    var qualified_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (qualified_names.items) |q| self.allocator.free(q);
        qualified_names.deinit(self.allocator);
    }

    // AUR targets qualified with the local AUR repo name (e.g., aurpkgs/pkgname)
    const aur_repo_name = self.repository.repo_name;
    for (aurpkgs_names) |name| {
        const qualified = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ aur_repo_name, name });
        try qualified_names.append(self.allocator, qualified);
        try argv.append(self.allocator, qualified);
    }

    // Repo targets qualified with their actual sync db (e.g., extra/expac)
    for (repo_names) |name| {
        const repo = self.pacman.syncDbFor(name);
        if (repo) |r| {
            const qualified = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ r, name });
            try qualified_names.append(self.allocator, qualified);
            try argv.append(self.allocator, qualified);
        } else {
            try argv.append(self.allocator, name);
        }
    }

    const exit_code = try self.auth.runInteractive(argv.items, null);
    if (exit_code != 0) {
        const ec = self.stderr_color;
        self.err_writer.print("{s}error:{s} installation failed (exit {d})\n", .{ ec.red, ec.reset, exit_code }) catch {};
        return false;
    }
    return true;
}

/// Pre-install chosen virtual-dep providers via `pacman -S --needed --asdeps`
/// so that makepkg -s finds them already installed and skips its own prompt.
/// Returns false if pacman exits non-zero.
pub fn preInstallProviders(self: *BuildContext, pkg_names: []const []const u8) !bool {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(self.allocator);
    try argv.appendSlice(self.allocator, &.{ "pacman", "-S", "--needed", "--asdeps", "--noconfirm" });
    try argv.appendSlice(self.allocator, pkg_names);
    const exit_code = try self.auth.runInteractive(argv.items, null);
    if (exit_code != 0) {
        const ec = self.stderr_color;
        self.err_writer.print("{s}error:{s} failed to pre-install providers (exit {d})\n", .{ ec.red, ec.reset, exit_code }) catch {};
        return false;
    }
    return true;
}

/// Collect the target names of every build entry whose pkgbase neither
/// failed nor was skipped. Matching is per entry (pkgbase), so split
/// packages whose names differ from their pkgbase are filtered correctly.
pub fn filterInstallable(allocator: Allocator, build_order: []const plan_mod.BuildEntry, failed: []const types.FailedBuild) ![]const []const u8 {
    var failed_set: std.StringHashMapUnmanaged(void) = .empty;
    defer failed_set.deinit(allocator);
    for (failed) |f| {
        try failed_set.put(allocator, f.pkgbase, {});
    }
    var installable: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer installable.deinit(allocator);
    for (build_order) |entry| {
        if (failed_set.contains(entry.pkgbase)) continue;
        try installable.appendSlice(allocator, entry.target_names);
    }
    return try installable.toOwnedSlice(allocator);
}

/// Delete package files from pacman's pkg cache so a rebuild with the same
/// version doesn't trigger a checksum mismatch on the stale cached copy.
/// Every configured CacheDir is checked; the files found are removed with
/// a single privileged `rm`.
pub fn purgePacmanCache(self: *BuildContext, basenames: []const []const u8) void {
    const paths = cachedPackagePaths(self.allocator, self.pacman.cacheDirs(), basenames) catch return;
    defer {
        for (paths) |p| self.allocator.free(p);
        self.allocator.free(paths);
    }
    if (paths.len == 0) return;

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(self.allocator);
    argv.appendSlice(self.allocator, &.{ "rm", "-f", "--" }) catch return;
    argv.appendSlice(self.allocator, paths) catch return;
    const result = self.auth.runCaptured(argv.items) catch return;
    result.deinit(self.allocator);
}

/// The files named `basenames` that exist in any of `cache_dirs`.
/// Caller owns the slice and its strings.
pub fn cachedPackagePaths(
    allocator: Allocator,
    cache_dirs: []const []const u8,
    basenames: []const []const u8,
) ![]const []const u8 {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    for (cache_dirs) |dir| {
        for (basenames) |basename| {
            const path = try std.fs.path.join(allocator, &.{ dir, basename });
            std.Io.Dir.accessAbsolute(std.Options.debug_io, path, .{}) catch {
                allocator.free(path);
                continue;
            };
            paths.append(allocator, path) catch |err| {
                allocator.free(path);
                return err;
            };
        }
    }
    return try paths.toOwnedSlice(allocator);
}

test "cachedPackagePaths finds built files in every cache directory" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    try tmp.dir.createDirPath(testing.io, "a");
    try tmp.dir.createDirPath(testing.io, "b");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/foo-1-1-any.pkg.tar.zst", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b/foo-1-1-any.pkg.tar.zst", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b/bar-2-1-any.pkg.tar.zst", .data = "" });

    const dir_a = try std.fs.path.join(testing.allocator, &.{ root, "a" });
    defer testing.allocator.free(dir_a);
    const dir_b = try std.fs.path.join(testing.allocator, &.{ root, "b/" });
    defer testing.allocator.free(dir_b);

    const paths = try cachedPackagePaths(
        testing.allocator,
        &.{ dir_a, dir_b },
        &.{ "foo-1-1-any.pkg.tar.zst", "bar-2-1-any.pkg.tar.zst", "baz-3-1-any.pkg.tar.zst" },
    );
    defer {
        for (paths) |p| testing.allocator.free(p);
        testing.allocator.free(paths);
    }

    try testing.expectEqual(@as(usize, 3), paths.len);
    try testing.expect(std.mem.endsWith(u8, paths[0], "/a/foo-1-1-any.pkg.tar.zst"));
    try testing.expect(std.mem.endsWith(u8, paths[1], "/b/foo-1-1-any.pkg.tar.zst"));
    try testing.expect(std.mem.endsWith(u8, paths[2], "/b/bar-2-1-any.pkg.tar.zst"));
}
