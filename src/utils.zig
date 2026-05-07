const std = @import("std");
const Allocator = std.mem.Allocator;
const color = @import("color.zig");

/// Runtime I/O implementation. Set from `init.io` in `main` so that process
/// spawning (which is incompatible with `std.Options.debug_io` in Zig 0.16.0)
/// uses the correct backend.
pub var global_io: std.Io = std.Options.debug_io;

fn currentIo() std.Io {
    return if (@import("builtin").is_test) std.testing.io else global_io;
}

/// Max output size we'll capture from a child process.
const MAX_OUTPUT = 10 * 1024 * 1024;

pub const ProcessResult = struct {
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,

    pub fn deinit(self: ProcessResult, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    pub fn success(self: ProcessResult) bool {
        return self.exit_code == 0;
    }
};

fn termToExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| @truncate(128 +| @as(u16, @intCast(@intFromEnum(sig)))),
        else => 1,
    };
}

/// Spawn a child process, capture stdout and stderr, wait for completion.
///
/// Both stdout and stderr are fully captured into memory. This is appropriate
/// for short-lived commands (git, repo-add) where output is small.
pub fn runCommand(
    allocator: Allocator,
    argv: []const []const u8,
) !ProcessResult {
    return runCommandIn(allocator, argv, null);
}

/// Like runCommand but with an explicit working directory.
pub fn runCommandIn(
    allocator: Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
) !ProcessResult {
    if (argv.len == 0) return error.SpawnFailed;

    const io = currentIo();
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = if (cwd) |p| .{ .path = p } else .inherit,
    });

    return .{
        .exit_code = termToExitCode(result.term),
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

/// Spawn a process with inherited stdio (stdin/stdout/stderr).
/// Returns only the exit code. Use for long-running interactive commands
/// like makepkg where the user needs real-time terminal output.
pub fn runInteractive(
    allocator: Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
) !u8 {
    if (argv.len == 0) return error.SpawnFailed;
    _ = allocator;

    const io = currentIo();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |p| .{ .path = p } else .inherit,
    });
    const term = try child.wait(io);
    return termToExitCode(term);
}

/// Prompt the user for yes/no confirmation.
/// Returns true for 'y' or 'Y', false for anything else.
/// If stdin is not a terminal (piped input), returns false
/// (fail-safe: don't auto-confirm in non-interactive mode).
pub fn promptYesNo(message: []const u8) !bool {
    return promptYesNoStyled(color.Style.disabled, message);
}

pub fn promptYesNoStyled(c: color.Style, message: []const u8) !bool {
    if (!isTerminalFd(std.posix.STDIN_FILENO)) return false;
    var prompt_buf: [256]u8 = undefined;
    const prompt = std.fmt.bufPrint(&prompt_buf, "{s}::{s} {s} [Y/n] ", .{ c.blue, c.reset, message }) catch "";
    _ = std.os.linux.write(std.posix.STDOUT_FILENO, prompt.ptr, prompt.len);

    var buf: [16]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return true;
    if (n == 0) return true;

    const response = std.mem.trim(u8, buf[0..n], " \t\n\r");
    if (response.len == 0) return true;
    return response[0] != 'n' and response[0] != 'N';
}

fn isTerminalFd(fd: std.posix.fd_t) bool {
    return std.c.isatty(fd) != 0;
}

/// Check if a binary exists on PATH.
pub fn findOnPath(name: []const u8) bool {
    const path_ptr = std.c.getenv("PATH") orelse return false;
    const path_env = std.mem.span(path_ptr);
    var iter = std.mem.tokenizeScalar(u8, path_env, ':');
    while (iter.next()) |dir| {
        // Use a stack buffer to avoid allocation.
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        std.Io.Dir.accessAbsolute(std.Options.debug_io, full, .{}) catch continue;
        return true;
    }
    return false;
}

const provider_mod = @import("provider.zig");

/// Prompt the user to choose a provider, matching pacman's format:
///
/// :: There are N providers available for <dep>:
/// :: Repository extra
///    1) jdk-openjdk  2) jre-openjdk  ...
/// :: Repository aurpkgs
///    5) jdk-openjdk-git
/// Enter a number (default=1):
///
/// Signature matches `ProviderChooserFn`.
pub fn promptProviderChoice(
    dep_name: []const u8,
    candidates: []const provider_mod.ProviderCandidate,
    c: color.Style,
) ?usize {
    if (!isTerminalFd(std.posix.STDIN_FILENO)) return 0;
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

        const choice = std.fmt.parseInt(usize, response, 10) catch {
            std.debug.print(":: Invalid number, try again.", .{});
            continue;
        };
        if (choice >= 1 and choice <= candidates.len) {
            return choice - 1;
        }
        std.debug.print(":: Invalid number, try again.", .{});
    }
}

/// Expand ~ at the start of a path to $HOME.
/// Does NOT handle ~user syntax — only ~/path.
/// Returns a newly allocated string.
pub fn expandHome(allocator: Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return try allocator.dupe(u8, path);

    if (path[0] == '~') {
        const home = if (std.c.getenv("HOME")) |p| std.mem.span(p) else return error.NoHomeDirectory;
        if (path.len == 1) {
            return try allocator.dupe(u8, home);
        }
        if (path[1] == '/') {
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, path[1..] });
        }
    }

    return try allocator.dupe(u8, path);
}

/// Check if a path exists and is a directory.
pub fn dirExists(path: []const u8) bool {
    const stat = std.Io.Dir.statFile(std.Io.Dir.cwd(), std.Options.debug_io, path, .{}) catch return false;
    return stat.kind == .directory;
}

// ── Tests ────────────────────────────────────────────────────────────────

test "runCommand captures stdout and stderr" {
    const result = try runCommand(std.testing.allocator, &.{
        "sh", "-c", "echo hello && echo error >&2",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("hello\n", result.stdout);
    try std.testing.expectEqualStrings("error\n", result.stderr);
}

test "runCommand returns nonzero exit code on failure" {
    const result = try runCommand(std.testing.allocator, &.{
        "sh", "-c", "exit 42",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 42), result.exit_code);
}

test "runCommand success helper" {
    const ok = try runCommand(std.testing.allocator, &.{"true"});
    defer ok.deinit(std.testing.allocator);
    try std.testing.expect(ok.success());

    const fail = try runCommand(std.testing.allocator, &.{"false"});
    defer fail.deinit(std.testing.allocator);
    try std.testing.expect(!fail.success());
}

test "runCommandIn uses specified working directory" {
    const result = try runCommandIn(std.testing.allocator, &.{
        "pwd",
    }, "/tmp");
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/tmp\n", result.stdout);
}

test "runCommand maps signal termination to 128+signal" {
    const result = try runCommand(std.testing.allocator, &.{
        "sh", "-c", "kill -TERM $$",
    });
    defer result.deinit(std.testing.allocator);

    // SIGTERM = 15, so exit code = 128 + 15 = 143
    try std.testing.expectEqual(@as(u8, 143), result.exit_code);
}

test "runCommand empty argv returns SpawnFailed" {
    const empty: []const []const u8 = &.{};
    try std.testing.expectError(error.SpawnFailed, runCommand(std.testing.allocator, empty));
}

test "promptYesNo returns false for non-terminal stdin" {
    const result = try promptYesNo("Continue?");
    try std.testing.expect(!result);
}

test "expandHome replaces tilde with HOME" {
    const result = try expandHome(std.testing.allocator, "~/foo/bar");
    defer std.testing.allocator.free(result);

    const home = std.mem.span(std.c.getenv("HOME").?);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/foo/bar", .{home});
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, result);
}

test "expandHome returns non-tilde paths unchanged" {
    const result = try expandHome(std.testing.allocator, "/absolute/path");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("/absolute/path", result);
}

test "expandHome handles bare tilde" {
    const result = try expandHome(std.testing.allocator, "~");
    defer std.testing.allocator.free(result);

    const home = std.mem.span(std.c.getenv("HOME").?);
    try std.testing.expectEqualStrings(home, result);
}

test "expandHome returns empty string unchanged" {
    const result = try expandHome(std.testing.allocator, "");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "expandHome does not expand ~user syntax" {
    const result = try expandHome(std.testing.allocator, "~nobody/foo");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("~nobody/foo", result);
}

test "findOnPath finds existing binary" {
    // /usr/bin/env should exist on any POSIX system.
    try std.testing.expect(findOnPath("env"));
}

test "findOnPath returns false for nonexistent binary" {
    try std.testing.expect(!findOnPath("this_binary_should_not_exist_xyz_42"));
}
