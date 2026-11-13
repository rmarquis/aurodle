//! Terminal interaction for the command-line frontend: confirmation and
//! provider prompts. Core modules must not import this file; they take
//! decisions as values or through callbacks (see provider.ProviderChooser).

const std = @import("std");
const color = @import("color.zig");
const provider_mod = @import("provider.zig");
const utils = @import("utils.zig");

const stdout = utils.stdout;
const flushStdout = utils.flushStdout;

/// Prompt the user for yes/no confirmation.
/// Returns true for 'y' or 'Y', false for anything else.
/// If stdin is not a terminal (piped input), returns false
/// (fail-safe: don't auto-confirm in non-interactive mode).
pub fn promptYesNo(message: []const u8) !bool {
    return promptYesNoStyled(color.Style.disabled, message);
}

pub fn promptYesNoStyled(c: color.Style, message: []const u8) !bool {
    return promptConfirm(c, message, true);
}

/// Like promptYesNoStyled, but pressing Enter declines. Use for destructive
/// actions, where only an explicit 'y' or 'Y' should confirm.
pub fn promptNoYesStyled(c: color.Style, message: []const u8) !bool {
    return promptConfirm(c, message, false);
}

fn promptConfirm(c: color.Style, message: []const u8, default: bool) !bool {
    if (!isTerminalFd(std.posix.STDIN_FILENO)) return false;
    const hint = if (default) "[Y/n]" else "[y/N]";
    stdout().print("{s}::{s} {s} {s} ", .{ c.blue, c.reset, message, hint }) catch {};
    flushStdout();

    var buf: [16]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return default;
    if (n == 0) return default;

    const response = std.mem.trim(u8, buf[0..n], " \t\n\r");
    if (response.len == 0) return default;
    if (default) return response[0] != 'n' and response[0] != 'N';
    return response[0] == 'y' or response[0] == 'Y';
}

fn isTerminalFd(fd: std.posix.fd_t) bool {
    return std.c.isatty(fd) != 0;
}

/// Prompt the user to choose a provider, matching pacman's format:
///
/// :: There are N providers available for <dep>:
/// :: Repository extra
///    1) jdk-openjdk  2) jre-openjdk  ...
/// :: Repository aurpkgs
///    5) jdk-openjdk-git
/// Enter a number (default=1):
///
/// Used directly for repo-dep provider selection; the registry reaches it
/// through `providerChooser`.
pub fn promptProviderChoice(
    dep_name: []const u8,
    candidates: []const provider_mod.ProviderCandidate,
    c: color.Style,
) ?usize {
    if (!isTerminalFd(std.posix.STDIN_FILENO)) return 0;
    flushStdout();
    std.debug.print("{s}::{s} There are {d} providers available for {s}:\n", .{ c.blue, c.reset, candidates.len, dep_name });

    // Group by db_name and display
    var num: usize = 1;
    var current_db: []const u8 = "";
    for (candidates) |cand| {
        if (!std.mem.eql(u8, cand.db_name, current_db)) {
            current_db = cand.db_name;
            std.debug.print("{s}::{s} Repository {s}\n   ", .{ c.blue, c.reset, current_db });
        }
        std.debug.print(" {d}) {s}", .{ num, cand.name });
        num += 1;
    }
    std.debug.print("\n", .{});

    // Prompt loop
    while (true) {
        std.debug.print("\nEnter a number (default=1): ", .{});

        var buf: [32]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return 0;
        if (n == 0) return 0;

        const response = std.mem.trim(u8, buf[0..n], " \t\n\r");
        if (response.len == 0) return 0; // default

        const choice = std.fmt.parseInt(usize, response, 10) catch 0;
        if (choice >= 1 and choice <= candidates.len) {
            return choice - 1;
        }
        std.debug.print("{s}warning:{s} invalid number: {s}", .{ c.yellow, c.reset, response });
    }
}

/// A registry provider chooser that prompts on the terminal, styled with
/// `style`. `style` must outlive the chooser.
pub fn providerChooser(style: *const color.Style) provider_mod.ProviderChooser {
    return .{ .ctx = @constCast(style), .choose_fn = promptProviderChoiceCallback };
}

fn promptProviderChoiceCallback(ctx: ?*anyopaque, dep_name: []const u8, candidates: []const provider_mod.ProviderCandidate) ?usize {
    const style: *const color.Style = @ptrCast(@alignCast(ctx.?));
    return promptProviderChoice(dep_name, candidates, style.*);
}

// ── Tests ────────────────────────────────────────────────────────────────

test "promptNoYesStyled returns false for non-terminal stdin" {
    try std.testing.expect(!try promptNoYesStyled(color.Style.disabled, "Continue?"));
}

test "promptYesNo returns false for non-terminal stdin" {
    const result = try promptYesNo("Continue?");
    try std.testing.expect(!result);
}
