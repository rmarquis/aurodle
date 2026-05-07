/// Installation phase: everything that invokes pacman or touches pacman's
/// state (sync DB refresh, cache purge, provider selection, credential setup).
const std = @import("std");
const Allocator = std.mem.Allocator;
const repo_mod = @import("../repo.zig");
const utils = @import("../utils.zig");
const registry_mod = @import("../registry.zig");
const pacman_mod = @import("../pacman.zig");
const color = @import("../color.zig");
const types = @import("types.zig");
const build_ctx = @import("build_context.zig");

const BuildContext = build_ctx.BuildContext;
const BuildResult = types.BuildResult;

/// Acquire privilege credentials and start the keepalive thread.
/// Called after the user has confirmed the plan and reviewed PKGBUILDs,
/// so we don't prompt for a password if they're going to bail out anyway.
/// Returns an ExitCode if acquisition failed, null on success.
pub fn acquireAuth(self: *BuildContext) !?types.ExitCode {
    const auth = self.auth;
    const ec = self.stderr_color;
    const cred_exit = auth.acquireCredentials() catch 0;
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
            if (chosen_pkgs.contains(m.provider_name)) {
                auto_idx = i;
                break;
            }
        }

        const chosen_idx = if (auto_idx) |i| i else blk: {
            if (noconfirm) break :blk @as(usize, 0);
            var candidates: std.ArrayListUnmanaged(registry_mod.ProviderCandidate) = .empty;
            defer candidates.deinit(allocator);
            for (choice.candidates) |m| {
                try candidates.append(allocator, .{
                    .name = m.provider_name,
                    .version = m.provider_version,
                    .db_name = m.db_name,
                });
            }
            const idx = utils.promptProviderChoice(choice.dep_name, candidates.items, c);
            break :blk idx orelse 0;
        };

        const chosen_name = choice.candidates[chosen_idx].provider_name;
        try chosen_providers.put(allocator, choice.dep_name, chosen_name);
        if (!chosen_pkgs.contains(chosen_name)) {
            try chosen_pkgs.put(allocator, chosen_name, {});
            try providers_to_install.append(allocator, chosen_name);
        }
    }
}

/// Install AUR targets (from aurpkgs) and repo targets (from their sync db)
/// in a single `pacman -S` transaction.
pub fn installAllTargets(self: *BuildContext, aurpkgs_names: []const []const u8, repo_names: []const []const u8) !void {
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
    }
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

/// Filter the AUR targets list down to packages whose builds succeeded.
pub fn filterInstallable(self: *BuildContext, targets: []const []const u8, result: BuildResult) ![]const []const u8 {
    var failed_set: std.StringHashMapUnmanaged(void) = .empty;
    defer failed_set.deinit(self.allocator);
    for (result.failed) |f| {
        try failed_set.put(self.allocator, f.pkgbase, {});
    }
    var installable: std.ArrayListUnmanaged([]const u8) = .empty;
    for (targets) |target| {
        if (!failed_set.contains(target)) {
            try installable.append(self.allocator, target);
        }
    }
    return try installable.toOwnedSlice(self.allocator);
}

/// Delete package files from pacman's pkg cache so a rebuild with the same
/// version doesn't trigger a checksum mismatch on the stale cached copy.
pub fn purgePacmanCache(self: *BuildContext, basenames: []const []const u8) void {
    for (basenames) |basename| {
        const cache_path = std.fmt.allocPrint(self.allocator, "/var/cache/pacman/pkg/{s}", .{basename}) catch continue;
        defer self.allocator.free(cache_path);
        std.Io.Dir.accessAbsolute(std.Options.debug_io, cache_path, .{}) catch continue;
        const result = self.auth.runCaptured(&.{ "rm", "-f", cache_path }) catch continue;
        result.deinit(self.allocator);
    }
}
