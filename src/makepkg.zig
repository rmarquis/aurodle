//! Read-only access to makepkg's configuration.
//!
//! makepkg.conf is a bash file. It is only ever parsed here, never executed,
//! so expansions are literal text and a conditional assignment counts as an
//! assignment.

const std = @import("std");
const utils = @import("utils.zig");
const Allocator = std.mem.Allocator;

pub const DEFAULT_PKGEXT = ".pkg.tar.zst";

const SYSTEM_CONF = "/etc/makepkg.conf";
const MAX_CONF_BYTES = 64 * 1024;

const Key = enum { pkgdest, pkgext, pacman_auth };

const KEYS = [_]struct { name: []const u8, key: Key }{
    .{ .name = "PKGDEST", .key = .pkgdest },
    .{ .name = "PKGEXT", .key = .pkgext },
    .{ .name = "PACMAN_AUTH", .key = .pacman_auth },
};

/// Parsed makepkg.conf values used by Repository initialization.
pub const MakepkgConfig = struct {
    pkgdest: ?[]const u8 = null,
    pkgext: []const u8 = DEFAULT_PKGEXT,
    owns_pkgext: bool = false,
    /// PACMAN_AUTH as separate argv words, the way makepkg expands the array.
    pacman_auth: ?[]const []const u8 = null,

    pub fn deinit(self: MakepkgConfig, allocator: Allocator) void {
        if (self.pkgdest) |p| allocator.free(p);
        if (self.owns_pkgext) allocator.free(self.pkgext);
        if (self.pacman_auth) |words| freeWords(allocator, words);
    }

    /// Replace `key` with an assignment's words. No words clears the value.
    /// `words` is copied. A scalar key takes the first word, as `$VAR` does.
    fn assign(self: *MakepkgConfig, allocator: Allocator, key: Key, words: []const []const u8) Allocator.Error!void {
        switch (key) {
            .pkgdest => {
                const new = if (words.len > 0) try allocator.dupe(u8, words[0]) else null;
                if (self.pkgdest) |old| allocator.free(old);
                self.pkgdest = new;
            },
            .pkgext => {
                const new = if (words.len > 0) try allocator.dupe(u8, words[0]) else null;
                if (self.owns_pkgext) allocator.free(self.pkgext);
                self.pkgext = new orelse DEFAULT_PKGEXT;
                self.owns_pkgext = new != null;
            },
            .pacman_auth => {
                const new = if (words.len > 0) try dupeWords(allocator, words) else null;
                if (self.pacman_auth) |old| freeWords(allocator, old);
                self.pacman_auth = new;
            },
        }
    }
};

/// Where makepkg's configuration files live.
const Paths = struct {
    system: []const u8,
    xdg_config_home: ?[]const u8,
    home: ?[]const u8,
};

/// Read PKGDEST, PKGEXT and PACMAN_AUTH from makepkg's configuration files, in
/// makepkg's order. A non-empty environment variable overrides the files.
pub fn parseMakepkgConf(allocator: Allocator) !MakepkgConfig {
    var config = MakepkgConfig{};
    errdefer config.deinit(allocator);

    try readConfFiles(allocator, .{
        .system = SYSTEM_CONF,
        .xdg_config_home = nonEmptyEnv("XDG_CONFIG_HOME"),
        .home = nonEmptyEnv("HOME"),
    }, &config);

    if (nonEmptyEnv("PKGDEST")) |value| try config.assign(allocator, .pkgdest, &.{value});
    if (nonEmptyEnv("PKGEXT")) |value| try config.assign(allocator, .pkgext, &.{value});
    if (nonEmptyEnv("PACMAN_AUTH")) |value| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const words = try splitWords(arena.allocator(), value);
        if (words.len > 0) try config.assign(allocator, .pacman_auth, words);
    }

    return config;
}

/// Fold one makepkg.conf file into `config`. A file that cannot be read is
/// skipped.
pub fn parseMakepkgConfFromFile(allocator: Allocator, path: []const u8, config: *MakepkgConfig) Allocator.Error!void {
    var buf: [MAX_CONF_BYTES]u8 = undefined;
    const content = std.Io.Dir.readFile(std.Io.Dir.cwd(), utils.currentIo(), path, &buf) catch return;
    try parseContent(allocator, content, config);
}

// ── Internal Helpers ─────────────────────────────────────────────────────

fn nonEmptyEnv(name: [*:0]const u8) ?[]const u8 {
    const value = std.mem.span(std.c.getenv(name) orelse return null);
    return if (value.len > 0) value else null;
}

fn dupeWords(allocator: Allocator, words: []const []const u8) Allocator.Error![]const []const u8 {
    const copy = try allocator.alloc([]const u8, words.len);
    var done: usize = 0;
    errdefer {
        for (copy[0..done]) |word| allocator.free(word);
        allocator.free(copy);
    }
    for (words) |word| {
        copy[done] = try allocator.dupe(u8, word);
        done += 1;
    }
    return copy;
}

fn freeWords(allocator: Allocator, words: []const []const u8) void {
    for (words) |word| allocator.free(word);
    allocator.free(words);
}

/// Read each file in makepkg's order, so later files override earlier ones:
/// the system file, its drop-ins, then one user file.
fn readConfFiles(allocator: Allocator, paths: Paths, config: *MakepkgConfig) Allocator.Error!void {
    try parseMakepkgConfFromFile(allocator, paths.system, config);
    try readDropIns(allocator, paths.system, config);
    try readUserFile(allocator, paths, config);
}

/// Read `<system>.d/*.conf` in sorted order, as makepkg's shell glob does. Like
/// the glob, this skips hidden files.
fn readDropIns(allocator: Allocator, system: []const u8, config: *MakepkgConfig) Allocator.Error!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const io = utils.currentIo();
    const dir_path = try std.fmt.allocPrint(a, "{s}.d", .{system});
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.name[0] != '.' and std.mem.endsWith(u8, entry.name, ".conf")) {
            try names.append(a, try a.dupe(u8, entry.name));
        }
    }

    std.mem.sort([]const u8, names.items, {}, lessThanString);
    for (names.items) |name| {
        const path = try std.fs.path.join(a, &.{ dir_path, name });
        try parseMakepkgConfFromFile(allocator, path, config);
    }
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// makepkg reads the XDG file *or* the legacy one, never both.
fn readUserFile(allocator: Allocator, paths: Paths, config: *MakepkgConfig) Allocator.Error!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const xdg: ?[]const u8 = if (paths.xdg_config_home) |dir|
        try std.fs.path.join(a, &.{ dir, "pacman", "makepkg.conf" })
    else if (paths.home) |home|
        try std.fs.path.join(a, &.{ home, ".config", "pacman", "makepkg.conf" })
    else
        null;

    if (xdg) |path| {
        if (std.Io.Dir.cwd().access(utils.currentIo(), path, .{ .read = true })) |_| {
            return parseMakepkgConfFromFile(allocator, path, config);
        } else |_| {}
    }

    if (paths.home) |home| {
        const legacy = try std.fs.path.join(a, &.{ home, ".makepkg.conf" });
        try parseMakepkgConfFromFile(allocator, legacy, config);
    }
}

/// Apply each assignment in makepkg.conf text to `config`.
fn parseContent(allocator: Allocator, content: []const u8, config: *MakepkgConfig) Allocator.Error!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var pos: usize = 0;
    while (pos < content.len) {
        while (pos < content.len and (content[pos] == ' ' or content[pos] == '\t')) pos += 1;
        for (KEYS) |entry| {
            const rest = content[pos..];
            if (rest.len > entry.name.len and std.mem.startsWith(u8, rest, entry.name) and rest[entry.name.len] == '=') {
                pos += entry.name.len + 1;
                try config.assign(allocator, entry.key, try parseValue(arena.allocator(), content, &pos));
                break;
            }
        }
        const newline = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse break;
        pos = newline + 1;
    }
}

/// Read a scalar or array value starting at `pos.*`. Returns no words for an
/// empty assignment.
fn parseValue(allocator: Allocator, content: []const u8, pos: *usize) Allocator.Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;

    if (pos.* >= content.len or content[pos.*] != '(') {
        if (pos.* < content.len and !isWordEnd(content[pos.*], .scalar)) {
            const word = try readWord(allocator, content, pos, .scalar);
            if (word.len > 0) try words.append(allocator, word);
        }
        return words.toOwnedSlice(allocator);
    }

    pos.* += 1;
    while (pos.* < content.len) {
        const c = content[pos.*];
        if (c == ')') {
            pos.* += 1;
            break;
        }
        if (std.ascii.isWhitespace(c)) {
            pos.* += 1;
        } else if (c == '#') {
            pos.* = std.mem.indexOfScalarPos(u8, content, pos.*, '\n') orelse content.len;
        } else {
            try words.append(allocator, try readWord(allocator, content, pos, .array));
        }
    }
    return words.toOwnedSlice(allocator);
}

/// Split an environment value into words, honouring quotes.
fn splitWords(allocator: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var pos: usize = 0;
    while (pos < text.len) {
        if (std.ascii.isWhitespace(text[pos])) {
            pos += 1;
        } else {
            try words.append(allocator, try readWord(allocator, text, &pos, .plain));
        }
    }
    return words.toOwnedSlice(allocator);
}

const WordContext = enum { scalar, array, plain };

/// Whitespace ends every word, so a `#` inside one is literal, as in bash.
fn isWordEnd(c: u8, context: WordContext) bool {
    if (std.ascii.isWhitespace(c)) return true;
    return switch (context) {
        .scalar => c == ';',
        .array => c == ')',
        .plain => false,
    };
}

/// Read one bash word: unquoted, single-quoted and double-quoted runs join up.
fn readWord(allocator: Allocator, content: []const u8, pos: *usize, context: WordContext) Allocator.Error![]const u8 {
    var word: std.ArrayList(u8) = .empty;
    var i = pos.*;
    while (i < content.len and !isWordEnd(content[i], context)) {
        switch (content[i]) {
            '\'' => {
                const close = std.mem.indexOfScalarPos(u8, content, i + 1, '\'') orelse content.len;
                try word.appendSlice(allocator, content[i + 1 .. close]);
                i = @min(close + 1, content.len);
            },
            '"' => {
                i += 1;
                while (i < content.len and content[i] != '"') : (i += 1) {
                    if (content[i] == '\\' and i + 1 < content.len and
                        std.mem.indexOfScalar(u8, "\"\\$`", content[i + 1]) != null) i += 1;
                    try word.append(allocator, content[i]);
                }
                i = @min(i + 1, content.len);
            },
            '\\' => {
                if (i + 1 < content.len) try word.append(allocator, content[i + 1]);
                i = @min(i + 2, content.len);
            },
            else => {
                try word.append(allocator, content[i]);
                i += 1;
            },
        }
    }
    pos.* = i;
    return word.toOwnedSlice(allocator);
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectWords(actual: ?[]const []const u8, expected: []const []const u8) !void {
    const words = actual orelse return error.TestExpectedWords;
    try testing.expectEqual(expected.len, words.len);
    for (expected, words) |e, a| try testing.expectEqualStrings(e, a);
}

fn expectAuth(content: []const u8, expected: []const []const u8) !void {
    var config = MakepkgConfig{};
    defer config.deinit(testing.allocator);
    try parseContent(testing.allocator, content, &config);
    try expectWords(config.pacman_auth, expected);
}

fn expectPkgdest(content: []const u8, expected: ?[]const u8) !void {
    var config = MakepkgConfig{};
    defer config.deinit(testing.allocator);
    try parseContent(testing.allocator, content, &config);
    if (expected) |e| {
        try testing.expectEqualStrings(e, config.pkgdest orelse return error.TestExpectedValue);
    } else {
        try testing.expect(config.pkgdest == null);
    }
}

test "PACMAN_AUTH keeps each array element as a word" {
    try expectAuth("PACMAN_AUTH=(sudo)\n", &.{"sudo"});
    try expectAuth("PACMAN_AUTH=(sudo --askpass)\n", &.{ "sudo", "--askpass" });
    try expectAuth("PACMAN_AUTH=(\"su\" \"-c\" \"%c\")\n", &.{ "su", "-c", "%c" });
    try expectAuth("PACMAN_AUTH=('doas' -n)\n", &.{ "doas", "-n" });
    try expectAuth("PACMAN_AUTH=(su -c 'exec %c')\n", &.{ "su", "-c", "exec %c" });
    try expectAuth("PACMAN_AUTH=doas\n", &.{"doas"});
    try expectAuth("  PACMAN_AUTH=\"doas\"\n", &.{"doas"});
}

test "a multi-line array with comments is read whole" {
    try expectAuth(
        \\PACMAN_AUTH=(
        \\  su # the tool
        \\  -c
        \\  "%c"
        \\)
        \\PKGEXT=.pkg.tar
    , &.{ "su", "-c", "%c" });
}

test "comments end a value and commented assignments do not count" {
    try expectAuth("PACMAN_AUTH=(doas) # elevate\n", &.{"doas"});
    try expectPkgdest("PKGDEST=/srv/repo # built here\n", "/srv/repo");
    try expectPkgdest("PKGDEST=\"/srv/repo\" # built here\n", "/srv/repo");
    try expectPkgdest("#PKGDEST=/srv/repo\n", null);
    try expectPkgdest("PKGDEST=/srv/repo#1\n", "/srv/repo#1");
}

test "scalar values follow bash quoting" {
    try expectPkgdest("PKGDEST=\"/srv/my repo\"\n", "/srv/my repo");
    try expectPkgdest("PKGDEST=/srv/'my repo'/aur\n", "/srv/my repo/aur");
    try expectPkgdest("PKGDEST=/srv/my\\ repo\n", "/srv/my repo");
    try expectPkgdest("PKGDEST=/srv/repo; PKGEXT=.x\n", "/srv/repo");
    try expectPkgdest("PKGDEST=/srv/repo\r\n", "/srv/repo");
}

test "the whole variable name must match" {
    try expectPkgdest("PKGDESTINATION=/x\n", null);
    try expectPkgdest("SRCPKGDEST=/x\n", null);
}

test "the last assignment wins and an empty one clears the value" {
    try expectPkgdest("PKGDEST=/a\nPKGDEST=/b\n", "/b");
    try expectPkgdest("PKGDEST=/a\nPKGDEST=\n", null);
    try expectPkgdest("PKGDEST=/a\nPKGDEST=\"\"\n", null);

    var config = MakepkgConfig{};
    defer config.deinit(testing.allocator);
    try parseContent(testing.allocator, "PACMAN_AUTH=(sudo)\nPACMAN_AUTH=()\nPKGEXT=.a\nPKGEXT=\n", &config);
    try testing.expect(config.pacman_auth == null);
    try testing.expectEqualStrings(DEFAULT_PKGEXT, config.pkgext);
}

test "expansions are literal text" {
    try expectPkgdest("PKGDEST=$HOME/repo\n", "$HOME/repo");
    try expectAuth("PACMAN_AUTH=($(touch /tmp/x))\n", &.{ "$(touch", "/tmp/x" });
}

test "splitWords honours quotes in an environment value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectWords(try splitWords(a, "su -c \"%c\""), &.{ "su", "-c", "%c" });
    try expectWords(try splitWords(a, "  doas\t-n "), &.{ "doas", "-n" });
    try testing.expectEqual(@as(usize, 0), (try splitWords(a, "   ")).len);
}

/// A throwaway configuration tree. Paths are relative to the working directory,
/// where `tmpDir` creates its directories.
const ConfTree = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,

    fn init() ConfTree {
        return .{ .tmp = testing.tmpDir(.{}), .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(self: *ConfTree) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn path(self: *ConfTree, sub_path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), ".zig-cache/tmp/{s}/{s}", .{ self.tmp.sub_path, sub_path });
    }

    fn write(self: *ConfTree, sub_path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub_path)) |dir| try self.tmp.dir.createDirPath(testing.io, dir);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn pkgdestAfterReading(self: *ConfTree, use_xdg_home: bool) !?[]const u8 {
        var config = MakepkgConfig{};
        defer config.deinit(testing.allocator);
        try readConfFiles(testing.allocator, .{
            .system = try self.path("etc/makepkg.conf"),
            .xdg_config_home = if (use_xdg_home) try self.path("xdg") else null,
            .home = try self.path("home"),
        }, &config);
        const value = config.pkgdest orelse return null;
        return try self.arena.allocator().dupe(u8, value);
    }
};

test "a drop-in overrides the system file" {
    var tree = ConfTree.init();
    defer tree.deinit();
    try tree.write("etc/makepkg.conf", "PKGDEST=/system\n");
    try tree.write("etc/makepkg.conf.d/a.conf", "PKGDEST=/dropin\n");
    try testing.expectEqualStrings("/dropin", (try tree.pkgdestAfterReading(true)).?);
}

test "drop-ins apply in sorted order and only *.conf counts" {
    var tree = ConfTree.init();
    defer tree.deinit();
    try tree.write("etc/makepkg.conf", "");
    try tree.write("etc/makepkg.conf.d/20-b.conf", "PKGDEST=/b\n");
    try tree.write("etc/makepkg.conf.d/10-a.conf", "PKGDEST=/a\n");
    try tree.write("etc/makepkg.conf.d/30-c.conf.bak", "PKGDEST=/ignored\n");
    try tree.write("etc/makepkg.conf.d/.99-hidden.conf", "PKGDEST=/hidden\n");
    try testing.expectEqualStrings("/b", (try tree.pkgdestAfterReading(true)).?);
}

test "the user file overrides drop-ins" {
    var tree = ConfTree.init();
    defer tree.deinit();
    try tree.write("etc/makepkg.conf", "PKGDEST=/system\n");
    try tree.write("etc/makepkg.conf.d/a.conf", "PKGDEST=/dropin\n");
    try tree.write("home/.makepkg.conf", "PKGDEST=/legacy\n");
    try testing.expectEqualStrings("/legacy", (try tree.pkgdestAfterReading(true)).?);
}

test "the XDG file replaces the legacy file instead of layering with it" {
    var tree = ConfTree.init();
    defer tree.deinit();
    try tree.write("etc/makepkg.conf", "PKGDEST=/system\n");
    try tree.write("xdg/pacman/makepkg.conf", "PKGEXT=.pkg.tar\n");
    try tree.write("home/.makepkg.conf", "PKGDEST=/legacy\n");
    try testing.expectEqualStrings("/system", (try tree.pkgdestAfterReading(true)).?);
}

test "XDG_CONFIG_HOME falls back to ~/.config" {
    var tree = ConfTree.init();
    defer tree.deinit();
    try tree.write("home/.config/pacman/makepkg.conf", "PKGDEST=/xdg\n");
    try tree.write("home/.makepkg.conf", "PKGDEST=/legacy\n");
    try testing.expectEqualStrings("/xdg", (try tree.pkgdestAfterReading(false)).?);
}

test "a missing configuration file is skipped" {
    var tree = ConfTree.init();
    defer tree.deinit();
    try testing.expect((try tree.pkgdestAfterReading(true)) == null);
}

test {
    std.testing.refAllDecls(@This());
}
