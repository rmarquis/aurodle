/// Review phase: present PKGBUILD files and diffs to the user for inspection,
/// and prompt for conflict resolution before any packages are installed.
const std = @import("std");
const Allocator = std.mem.Allocator;
const git = @import("../git.zig");
const plan_mod = @import("../plan.zig");
const utils = @import("../utils.zig");
const color = @import("../color.zig");
const types = @import("types.zig");
const build_ctx = @import("build_context.zig");

const BuildContext = build_ctx.BuildContext;

/// Resolve the preferred file viewer from the environment.
/// Priority: $PAGER → $VISUAL → $EDITOR → vim.
pub fn getViewer() []const u8 {
    if (std.c.getenv("PAGER")) |p| if (std.mem.span(p).len > 0) return std.mem.span(p);
    if (std.c.getenv("VISUAL")) |v| if (std.mem.span(v).len > 0) return std.mem.span(v);
    if (std.c.getenv("EDITOR")) |e| if (std.mem.span(e).len > 0) return std.mem.span(e);
    return "vim";
}

/// Review each build entry's AUR files against the version last accepted
/// (the clone's HEAD; see git.CloneOrFetchResult):
/// - fresh clone: open all files in the viewer;
/// - AUR changes pending: show `git diff HEAD @{upstream}`, every change
///   since the last accepted version, however many runs ago it was fetched;
/// - nothing new: say so, and offer the local changes (`git diff HEAD`),
///   which for a VCS package is the pkgver line makepkg rewrote.
/// `clone_results[i]` is the clone/fetch result for `entries[i]`.
pub fn reviewPackages(
    self: *BuildContext,
    entries: []const plan_mod.BuildEntry,
    clone_results: []const git.CloneOrFetchResult,
    c_root: []const u8,
) !void {
    std.debug.assert(entries.len == clone_results.len);

    for (entries, clone_results) |entry, clone_result| {
        const clone_dir = try git.cloneDir(self.allocator, c_root, entry.pkgbase);
        defer self.allocator.free(clone_dir);

        switch (clone_result) {
            .cloned, .reCloned => try reviewFiles(self, entry.pkgbase, clone_dir),
            .pending => try reviewDiff(self, entry.pkgbase, clone_dir, "View {s} diff?", &.{ "git", "diff", "--color=always", "HEAD", "@{upstream}" }),
            .unchanged => {
                const sc = self.stdout_color;
                types.getStdout().print("{s}::{s} {s}: no AUR changes since your last review (aurodle show {s} to view all files)\n", .{ sc.blue, sc.reset, entry.pkgbase, entry.pkgbase });
                if (try hasLocalChanges(self.allocator, clone_dir)) {
                    try reviewDiff(self, entry.pkgbase, clone_dir, "View {s} local changes?", &.{ "git", "diff", "--color=always", "HEAD" });
                }
            },
        }
    }
}

/// Offer to open every file of a clone in the viewer.
fn reviewFiles(self: *BuildContext, pkgbase: []const u8, clone_dir: []const u8) !void {
    const stdout = types.getStdout();
    const sc = self.stdout_color;
    const msg = try std.fmt.allocPrint(self.allocator, "Review {s} files?", .{pkgbase});
    defer self.allocator.free(msg);
    if (!try utils.promptYesNoStyled(self.stdout_color, msg)) return;

    const editor = getViewer();
    const exit_code = utils.runInteractive(self.allocator, &.{ editor, clone_dir }, null) catch {
        stdout.writeAll("  (could not open editor)\n");
        return;
    };
    if (exit_code != 0) {
        stdout.print("  editor exited with {d}\n", .{exit_code});
    }
    stdout.print("{s}::{s} {s} files reviewed\n", .{ sc.blue, sc.reset, pkgbase });
}

/// Offer to run a `git diff` command in the clone.
fn reviewDiff(
    self: *BuildContext,
    pkgbase: []const u8,
    clone_dir: []const u8,
    comptime prompt: []const u8,
    argv: []const []const u8,
) !void {
    const stdout = types.getStdout();
    const sc = self.stdout_color;
    const msg = try std.fmt.allocPrint(self.allocator, prompt, .{pkgbase});
    defer self.allocator.free(msg);
    if (!try utils.promptYesNoStyled(self.stdout_color, msg)) return;

    _ = utils.runInteractive(self.allocator, argv, clone_dir) catch {
        stdout.writeAll("  (could not show diff)\n");
        return;
    };
    stdout.print("{s}::{s} {s} diff reviewed\n", .{ sc.blue, sc.reset, pkgbase });
}

/// Do tracked files differ from HEAD (e.g. the pkgver makepkg rewrote)?
fn hasLocalChanges(allocator: Allocator, clone_dir: []const u8) !bool {
    const result = try utils.runCommandIn(allocator, &.{ "git", "diff", "--quiet", "HEAD" }, clone_dir);
    defer result.deinit(allocator);
    return result.exit_code == 1;
}

/// Prompt the user to resolve each detected conflict.
/// Returns the list of packages accepted for removal, or null if any conflict was rejected.
pub fn resolveConflicts(allocator: Allocator, conflicts: []const plan_mod.Conflict, c: color.Style) !?[]const []const u8 {
    if (std.c.isatty(std.posix.STDIN_FILENO) == 0) return null;
    utils.flushStdout();

    var removals: std.ArrayListUnmanaged([]const u8) = .empty;
    defer removals.deinit(allocator);

    for (conflicts) |conflict| {
        switch (conflict.kind) {
            .aur_aur => std.debug.print(
                "{s}::{s} {s} and {s} are in conflict. Continue anyway? [y/N] ",
                .{ c.yellow, c.reset, conflict.package, conflict.conflicts_with },
            ),
            .aur_installed, .repo_installed => std.debug.print(
                "{s}::{s} {s} and {s} are in conflict ({s}). Remove {s}? [y/N] ",
                .{ c.yellow, c.reset, conflict.package, conflict.conflicts_with, conflict.conflicts_with, conflict.conflicts_with },
            ),
            .aur_replaces => std.debug.print(
                "{s}::{s} Replace {s} with aur/{s}? [y/N] ",
                .{ c.yellow, c.reset, conflict.conflicts_with, conflict.package },
            ),
            .repo_replaces => std.debug.print(
                "{s}::{s} Replace {s} with {s}? [y/N] ",
                .{ c.yellow, c.reset, conflict.conflicts_with, conflict.package },
            ),
        }

        var buf: [16]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return null;
        if (n == 0) return null;
        const response = std.mem.trim(u8, buf[0..n], " \t\n\r");
        if (response.len == 0 or (response[0] != 'y' and response[0] != 'Y')) return null;

        switch (conflict.kind) {
            .aur_installed, .repo_installed, .aur_replaces, .repo_replaces => {
                try removals.append(allocator, conflict.conflicts_with);
            },
            .aur_aur => {},
        }
    }
    return try removals.toOwnedSlice(allocator);
}
