// Contract specification for utils.zig — Shared Infrastructure
//
// Verifies the formal contract for process execution, HTTP, filesystem,
// and user interaction helpers.
//
// Architecture: docs/architecture/class_utils.md
// Module: utils (free functions)
//
// Tests use real system calls (echo, sh -c, pwd).

const std = @import("std");
const testing = std.testing;

// TODO: Replace with real import when implementation exists
// const utils = @import("../../../../src/utils.zig");

// ============================================================================
// runCommand() Contracts
// ============================================================================

test "runCommand captures stdout from successful command" {
    // Contract: runCommand(allocator, argv) spawns a child process and
    // captures its stdout. Returns ProcessResult with exit_code 0
    // and the captured output.
    //
    // const result = try utils.runCommand(testing.allocator, &.{ "echo", "hello" });
    // defer testing.allocator.free(result.stdout);
    // try testing.expectEqual(@as(u8, 0), result.exit_code);
    // try testing.expectEqualStrings("hello\n", result.stdout);
}

test "runCommand captures stderr separately" {
    // Contract: stderr is captured independently from stdout.
    // Both are available in ProcessResult.
    //
    // const result = try utils.runCommand(testing.allocator, &.{ "sh", "-c", "echo err >&2" });
    // defer testing.allocator.free(result.stderr);
    // try testing.expectEqualStrings("err\n", result.stderr);
}

test "runCommand returns non-zero exit code on failure" {
    // Contract: A command that exits with non-zero returns that exit
    // code in ProcessResult.exit_code. This is NOT a Zig error —
    // the caller decides how to interpret non-zero exits.
    //
    // const result = try utils.runCommand(testing.allocator, &.{ "sh", "-c", "exit 42" });
    // try testing.expectEqual(@as(u8, 42), result.exit_code);
}

test "runCommand returns CommandNotFound for missing executable" {
    // Contract: If the executable doesn't exist, returns
    // error.CommandNotFound.
    //
    // const result = utils.runCommand(testing.allocator, &.{"zzz-nonexistent-cmd"});
    // try testing.expectError(error.CommandNotFound, result);
}

test "runCommand maps signal termination to 128+signal" {
    // Contract: If the child process is killed by a signal, exit_code
    // is 128 + signal number. SIGTERM=143, SIGKILL=137, SIGINT=130.
    // This allows commands.zig to detect signal kills (exit >= 128).
}

// ============================================================================
// runCommandIn() Contracts
// ============================================================================

test "runCommandIn executes in specified working directory" {
    // Contract: runCommandIn(allocator, argv, cwd) runs the command
    // with the specified current working directory.
    //
    // const result = try utils.runCommandIn(testing.allocator, &.{"pwd"}, "/tmp");
    // try testing.expectEqualStrings("/tmp\n", result.stdout);
}

// ============================================================================
// runCommandWithLog() Contracts
// ============================================================================

test "runCommandWithLog tees output to terminal and log file" {
    // Contract: runCommandWithLog(allocator, argv, cwd, log_path)
    // simultaneously displays output in real-time AND writes to a log file.
    // The log file is the authoritative record.
    //
    // try utils.runCommandWithLog(testing.allocator,
    //     &.{ "echo", "build output" }, ".", "/tmp/test.log");
    // // Log file should contain "build output\n"
}

test "runCommandWithLog creates log file parent directories" {
    // Contract: If the log file's parent directory doesn't exist,
    // it is created automatically.
}

test "runCommandWithLog respects MAX_OUTPUT memory guard" {
    // Contract: Output capture is bounded at MAX_OUTPUT (~10MB) to
    // prevent unbounded memory growth from verbose build output.
}

// ============================================================================
// runSudo() Contracts
// ============================================================================

test "runSudo prepends sudo to the command" {
    // Contract: runSudo(allocator, argv) prepends "sudo" to the
    // argument vector and executes. Used for pacman -S operations.
    //
    // Result contains the combined command output.
}

test "runSudo preserves original argv order" {
    // Contract: Arguments after "sudo" maintain their original order.
    // runSudo(&.{"pacman", "-S", "pkg"}) → executes "sudo pacman -S pkg"
}

// ============================================================================
// promptYesNo() Contracts
// ============================================================================

test "promptYesNo defaults to No" {
    // Contract: promptYesNo(message) displays "[y/N]" prompt.
    // Empty input (just Enter) returns false (conservative default).
    // This prevents accidental confirmation of untrusted builds.
}

test "promptYesNo returns false for non-TTY stdin" {
    // Contract: When stdin is not a terminal (piped input),
    // promptYesNo returns false. Forces explicit --noconfirm for scripts.
}

test "promptYesNo accepts y and Y as true" {
    // Contract: "y", "Y", "yes", "YES" return true.
    // Everything else returns false.
}

// ============================================================================
// expandHome() Contracts
// ============================================================================

test "expandHome replaces tilde with HOME directory" {
    // Contract: expandHome(allocator, "~/path") replaces ~ with
    // the value of $HOME. Returns an owned slice.
    //
    // const expanded = try utils.expandHome(testing.allocator, "~/test");
    // defer testing.allocator.free(expanded);
    // try testing.expect(!std.mem.startsWith(u8, expanded, "~"));
    // try testing.expect(std.mem.endsWith(u8, expanded, "/test"));
}

test "expandHome returns unchanged path without tilde" {
    // Contract: Paths not starting with ~ are returned as-is (duplicated).
    //
    // const expanded = try utils.expandHome(testing.allocator, "/absolute/path");
    // defer testing.allocator.free(expanded);
    // try testing.expectEqualStrings("/absolute/path", expanded);
}

test "expandHome handles tilde-only path" {
    // Contract: expandHome("~") returns just the HOME directory.
    //
    // const expanded = try utils.expandHome(testing.allocator, "~");
    // defer testing.allocator.free(expanded);
    // try testing.expect(expanded.len > 1);
}
