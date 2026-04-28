/// Review phase: present PKGBUILD files and diffs to the user for inspection,
/// and prompt for conflict resolution before any packages are installed.
const std = @import("std");
const Allocator = std.mem.Allocator;
const git = @import("../../git.zig");
const solver_mod = @import("../../solver.zig");
const utils = @import("../../utils.zig");
const color = @import("../../color.zig");
const cmds = @import("../context.zig");

const Commands = cmds.Commands;

/// Resolve the preferred file viewer from the environment.
/// Priority: $PAGER → $VISUAL → $EDITOR → vim.
pub fn getViewer() []const u8 {
    if (std.posix.getenv("PAGER")) |p| if (p.len > 0) return p;
    if (std.posix.getenv("VISUAL")) |v| if (v.len > 0) return v;
    if (std.posix.getenv("EDITOR")) |e| if (e.len > 0) return e;
    return "vim";
}

/// For each build entry: if the clone was just updated show an interactive diff,
/// otherwise open all files in the viewer for fresh-clone review.
pub fn reviewPackages(
    self: *Commands,
    entries: []const solver_mod.BuildEntry,
    c_root: []const u8,
) !void {
    const stdout = cmds.getStdout();
    const sc = self.stdout_color;
    const editor = getViewer();

    for (entries) |entry| {
        const clone_dir = try git.cloneDir(self.allocator, c_root, entry.pkgbase);
        defer self.allocator.free(clone_dir);

        const is_update = git.hasOrigHead(self.allocator, c_root, entry.pkgbase) catch false;

        if (is_update) {
            const msg = try std.fmt.allocPrint(self.allocator, "View {s} diff?", .{entry.pkgbase});
            defer self.allocator.free(msg);

            if (try utils.promptYesNoStyled(self.stdout_color, msg)) {
                const exit_code = utils.runInteractive(
                    self.allocator,
                    &.{ "git", "diff", "--color=always", "ORIG_HEAD..HEAD" },
                    clone_dir,
                ) catch {
                    stdout.writeAll("  (could not show diff)\n") catch {};
                    continue;
                };
                _ = exit_code;
                stdout.print("{s}::{s} {s} diff reviewed\n", .{ sc.blue, sc.reset, entry.pkgbase }) catch {};
            }
        } else {
            const msg = try std.fmt.allocPrint(self.allocator, "Review {s} files?", .{entry.pkgbase});
            defer self.allocator.free(msg);

            if (try utils.promptYesNoStyled(self.stdout_color, msg)) {
                const exit_code = utils.runInteractive(
                    self.allocator,
                    &.{ editor, clone_dir },
                    null,
                ) catch {
                    stdout.writeAll("  (could not open editor)\n") catch {};
                    continue;
                };
                if (exit_code != 0) {
                    stdout.print("  editor exited with {d}\n", .{exit_code}) catch {};
                }
                stdout.print("{s}::{s} {s} files reviewed\n", .{ sc.blue, sc.reset, entry.pkgbase }) catch {};
            }
        }
    }
}

/// Prompt the user to resolve each detected conflict.
/// Returns the list of packages accepted for removal, or null if any conflict was rejected.
pub fn resolveConflicts(allocator: Allocator, conflicts: []const solver_mod.Conflict, c: color.Style) !?[]const []const u8 {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stdin: std.fs.File = .{ .handle = std.posix.STDIN_FILENO };
    if (!std.posix.isatty(stdin.handle)) return null;

    const w = stdout.deprecatedWriter();
    var removals: std.ArrayListUnmanaged([]const u8) = .empty;
    defer removals.deinit(allocator);

    for (conflicts) |conflict| {
        switch (conflict.kind) {
            .aur_aur => w.print(
                "{s}::{s} {s} and {s} are in conflict. Continue anyway? [y/N] ",
                .{ c.yellow, c.reset, conflict.package, conflict.conflicts_with },
            ) catch {},
            .aur_installed, .repo_installed => w.print(
                "{s}::{s} {s} and {s} are in conflict ({s}). Remove {s}? [y/N] ",
                .{ c.yellow, c.reset, conflict.package, conflict.conflicts_with, conflict.conflicts_with, conflict.conflicts_with },
            ) catch {},
            .aur_replaces => w.print(
                "{s}::{s} Replace {s} with aur/{s}? [y/N] ",
                .{ c.yellow, c.reset, conflict.conflicts_with, conflict.package },
            ) catch {},
            .repo_replaces => w.print(
                "{s}::{s} Replace {s} with {s}? [y/N] ",
                .{ c.yellow, c.reset, conflict.conflicts_with, conflict.package },
            ) catch {},
        }

        var buf: [16]u8 = undefined;
        const n = stdin.read(&buf) catch return null;
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
