const std = @import("std");
const Allocator = std.mem.Allocator;

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
        .Exited => |code| code,
        .Signal => |sig| @truncate(128 +| @as(u16, @intCast(sig))),
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

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = MAX_OUTPUT,
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

    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    try child.spawn();
    const term = try child.wait();
    return termToExitCode(term);
}

/// Run a command with privilege escalation (captured I/O).
/// Stdout/stderr are captured into ProcessResult.
///
/// Use for non-interactive sudo commands (cp, etc).
/// For interactive commands (pacman -S), use runSudoInteractive.
pub fn runSudo(
    allocator: Allocator,
    argv: []const []const u8,
) !ProcessResult {
    var sudo_argv: std.ArrayList([]const u8) = .empty;
    defer sudo_argv.deinit(allocator);
    try sudo_argv.ensureTotalCapacity(allocator, argv.len + 1);

    sudo_argv.appendAssumeCapacity("sudo");
    sudo_argv.appendSliceAssumeCapacity(argv);

    return runCommand(allocator, sudo_argv.items);
}

/// Run a command interactively with privilege escalation.
/// Inherits stdin/stdout/stderr so the user can interact with
/// sudo password prompts and pacman confirmation prompts.
pub fn runSudoInteractive(
    allocator: Allocator,
    argv: []const []const u8,
) !u8 {
    var sudo_argv: std.ArrayList([]const u8) = .empty;
    defer sudo_argv.deinit(allocator);
    try sudo_argv.ensureTotalCapacity(allocator, argv.len + 1);

    sudo_argv.appendAssumeCapacity("sudo");
    sudo_argv.appendSliceAssumeCapacity(argv);

    var child = std.process.Child.init(sudo_argv.items, allocator);
    try child.spawn();
    const term = try child.wait();
    return termToExitCode(term);
}

/// Prompt the user for yes/no confirmation.
/// Returns true for 'y' or 'Y', false for anything else.
/// If stdin is not a terminal (piped input), returns false
/// (fail-safe: don't auto-confirm in non-interactive mode).
pub fn promptYesNo(message: []const u8) !bool {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const stdin: std.fs.File = .{ .handle = std.posix.STDIN_FILENO };

    // Check if stdin is a terminal
    if (!std.posix.isatty(stdin.handle)) {
        return false;
    }

    const w = stdout.deprecatedWriter();
    try w.print(":: {s} [Y/n] ", .{message});

    var buf: [16]u8 = undefined;
    const n = stdin.read(&buf) catch return true;
    if (n == 0) return true;

    const response = std.mem.trim(u8, buf[0..n], " \t\n\r");
    if (response.len == 0) return true;
    return response[0] != 'n' and response[0] != 'N';
}

/// Expand ~ at the start of a path to $HOME.
/// Does NOT handle ~user syntax — only ~/path.
/// Returns a newly allocated string.
pub fn expandHome(allocator: Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return try allocator.dupe(u8, path);

    if (path[0] == '~') {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
        if (path.len == 1) {
            return try allocator.dupe(u8, home);
        }
        if (path[1] == '/') {
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, path[1..] });
        }
    }

    return try allocator.dupe(u8, path);
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

    const home = std.posix.getenv("HOME").?;
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

    const home = std.posix.getenv("HOME").?;
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
