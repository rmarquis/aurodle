//! Argument parsing: pacman-style argv -> `Invocation`.
//!
//! This module records what the user said. It never decides where a command
//! goes; that is `route`'s job. The only text transformation here is
//! stripping an `aur/` prefix, recorded as a token kind.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Which side `--repo` / `--aur` forces the whole invocation to.
pub const Side = enum { pacman, aur };

/// pacsaur's own flags, never passed on.
pub const OwnFlags = struct {
    help: bool = false,
    version: bool = false,
    dry_run: bool = false,
    force: ?Side = null,
};

/// The operation, derived from the family and modifiers whatever their
/// spelling (`-Syu`, `-S -y -u`, `--sync --refresh --sysupgrade`).
pub const Op = enum {
    sync,
    build,
    info,
    search,
    sysupgrade,
    refresh,
    upgrades,
    clean,
    other,

    /// How the operation is routed.
    ///
    /// Split operations take package names, so each target goes to pacman
    /// or the AUR (and both sides upgrade with -Su). Broadcast operations
    /// take no package names (or none at all), so both sides run them.
    pub fn class(self: Op) Class {
        return switch (self) {
            .sync, .build, .info, .sysupgrade => .split,
            .search, .upgrades, .clean => .broadcast,
            .refresh, .other => .pacman_only,
        };
    }
};

pub const Class = enum { split, broadcast, pacman_only };

pub const TokenKind = enum {
    /// The first operation option (`-S...`, `--sync`, `-Q...`, ...).
    op,
    flag,
    /// An option's operand (e.g. the path in `--cachedir DIR`).
    flag_arg,
    /// An option that only applies to AUR packages. Never passed to pacman.
    aur_flag,
    aur_flag_arg,
    target,
    /// A target written `aur/name`; the prefix has already been stripped.
    target_aur,
    separator,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
};

/// The pacman operation family, whichever spelling selected it.
pub const Family = enum { sync, query, remove, upgrade, database, files, deptest, other };

/// pacman modifiers that change what an operation does. A letter's meaning
/// depends on the family (`-Su` upgrades, `-Qu` lists upgrades), so these
/// are read alongside `family`.
pub const Modifiers = struct {
    family: Family = .other,
    refresh: bool = false,
    /// `-u`: `--sysupgrade` for sync, `--upgrades` for query.
    upgrade: bool = false,
    /// `-w`: pacman downloads and the AUR side builds into the local
    /// repository; neither installs anything.
    downloadonly: bool = false,
    /// How many times `-c` / `--clean` was given (`-Scc` is 2).
    clean: u8 = 0,
    info: bool = false,
    search: bool = false,
    list: bool = false,
    groups: bool = false,
    print: bool = false,
    check: bool = false,
    quiet: bool = false,
    /// A help request written inside a cluster (`-Sh`). A bare `-h` is
    /// pacsaur's own flag and never reaches this scan.
    help: bool = false,
};

pub const ParseError = error{
    /// An option that consumes a following token was the last argument.
    MissingArgument,
    /// Both `--repo` and `--aur` were given.
    OwnFlagConflict,
    /// `--repo` was combined with an `aur/`-prefixed target.
    ContradictoryHint,
    OutOfMemory,
};

/// A parsed invocation. Owns `tokens`; `Token.text` points into the
/// caller's argv.
pub const Invocation = struct {
    allocator: Allocator,
    own: OwnFlags,
    op: Op,
    class: Class,
    mods: Modifiers = .{},
    tokens: []Token,

    pub fn deinit(self: *Invocation) void {
        self.allocator.free(self.tokens);
        self.* = undefined;
    }

    pub fn hasTargets(self: *const Invocation) bool {
        for (self.tokens) |t| {
            if (t.kind == .target or t.kind == .target_aur) return true;
        }
        return false;
    }
};

/// pacman options that consume the following token.
const PACMAN_ARG_OPTIONS = [_][]const u8{
    "--ignore",  "--ignoregroup", "--overwrite",    "--cachedir",
    "--config",  "--dbpath",      "--root",         "--gpgdir",
    "--hookdir", "--logfile",     "--sysroot",      "--assume-installed",
    "--arch",    "--color",       "--print-format",
};

/// AUR-only options, and those of them that take an operand.
const AUR_FLAGS = [_][]const u8{ "--noshow", "--rebuild", "--chroot", "--devel", "--all" };
const AUR_ARG_OPTIONS = [_][]const u8{ "--by", "--sort", "--rsort" };

fn isOneOf(text: []const u8, list: []const []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, text, item)) return true;
    }
    return false;
}

fn familyFromShort(letter: u8) ?Family {
    return switch (letter) {
        'S' => .sync,
        'Q' => .query,
        'R' => .remove,
        'U' => .upgrade,
        'D' => .database,
        'F' => .files,
        'T' => .deptest,
        else => null,
    };
}

fn familyFromLong(name: []const u8) ?Family {
    const map = std.StaticStringMap(Family).initComptime(.{
        .{ "--sync", .sync },
        .{ "--query", .query },
        .{ "--remove", .remove },
        .{ "--upgrade", .upgrade },
        .{ "--database", .database },
        .{ "--files", .files },
        .{ "--deptest", .deptest },
    });
    return map.get(name);
}

/// The letters of a short cluster that are options. `-b` and `-r` take an
/// operand that may be attached (`-rfoo`), so scanning stops at them.
fn clusterLetters(text: []const u8) []const u8 {
    const letters = text[1..];
    const end = std.mem.indexOfAny(u8, letters, "br") orelse letters.len;
    return letters[0..end];
}

fn longName(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '=') orelse text.len;
    return text[0..end];
}

fn isOptionToken(t: Token) bool {
    return (t.kind == .op or t.kind == .flag) and t.text.len >= 2 and t.text[0] == '-';
}

fn isLong(text: []const u8) bool {
    return text[1] == '-';
}

/// Collect the modifiers of `tokens`. The family is resolved first because
/// a short letter's meaning depends on it.
fn scanModifiers(tokens: []const Token) Modifiers {
    var m = Modifiers{};

    family: for (tokens) |t| {
        if (!isOptionToken(t)) continue;
        if (isLong(t.text)) {
            if (familyFromLong(longName(t.text))) |f| {
                m.family = f;
                break :family;
            }
        } else for (clusterLetters(t.text)) |c| {
            if (familyFromShort(c)) |f| {
                m.family = f;
                break :family;
            }
        }
    }

    for (tokens) |t| {
        if (!isOptionToken(t)) continue;
        if (isLong(t.text)) {
            const name = longName(t.text);
            const eql = std.mem.eql;
            if (eql(u8, name, "--refresh")) m.refresh = true;
            if (eql(u8, name, "--sysupgrade") or eql(u8, name, "--upgrades")) m.upgrade = true;
            if (eql(u8, name, "--downloadonly")) m.downloadonly = true;
            if (eql(u8, name, "--clean")) m.clean +|= 1;
            if (eql(u8, name, "--info")) m.info = true;
            if (eql(u8, name, "--search")) m.search = true;
            if (eql(u8, name, "--check")) m.check = true;
            if (eql(u8, name, "--list")) m.list = true;
            if (eql(u8, name, "--groups")) m.groups = true;
            if (eql(u8, name, "--quiet")) m.quiet = true;
            if (eql(u8, name, "--print") or eql(u8, name, "--print-format")) m.print = true;
        } else for (clusterLetters(t.text)) |c| switch (c) {
            'y' => m.refresh = true,
            'u' => m.upgrade = true,
            'w' => m.downloadonly = true,
            'c' => m.clean +|= 1,
            'i' => m.info = true,
            's' => m.search = true,
            'k' => m.check = true,
            'q' => m.quiet = true,
            'h' => m.help = true,
            'l' => m.list = true,
            'g' => m.groups = true,
            'p' => m.print = true,
            else => {},
        };
    }
    return m;
}

/// The operation `m` selects. `has_targets` tells `-Sy` (refresh only)
/// from `-Sy foo` (refresh, then install foo).
fn opOf(m: Modifiers, has_targets: bool) Op {
    if (m.help) return .other;
    return switch (m.family) {
        .sync => blk: {
            // These query pacman's own databases (repository names, group
            // names, print-only targets), which the AUR side cannot answer.
            if (m.list or m.groups or m.print) break :blk .other;
            if (m.info) break :blk .info;
            if (m.search) break :blk .search;
            if (m.clean > 0) break :blk .clean;
            // With -w, nothing is installed (see `Modifiers.downloadonly`).
            if (m.upgrade) break :blk .sysupgrade;
            if (m.downloadonly) break :blk .build;
            if (m.refresh and !has_targets) break :blk .refresh;
            break :blk .sync;
        },
        .query => if (m.upgrade) .upgrades else .other,
        else => .other,
    };
}

/// Parse full process argv (including argv[0]) into an `Invocation`.
/// With no user arguments the result is a help request.
pub fn parse(allocator: Allocator, argv: []const []const u8) ParseError!Invocation {
    var own = OwnFlags{};
    var op_seen = false;
    var list: std.ArrayList(Token) = .empty;
    errdefer list.deinit(allocator);

    const args = if (argv.len > 0) argv[1..] else argv[0..0];
    if (args.len == 0) own.help = true;

    var i: usize = 0;
    var after_separator = false;
    while (i < args.len) : (i += 1) {
        const text = args[i];

        if (after_separator) {
            try list.append(allocator, classifyTarget(text));
            continue;
        }

        // ── pacsaur's own flags ─────────────────────────────────────────
        if (std.mem.eql(u8, text, "--help") or std.mem.eql(u8, text, "-h")) {
            own.help = true;
            continue;
        }
        if (std.mem.eql(u8, text, "--version") or std.mem.eql(u8, text, "-V")) {
            own.version = true;
            continue;
        }
        if (std.mem.eql(u8, text, "--dry-run")) {
            own.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, text, "--repo")) {
            if (own.force == .aur) return error.OwnFlagConflict;
            own.force = .pacman;
            continue;
        }
        if (std.mem.eql(u8, text, "--aur")) {
            if (own.force == .pacman) return error.OwnFlagConflict;
            own.force = .aur;
            continue;
        }

        if (std.mem.eql(u8, text, "--")) {
            try list.append(allocator, .{ .kind = .separator, .text = text });
            after_separator = true;
            continue;
        }

        // ── long options ────────────────────────────────────────────────
        if (text.len >= 2 and text[0] == '-' and text[1] == '-') {
            const name = longName(text);
            if (isOneOf(name, &AUR_FLAGS) or isOneOf(name, &AUR_ARG_OPTIONS)) {
                try list.append(allocator, .{ .kind = .aur_flag, .text = text });
                if (isOneOf(text, &AUR_ARG_OPTIONS)) {
                    if (i + 1 >= args.len) return error.MissingArgument;
                    i += 1;
                    try list.append(allocator, .{ .kind = .aur_flag_arg, .text = args[i] });
                }
                continue;
            }
            const is_op = !op_seen and familyFromLong(text) != null;
            op_seen = op_seen or is_op;
            try list.append(allocator, .{ .kind = if (is_op) .op else .flag, .text = text });
            if (isOneOf(text, &PACMAN_ARG_OPTIONS)) {
                if (i + 1 >= args.len) return error.MissingArgument;
                i += 1;
                try list.append(allocator, .{ .kind = .flag_arg, .text = args[i] });
            }
            continue;
        }

        // ── short clusters ──────────────────────────────────────────────
        if (text.len >= 2 and text[0] == '-') {
            const is_op = !op_seen and familyFromShort(text[1]) != null;
            op_seen = op_seen or is_op;
            try list.append(allocator, .{ .kind = if (is_op) .op else .flag, .text = text });
            continue;
        }

        try list.append(allocator, classifyTarget(text));
    }

    const tokens = try list.toOwnedSlice(allocator);
    errdefer allocator.free(tokens);

    if (own.force == .pacman) {
        for (tokens) |t| {
            if (t.kind == .target_aur) return error.ContradictoryHint;
        }
    }

    var inv = Invocation{
        .allocator = allocator,
        .own = own,
        .op = .other,
        .class = .pacman_only,
        .mods = scanModifiers(tokens),
        .tokens = tokens,
    };
    inv.op = opOf(inv.mods, inv.hasTargets());
    inv.class = inv.op.class();
    return inv;
}

/// `aur/name` becomes `target_aur` with the prefix stripped. A bare `aur/`
/// is left as a literal target for pacman to report.
fn classifyTarget(text: []const u8) Token {
    if (std.mem.startsWith(u8, text, "aur/") and text.len > 4) {
        return .{ .kind = .target_aur, .text = text[4..] };
    }
    return .{ .kind = .target, .text = text };
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectOp(argv: []const []const u8, op: Op, class: Class) !void {
    var inv = try parse(testing.allocator, argv);
    defer inv.deinit();
    try testing.expectEqual(op, inv.op);
    try testing.expectEqual(class, inv.class);
}

test "parse on empty argv or the program name alone yields help" {
    var a = try parse(testing.allocator, &.{});
    defer a.deinit();
    try testing.expect(a.own.help);
    var b = try parse(testing.allocator, &.{"pacsaur"});
    defer b.deinit();
    try testing.expect(b.own.help);
}

test "parse keeps own flags out of the tokens" {
    var inv = try parse(testing.allocator, &.{ "p", "--dry-run", "-S", "foo", "-V" });
    defer inv.deinit();
    try testing.expect(inv.own.dry_run);
    try testing.expect(inv.own.version);
    try testing.expectEqual(@as(usize, 2), inv.tokens.len);
}

test "parse maps --repo and --aur to force and rejects both" {
    var r = try parse(testing.allocator, &.{ "p", "--repo", "-S", "foo" });
    defer r.deinit();
    try testing.expectEqual(Side.pacman, r.own.force.?);
    var a = try parse(testing.allocator, &.{ "p", "--aur", "-S", "foo" });
    defer a.deinit();
    try testing.expectEqual(Side.aur, a.own.force.?);
    try testing.expectError(error.OwnFlagConflict, parse(testing.allocator, &.{ "p", "--repo", "--aur", "-S" }));
    try testing.expectError(error.OwnFlagConflict, parse(testing.allocator, &.{ "p", "--aur", "--repo", "-S" }));
}

test "parse rejects --repo with an aur/ target" {
    try testing.expectError(error.ContradictoryHint, parse(testing.allocator, &.{ "p", "--repo", "-S", "aur/foo" }));
    try testing.expectError(error.ContradictoryHint, parse(testing.allocator, &.{ "p", "-S", "aur/foo", "--repo" }));
}

test "parse classifies split operations" {
    try expectOp(&.{ "p", "-S", "foo" }, .sync, .split);
    try expectOp(&.{ "p", "-Sw", "foo" }, .build, .split);
    try expectOp(&.{ "p", "-Si", "foo" }, .info, .split);
    try expectOp(&.{ "p", "--sync", "foo" }, .sync, .split);
    try expectOp(&.{ "p", "--sync", "--downloadonly", "foo" }, .build, .split);
    try expectOp(&.{ "p", "-Su" }, .sysupgrade, .split);
    try expectOp(&.{ "p", "-Syu", "foo" }, .sysupgrade, .split);
    try expectOp(&.{ "p", "-S", "-y", "-u" }, .sysupgrade, .split);
    try expectOp(&.{ "p", "--sync", "--refresh", "--sysupgrade" }, .sysupgrade, .split);
    try expectOp(&.{ "p", "-Suw" }, .sysupgrade, .split);
}

test "parse classifies broadcast operations in every spelling" {
    try expectOp(&.{ "p", "-Ss", "foo" }, .search, .broadcast);
    try expectOp(&.{ "p", "-Qu" }, .upgrades, .broadcast);
    try expectOp(&.{ "p", "--query", "--upgrades" }, .upgrades, .broadcast);
    try expectOp(&.{ "p", "-Sc" }, .clean, .broadcast);
    try expectOp(&.{ "p", "-Scc" }, .clean, .broadcast);
}

test "parse counts -c for -Scc" {
    var a = try parse(testing.allocator, &.{ "p", "-Scc" });
    defer a.deinit();
    try testing.expectEqual(@as(u8, 2), a.mods.clean);
    var b = try parse(testing.allocator, &.{ "p", "--sync", "--clean", "--clean" });
    defer b.deinit();
    try testing.expectEqual(@as(u8, 2), b.mods.clean);
}

test "parse tells -Sy alone from -Sy with targets" {
    try expectOp(&.{ "p", "-Sy" }, .refresh, .pacman_only);
    try expectOp(&.{ "p", "-Sy", "foo" }, .sync, .split);
}

test "parse classifies other families as pacman_only" {
    inline for ([_][]const u8{ "-R", "-Rns", "-Q", "-Qi", "-Ql", "-F", "-D", "-T", "-U" }) |tok| {
        try expectOp(&.{ "p", tok, "foo" }, .other, .pacman_only);
    }
    try expectOp(&.{ "p", "--frobnicate", "foo" }, .other, .pacman_only);
}

test "parse keeps sync queries of pacman's own databases with pacman" {
    const cases = [_][]const []const u8{
        &.{ "p", "-Sl", "core" },
        &.{ "p", "-Sg", "base-devel" },
        &.{ "p", "-Sp", "foo" },
        &.{ "p", "-Sup" },
        &.{ "p", "-S", "-p", "foo" },
        &.{ "p", "--sync", "--print-format=%n", "foo" },
        &.{ "p", "--sync", "--list" },
        &.{ "p", "-Sh" },
    };
    for (cases) |argv| try expectOp(argv, .other, .pacman_only);
}

test "parse reads -p and -g as sync modifiers only" {
    try expectOp(&.{ "p", "-Qu", "-p" }, .upgrades, .broadcast);
}

test "parse does not read an operand attached to -r as modifiers" {
    try expectOp(&.{ "p", "-S", "-rlgp", "foo" }, .sync, .split);
}

test "parse marks only the first operation option as op" {
    var inv = try parse(testing.allocator, &.{ "p", "--sync", "--sysupgrade", "-y" });
    defer inv.deinit();
    try testing.expectEqual(TokenKind.op, inv.tokens[0].kind);
    try testing.expectEqual(TokenKind.flag, inv.tokens[1].kind);
    try testing.expectEqual(TokenKind.flag, inv.tokens[2].kind);
}

test "parse separates AUR-only options and their operands" {
    var inv = try parse(testing.allocator, &.{ "p", "-Ss", "--by", "maintainer", "--devel", "foo" });
    defer inv.deinit();
    try testing.expectEqual(TokenKind.aur_flag, inv.tokens[1].kind);
    try testing.expectEqual(TokenKind.aur_flag_arg, inv.tokens[2].kind);
    try testing.expectEqual(TokenKind.aur_flag, inv.tokens[3].kind);
    try testing.expectEqual(TokenKind.target, inv.tokens[4].kind);
}

test "parse does not treat an option's operand as a target" {
    var inv = try parse(testing.allocator, &.{ "p", "-S", "--cachedir", "/var/cache", "foo" });
    defer inv.deinit();
    try testing.expectEqual(TokenKind.flag_arg, inv.tokens[2].kind);
    try testing.expectEqual(TokenKind.target, inv.tokens[3].kind);

    var eq = try parse(testing.allocator, &.{ "p", "-S", "--cachedir=/var/cache", "foo" });
    defer eq.deinit();
    try testing.expectEqual(TokenKind.flag, eq.tokens[1].kind);
    try testing.expectEqual(TokenKind.target, eq.tokens[2].kind);
}

test "parse errors when an argument-taking option is last" {
    try testing.expectError(error.MissingArgument, parse(testing.allocator, &.{ "p", "-S", "--ignore" }));
    try testing.expectError(error.MissingArgument, parse(testing.allocator, &.{ "p", "-Ss", "--sort" }));
}

test "parse honours the -- separator" {
    var inv = try parse(testing.allocator, &.{ "p", "-S", "--", "-weird-name" });
    defer inv.deinit();
    try testing.expectEqual(TokenKind.separator, inv.tokens[1].kind);
    try testing.expectEqual(TokenKind.target, inv.tokens[2].kind);
}

test "parse strips the aur/ prefix, and keeps a bare aur/ literal" {
    var inv = try parse(testing.allocator, &.{ "p", "-S", "foo", "aur/bar", "aur/" });
    defer inv.deinit();
    try testing.expectEqual(TokenKind.target, inv.tokens[1].kind);
    try testing.expectEqual(TokenKind.target_aur, inv.tokens[2].kind);
    try testing.expectEqualStrings("bar", inv.tokens[2].text);
    try testing.expectEqual(TokenKind.target, inv.tokens[3].kind);
    try testing.expectEqualStrings("aur/", inv.tokens[3].text);
}

test "parse reads -q in a cluster as quiet" {
    var inv = try parse(testing.allocator, &.{ "p", "-Ssq", "foo" });
    defer inv.deinit();
    try testing.expect(inv.mods.quiet);
}
