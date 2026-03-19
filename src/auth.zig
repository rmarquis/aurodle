const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

/// Privilege escalation abstraction.
///
/// Resolves how to run commands as root, following makepkg's PACMAN_AUTH
/// convention:
///   1. If PACMAN_AUTH is set → use it (with %c substitution if present)
///   2. Else if `sudo` is on PATH → prepend sudo
///   3. Else if `su` is on PATH → use su -c '%c'
///   4. Else → error
pub const Auth = struct {
    allocator: Allocator,
    kind: Kind,
    /// Allocated prefix tokens (e.g. ["sudo"] or ["doas", "-s"] or ["su", "-c"]).
    prefix: []const []const u8,
    /// For substitute mode: index of the token containing %c.
    subst_index: ?usize,

    const Kind = enum {
        /// sudo-style: prefix ++ command argv
        prepend,
        /// %c style: replace %c in one prefix token with the shell-quoted command
        substitute,
    };

    /// Resolve from PACMAN_AUTH config value (already parsed from makepkg.conf).
    /// Falls back to detecting sudo/su on PATH.
    pub fn init(allocator: Allocator, pacman_auth: ?[]const u8) !Auth {
        if (pacman_auth) |raw| {
            return initFromConfig(allocator, raw);
        }
        return initFromPath(allocator);
    }

    pub fn deinit(self: Auth) void {
        for (self.prefix) |tok| self.allocator.free(tok);
        self.allocator.free(self.prefix);
    }

    /// Build an escalated argv from a command. Caller owns the returned slice
    /// and each string in it (only the newly allocated ones — the original argv
    /// strings are borrowed, not duped).
    pub fn wrap(self: Auth, argv: []const []const u8) ![]const []const u8 {
        return switch (self.kind) {
            .prepend => self.wrapPrepend(argv),
            .substitute => self.wrapSubstitute(argv),
        };
    }

    /// Free a slice returned by wrap().
    pub fn freeWrapped(self: Auth, wrapped: []const []const u8) void {
        // In prepend mode, we only allocated the slice itself — tokens are borrowed.
        // In substitute mode, we allocated the substituted token.
        if (self.kind == .substitute) {
            if (self.subst_index) |idx| {
                // %c mode: the substituted token at idx was allocated by wrap().
                if (idx < wrapped.len) {
                    self.allocator.free(wrapped[idx]);
                }
            } else {
                // su -c mode: the appended quoted command is the last element.
                self.allocator.free(wrapped[wrapped.len - 1]);
            }
        }
        self.allocator.free(wrapped);
    }

    /// Run with captured I/O (for non-interactive commands like cp).
    pub fn runCaptured(self: Auth, argv: []const []const u8) !utils.ProcessResult {
        const wrapped = try self.wrap(argv);
        defer self.freeWrapped(wrapped);
        return utils.runCommand(self.allocator, wrapped);
    }

    /// Run interactively with inherited stdio (for pacman -S, mkarchroot, etc).
    pub fn runInteractive(self: Auth, argv: []const []const u8, cwd: ?[]const u8) !u8 {
        const wrapped = try self.wrap(argv);
        defer self.freeWrapped(wrapped);
        return utils.runInteractive(self.allocator, wrapped, cwd);
    }

    // ── Internal ─────────────────────────────────────────────────────

    fn initFromConfig(allocator: Allocator, raw: []const u8) !Auth {
        // Tokenize the raw PACMAN_AUTH value on whitespace.
        var tokens_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer tokens_list.deinit(allocator);

        var iter = std.mem.tokenizeAny(u8, raw, " \t");
        while (iter.next()) |tok| {
            try tokens_list.append(allocator, try allocator.dupe(u8, tok));
        }

        if (tokens_list.items.len == 0) {
            return error.EmptyPacmanAuth;
        }

        const tokens = try tokens_list.toOwnedSlice(allocator);

        // Check if any token contains %c → substitute mode.
        var subst_idx: ?usize = null;
        for (tokens, 0..) |tok, i| {
            if (std.mem.indexOf(u8, tok, "%c") != null) {
                subst_idx = i;
                break;
            }
        }

        return .{
            .allocator = allocator,
            .kind = if (subst_idx != null) .substitute else .prepend,
            .prefix = tokens,
            .subst_index = subst_idx,
        };
    }

    fn initFromPath(allocator: Allocator) !Auth {
        // Check for sudo first, then su (matching makepkg behavior).
        if (findOnPath("sudo")) {
            const tokens = try allocator.alloc([]const u8, 1);
            tokens[0] = try allocator.dupe(u8, "sudo");
            return .{
                .allocator = allocator,
                .kind = .prepend,
                .prefix = tokens,
                .subst_index = null,
            };
        }
        if (findOnPath("su")) {
            const tokens = try allocator.alloc([]const u8, 2);
            tokens[0] = try allocator.dupe(u8, "su");
            tokens[1] = try allocator.dupe(u8, "-c");
            return .{
                .allocator = allocator,
                .kind = .substitute,
                .prefix = tokens,
                // su -c expects the command as the next argument (no %c token),
                // so we append the quoted command after the prefix.
                .subst_index = null,
            };
        }
        return error.NoAuthMethod;
    }

    fn wrapPrepend(self: Auth, argv: []const []const u8) ![]const []const u8 {
        const result = try self.allocator.alloc([]const u8, self.prefix.len + argv.len);
        @memcpy(result[0..self.prefix.len], self.prefix);
        @memcpy(result[self.prefix.len..], argv);
        return result;
    }

    fn wrapSubstitute(self: Auth, argv: []const []const u8) ![]const []const u8 {
        const quoted_cmd = try shellJoin(self.allocator, argv);

        if (self.subst_index) |idx| {
            // Replace %c in the token at idx with the quoted command.
            const result = try self.allocator.alloc([]const u8, self.prefix.len);
            for (self.prefix, 0..) |tok, i| {
                if (i == idx) {
                    result[i] = try std.mem.replaceOwned(u8, self.allocator, tok, "%c", quoted_cmd);
                    self.allocator.free(quoted_cmd);
                } else {
                    result[i] = tok;
                }
            }
            return result;
        } else {
            // su -c style: append the quoted command as one argument.
            const result = try self.allocator.alloc([]const u8, self.prefix.len + 1);
            @memcpy(result[0..self.prefix.len], self.prefix);
            result[self.prefix.len] = quoted_cmd;
            return result;
        }
    }
};

/// Check if a binary exists on PATH.
fn findOnPath(name: []const u8) bool {
    const path_env = std.posix.getenv("PATH") orelse return false;
    var iter = std.mem.tokenizeScalar(u8, path_env, ':');
    while (iter.next()) |dir| {
        // Use a stack buffer to avoid allocation.
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        std.fs.accessAbsolute(full, .{}) catch continue;
        return true;
    }
    return false;
}

/// Join argv into a single shell-safe string.
/// Each argument is single-quoted, with embedded single quotes escaped as '\''.
pub fn shellJoin(allocator: Allocator, argv: []const []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    for (argv, 0..) |arg, i| {
        if (i > 0) try buf.append(allocator, ' ');
        try shellQuoteInto(allocator, &buf, arg);
    }

    return try buf.toOwnedSlice(allocator);
}

fn shellQuoteInto(allocator: Allocator, buf: *std.ArrayListUnmanaged(u8), arg: []const u8) !void {
    // If the argument contains no special characters, skip quoting.
    const needs_quoting = arg.len == 0 or for (arg) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '/' and c != '.' and c != '-' and c != '_' and c != '=' and c != ':' and c != '+' and c != ',') break true;
    } else false;

    if (!needs_quoting) {
        try buf.appendSlice(allocator, arg);
        return;
    }

    try buf.append(allocator, '\'');
    for (arg) |c| {
        if (c == '\'') {
            // End current quote, add escaped quote, restart quote: '\''
            try buf.appendSlice(allocator, "'\\''");
        } else {
            try buf.append(allocator, c);
        }
    }
    try buf.append(allocator, '\'');
}

// ── Tests ────────────────────────────────────────────────────────────────

test "shellJoin quotes arguments correctly" {
    const alloc = std.testing.allocator;

    const simple = try shellJoin(alloc, &.{ "pacman", "-S", "pkg" });
    defer alloc.free(simple);
    try std.testing.expectEqualStrings("pacman -S pkg", simple);

    const with_space = try shellJoin(alloc, &.{ "pacman", "-S", "my package" });
    defer alloc.free(with_space);
    try std.testing.expectEqualStrings("pacman -S 'my package'", with_space);

    const with_quote = try shellJoin(alloc, &.{ "echo", "it's" });
    defer alloc.free(with_quote);
    try std.testing.expectEqualStrings("echo 'it'\\''s'", with_quote);

    const empty_arg = try shellJoin(alloc, &.{ "cmd", "" });
    defer alloc.free(empty_arg);
    try std.testing.expectEqualStrings("cmd ''", empty_arg);
}

test "shellJoin no-quote for safe characters" {
    const alloc = std.testing.allocator;

    const result = try shellJoin(alloc, &.{ "/usr/bin/pacman", "--noconfirm", "extra/expac" });
    defer alloc.free(result);
    try std.testing.expectEqualStrings("/usr/bin/pacman --noconfirm extra/expac", result);
}

test "Auth.init prepend mode from config" {
    const alloc = std.testing.allocator;

    var auth = try Auth.init(alloc, "sudo");
    defer auth.deinit();

    try std.testing.expectEqual(Auth.Kind.prepend, auth.kind);
    try std.testing.expectEqual(@as(usize, 1), auth.prefix.len);
    try std.testing.expectEqualStrings("sudo", auth.prefix[0]);
}

test "Auth.init prepend mode with args" {
    const alloc = std.testing.allocator;

    var auth = try Auth.init(alloc, "sudo --askpass");
    defer auth.deinit();

    try std.testing.expectEqual(Auth.Kind.prepend, auth.kind);
    try std.testing.expectEqual(@as(usize, 2), auth.prefix.len);
    try std.testing.expectEqualStrings("sudo", auth.prefix[0]);
    try std.testing.expectEqualStrings("--askpass", auth.prefix[1]);
}

test "Auth.init substitute mode with %c" {
    const alloc = std.testing.allocator;

    var auth = try Auth.init(alloc, "su -c %c");
    defer auth.deinit();

    try std.testing.expectEqual(Auth.Kind.substitute, auth.kind);
    try std.testing.expectEqual(@as(usize, 3), auth.prefix.len);
    try std.testing.expectEqual(@as(?usize, 2), auth.subst_index);
}

test "Auth.init detects sudo on PATH" {
    // This test only runs if sudo is available (typical on Arch/dev machines).
    if (!findOnPath("sudo")) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var auth = try Auth.init(alloc, null);
    defer auth.deinit();

    try std.testing.expectEqual(Auth.Kind.prepend, auth.kind);
    try std.testing.expectEqualStrings("sudo", auth.prefix[0]);
}

test "Auth.wrap prepend mode builds correct argv" {
    const alloc = std.testing.allocator;

    var auth = try Auth.init(alloc, "sudo");
    defer auth.deinit();

    const wrapped = try auth.wrap(&.{ "pacman", "-S", "pkg" });
    defer auth.freeWrapped(wrapped);

    try std.testing.expectEqual(@as(usize, 4), wrapped.len);
    try std.testing.expectEqualStrings("sudo", wrapped[0]);
    try std.testing.expectEqualStrings("pacman", wrapped[1]);
    try std.testing.expectEqualStrings("-S", wrapped[2]);
    try std.testing.expectEqualStrings("pkg", wrapped[3]);
}

test "Auth.wrap prepend with multiple prefix tokens" {
    const alloc = std.testing.allocator;

    var auth = try Auth.init(alloc, "doas -s");
    defer auth.deinit();

    const wrapped = try auth.wrap(&.{ "pacman", "-S" });
    defer auth.freeWrapped(wrapped);

    try std.testing.expectEqual(@as(usize, 4), wrapped.len);
    try std.testing.expectEqualStrings("doas", wrapped[0]);
    try std.testing.expectEqualStrings("-s", wrapped[1]);
    try std.testing.expectEqualStrings("pacman", wrapped[2]);
    try std.testing.expectEqualStrings("-S", wrapped[3]);
}

test "Auth.wrap substitute mode replaces %c" {
    const alloc = std.testing.allocator;

    var auth = try Auth.init(alloc, "su -c %c");
    defer auth.deinit();

    const wrapped = try auth.wrap(&.{ "pacman", "-S", "pkg" });
    defer auth.freeWrapped(wrapped);

    try std.testing.expectEqual(@as(usize, 3), wrapped.len);
    try std.testing.expectEqualStrings("su", wrapped[0]);
    try std.testing.expectEqualStrings("-c", wrapped[1]);
    try std.testing.expectEqualStrings("pacman -S pkg", wrapped[2]);
}

test "Auth.wrap substitute with quoted args" {
    const alloc = std.testing.allocator;

    var auth = try Auth.init(alloc, "su -c %c");
    defer auth.deinit();

    const wrapped = try auth.wrap(&.{ "cp", "file with spaces", "/dest" });
    defer auth.freeWrapped(wrapped);

    try std.testing.expectEqual(@as(usize, 3), wrapped.len);
    try std.testing.expectEqualStrings("su", wrapped[0]);
    try std.testing.expectEqualStrings("-c", wrapped[1]);
    try std.testing.expectEqualStrings("cp 'file with spaces' /dest", wrapped[2]);
}

test "Auth.init empty config returns error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.EmptyPacmanAuth, Auth.init(alloc, ""));
}

test "Auth.init whitespace-only config returns error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.EmptyPacmanAuth, Auth.init(alloc, "   "));
}

test "findOnPath finds existing binary" {
    // /usr/bin/env should exist on any POSIX system.
    try std.testing.expect(findOnPath("env"));
}

test "findOnPath returns false for nonexistent binary" {
    try std.testing.expect(!findOnPath("this_binary_should_not_exist_xyz_42"));
}
