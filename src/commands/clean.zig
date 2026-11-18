//! The clean command: remove stale clones, package files and database
//! entries from the local repository, after confirmation.

const output = @import("ui").output;
const term = @import("ui").term;
const repo_mod = @import("core").repo;
const repo_clean = @import("core").repo_clean;
const types = @import("types.zig");
const BuildContext = @import("build_context.zig").BuildContext;

const ExitCode = types.ExitCode;
const getStdout = output.getStdout;

/// Remove stale aurpkgs artifacts after user confirmation.
pub fn run(self: *BuildContext) !ExitCode {
    const ec = self.stderr_color;
    const repository = self.repository;

    const plan = if (self.flags.all) blk: {
        break :blk try repo_clean.findAll(repository);
    } else blk: {
        const uninstalled = self.pacman.uninstalledAurpkgs() catch |err| switch (err) {
            error.AurDbNotConfigured => {
                self.err_writer.print("{s}error:{s} local AUR repository not configured in pacman.conf\n", .{ ec.red, ec.reset });
                return .general_error;
            },
            else => return err,
        };
        defer self.allocator.free(uninstalled);

        break :blk try repo_clean.findStale(repository, uninstalled);
    };
    defer repo_clean.freeResult(repository, plan);

    if (plan.removed_clones.len == 0 and plan.removed_packages.len == 0 and
        plan.unreferenced_packages.len == 0 and plan.dangling_entries.len == 0)
    {
        if (!self.flags.quiet) getStdout().writeAll(" nothing to clean\n");
        return .success;
    }

    const stdout = getStdout();
    const c = self.stdout_color;

    const pkg_label = if (self.flags.all) "Packages" else "Stale packages";
    const clone_label = if (self.flags.all) "Clone directories" else "Stale clone directories";

    if (plan.removed_packages.len > 0) {
        stdout.print("{s}::{s} {s} ({d}):\n", .{ c.blue, c.reset, pkg_label, plan.removed_packages.len });
        for (plan.removed_packages) |filename| stdout.print("  {s}\n", .{filename});
    }

    if (plan.unreferenced_packages.len > 0) {
        stdout.print("{s}::{s} Old package files ({d}):\n", .{ c.blue, c.reset, plan.unreferenced_packages.len });
        for (plan.unreferenced_packages) |filename| stdout.print("  {s}\n", .{filename});
    }

    if (plan.dangling_entries.len > 0) {
        stdout.print("{s}::{s} Database entries with no package file ({d}):\n", .{ c.blue, c.reset, plan.dangling_entries.len });
        for (plan.dangling_entries) |name| stdout.print("  {s}\n", .{name});
    }

    if (plan.removed_clones.len > 0) {
        stdout.print("{s}::{s} {s} ({d}):\n", .{ c.blue, c.reset, clone_label, plan.removed_clones.len });
        for (plan.removed_clones) |name| stdout.print("  {s}/\n", .{name});
    }

    if (!self.flags.noconfirm) {
        const proceed = if (self.flags.all)
            try term.promptNoYesStyled(self.stdout_color, "Proceed with cleanup?")
        else
            try term.promptYesNoStyled(self.stdout_color, "Proceed with cleanup?");
        if (!proceed) return .success;
    }

    repo_clean.execute(repository, plan);

    if (plan.removed_packages.len > 0 or plan.dangling_entries.len > 0) {
        repo_mod.refreshAurpkgsSyncDb(self.allocator, repository, self.auth) catch |err| {
            self.err_writer.print("{s}warning:{s} failed to refresh aurpkgs sync db: {}\n", .{ ec.yellow, ec.reset, err });
        };
    }

    return .success;
}
