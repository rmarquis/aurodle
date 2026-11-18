//! Filtering `pacman -Ss` output: leave out the local AUR repository,
//! whose packages the AUR search lists again with their installed version.

const std = @import("std");
const Allocator = std.mem.Allocator;
const classify = @import("classify.zig");

/// `output` without the local repository's entries. An entry is a
/// `repo/name …` line and the indented description lines under it; with
/// -q, it is a bare name, left out when `classifier` finds it only in the
/// local repository. Colored output is matched without its escape codes.
/// Caller owns the result.
pub fn withoutLocalRepo(
    allocator: Allocator,
    output: []const u8,
    repo_name: []const u8,
    quiet: bool,
    classifier: anytype,
) ![]u8 {
    var kept: std.ArrayList(u8) = .empty;
    errdefer kept.deinit(allocator);

    var skipping = false;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (lines.peek() == null and line.len == 0) break;
        var buf: [256]u8 = undefined;
        const plain = stripEscapes(&buf, line);
        if (quiet) {
            skipping = classifier.source(plain) == .local_aur;
        } else if (plain.len > 0 and plain[0] != ' ') {
            skipping = isRepoEntry(plain, repo_name);
        }
        if (skipping) continue;
        try kept.appendSlice(allocator, line);
        try kept.append(allocator, '\n');
    }
    return kept.toOwnedSlice(allocator);
}

fn isRepoEntry(line: []const u8, repo_name: []const u8) bool {
    return line.len > repo_name.len and
        std.mem.startsWith(u8, line, repo_name) and
        line[repo_name.len] == '/';
}

/// The start of `line` without ANSI escape sequences, up to `buf.len`
/// bytes: enough to read a repository and package name.
fn stripEscapes(buf: []u8, line: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len and n < buf.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            i += 2;
            while (i < line.len and !std.ascii.isAlphabetic(line[i])) i += 1;
            i += 1;
            continue;
        }
        buf[n] = line[i];
        n += 1;
        i += 1;
    }
    return buf[0..n];
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

const FakeClassifier = struct {
    pub fn source(_: FakeClassifier, name: []const u8) classify.Source {
        if (std.mem.eql(u8, name, "yay")) return .local_aur;
        if (std.mem.eql(u8, name, "vim")) return .official;
        return .neither;
    }
};

fn expectFiltered(want: []const u8, output: []const u8, quiet: bool) !void {
    const got = try withoutLocalRepo(testing.allocator, output, "aur", quiet, FakeClassifier{});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "local repository entries and their descriptions are left out" {
    try expectFiltered(
        \\extra/vim 9.1-1 [installed]
        \\    Vi Improved
        \\
    ,
        \\extra/vim 9.1-1 [installed]
        \\    Vi Improved
        \\aur/yay 12.0-1 [installed]
        \\    Yet another yogurt
        \\    second description line
        \\
    , false);
}

test "a repository whose name starts with the local one's is kept" {
    try expectFiltered("aurx/foo 1-1\n    Foo\n", "aurx/foo 1-1\n    Foo\n", false);
}

test "colored entries are matched without escape codes" {
    const yay = "\x1b[1m\x1b[35maur/\x1b[0m\x1b[1myay \x1b[32m12.0-1\x1b[0m\n    Yet another yogurt\n";
    const vim = "\x1b[1m\x1b[35mextra/\x1b[0m\x1b[1mvim \x1b[32m9.1-1\x1b[0m\n    Vi Improved\n";
    try expectFiltered(vim, yay ++ vim, false);
}

test "with -q, names only in the local repository are left out" {
    try expectFiltered("vim\nfoo\n", "yay\nvim\nfoo\n", true);
}

test "empty output stays empty" {
    try expectFiltered("", "", false);
}
