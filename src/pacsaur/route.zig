//! Routing policy: `Invocation` -> `Plan`.
//!
//! The only module that decides what runs where. Steps run in order:
//! pacman first, then the AUR commands, so that AUR packages build against
//! an up-to-date system.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const types = @import("commands").types;
const args = @import("args.zig");
const classify = @import("classify.zig");

pub const Flags = types.Flags;

/// The AUR command a step runs.
pub const AurOp = enum {
    sync,
    build,
    info,
    search,
    upgrade,
    outdated,
    clean,

    /// Whether the command builds packages, which makepkg refuses as root.
    pub fn builds(self: AurOp) bool {
        return switch (self) {
            .sync, .build, .upgrade => true,
            else => false,
        };
    }
};

pub const PacmanStep = struct {
    /// pacman's arguments, without the program name.
    argv: []const []const u8,
    /// Run through PACMAN_AUTH (or sudo, or su).
    elevate: bool,
};

pub const AurStep = struct {
    op: AurOp,
    targets: []const []const u8,
};

pub const Step = union(enum) {
    pacman: PacmanStep,
    aur: AurStep,
};

/// An ordered plan. Steps run sequentially, in slice order.
pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    steps: []Step,
    /// The options of the AUR steps.
    flags: Flags,
    /// The tokens `flags` were read from, for --dry-run.
    aur_options: []const []const u8,

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn needsElevation(self: *const Plan) bool {
        for (self.steps) |s| switch (s) {
            .pacman => |p| if (p.elevate) return true,
            .aur => {},
        };
        return false;
    }

    pub fn buildsAur(self: *const Plan) bool {
        for (self.steps) |s| switch (s) {
            .aur => |a| if (a.op.builds()) return true,
            .pacman => {},
        };
        return false;
    }

    pub fn hasPacmanStep(self: *const Plan) bool {
        for (self.steps) |s| {
            if (s == .pacman) return true;
        }
        return false;
    }
};

pub const Error = error{
    /// An AUR-only option on an invocation with no AUR step. The option
    /// is in the diagnostic.
    AurOnlyFlag,
    /// `--aur` with an operation the AUR side does not have.
    NotAurOperation,
    /// An option's value is not one it accepts. The option is in the
    /// diagnostic.
    InvalidValue,
    OutOfMemory,
};

/// What an error is about: the offending option.
pub const Diagnostic = struct {
    option: []const u8 = "",
};

fn aurOpFor(op: args.Op) ?AurOp {
    return switch (op) {
        .sync => .sync,
        .build => .build,
        .info => .info,
        .search => .search,
        .sysupgrade => .upgrade,
        .upgrades => .outdated,
        .clean => .clean,
        .refresh, .other => null,
    };
}

/// Whether pacman refuses this operation unless it is root. A gap fails
/// safe: pacman then reports its own root error.
fn pacmanNeedsRoot(m: args.Modifiers) bool {
    if (m.help) return false;
    return switch (m.family) {
        .database => !m.check,
        .remove, .upgrade => !m.print,
        .files => m.refresh,
        .sync => m.refresh or m.clean > 0 or
            !(m.info or m.search or m.list or m.groups or m.print),
        .query, .deptest, .other => false,
    };
}

/// Build the plan for `inv`.
///
/// `classifier` is anything with a `source(name) classify.Source` method,
/// so tests can route without libalpm. It is only consulted for split
/// operations that are not forced to one side.
pub fn build(allocator: Allocator, inv: *const args.Invocation, classifier: anytype, diag: *Diagnostic) Error!Plan {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var aur_options: std.ArrayList([]const u8) = .empty;
    const flags = try aurFlags(a, inv, &aur_options, diag);

    var steps: std.ArrayList(Step) = .empty;
    const elevate = pacmanNeedsRoot(inv.mods);

    if (inv.own.force) |side| switch (side) {
        .pacman => try steps.append(a, .{ .pacman = .{ .argv = try pacmanArgv(a, inv, null), .elevate = elevate } }),
        .aur => {
            const op = aurOpFor(inv.op) orelse return error.NotAurOperation;
            try steps.append(a, .{ .aur = .{ .op = op, .targets = try allTargets(a, inv) } });
        },
    } else switch (inv.class) {
        .pacman_only => {
            try steps.append(a, .{ .pacman = .{ .argv = try pacmanArgv(a, inv, null), .elevate = elevate } });
        },
        .broadcast => {
            const op = aurOpFor(inv.op).?;
            try steps.append(a, .{ .pacman = .{ .argv = try pacmanArgv(a, inv, null), .elevate = elevate } });
            // A search without terms lists pacman's packages only; the AUR
            // cannot be listed. clean takes no targets.
            const targets = if (op == .clean) &.{} else try allTargets(a, inv);
            if (!(op == .search and targets.len == 0)) {
                try steps.append(a, .{ .aur = .{ .op = op, .targets = targets } });
            }
        },
        .split => {
            const part = try partition(a, inv, classifier);
            // Without targets, pacman reports the missing targets itself.
            // With -y, pacman refreshes the databases even if it installs
            // nothing, before the AUR packages build.
            if (part.pacman.len > 0 or part.aur.len == 0 or inv.mods.refresh) {
                try steps.append(a, .{ .pacman = .{ .argv = try pacmanArgv(a, inv, part.pacman), .elevate = elevate } });
            }
            if (part.aur.len > 0) {
                try steps.append(a, .{ .aur = .{ .op = aurOpFor(inv.op).?, .targets = part.aur } });
            }
        },
    }

    const owned = try steps.toOwnedSlice(a);
    if (aur_options.items.len > 0) {
        for (owned) |s| {
            if (s == .aur) break;
        } else {
            for (inv.tokens) |t| {
                if (t.kind == .aur_flag) {
                    diag.option = t.text;
                    break;
                }
            }
            if (diag.option.len > 0) return error.AurOnlyFlag;
        }
    }

    return .{
        .arena = arena,
        .steps = owned,
        .flags = flags,
        .aur_options = try aur_options.toOwnedSlice(a),
    };
}

const Partition = struct {
    pacman: []const []const u8,
    aur: []const []const u8,
};

/// Official names go to pacman, everything else to the AUR side. A
/// repository-qualified name (`extra/foo`) is pacman's; `aur/foo` is the
/// AUR side's whatever the databases say.
fn partition(a: Allocator, inv: *const args.Invocation, classifier: anytype) !Partition {
    var pacman: std.ArrayList([]const u8) = .empty;
    var aur: std.ArrayList([]const u8) = .empty;
    for (inv.tokens) |t| switch (t.kind) {
        .target_aur => try aur.append(a, t.text),
        .target => {
            const official = std.mem.indexOfScalar(u8, t.text, '/') != null or
                classifier.source(t.text) == .official;
            try (if (official) &pacman else &aur).append(a, t.text);
        },
        else => {},
    };
    return .{ .pacman = try pacman.toOwnedSlice(a), .aur = try aur.toOwnedSlice(a) };
}

fn allTargets(a: Allocator, inv: *const args.Invocation) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (inv.tokens) |t| {
        if (t.kind == .target or t.kind == .target_aur) try out.append(a, t.text);
    }
    return out.toOwnedSlice(a);
}

/// pacman's arguments: the tokens as typed, without AUR-only options and
/// `aur/` targets. `targets`, when given, keeps only those targets.
fn pacmanArgv(a: Allocator, inv: *const args.Invocation, targets: ?[]const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (inv.tokens) |t| switch (t.kind) {
        .aur_flag, .aur_flag_arg, .target_aur => {},
        .target => if (targets) |keep| {
            for (keep) |k| {
                if (k.ptr == t.text.ptr) {
                    try out.append(a, t.text);
                    break;
                }
            }
        } else try out.append(a, t.text),
        .op, .flag, .flag_arg, .separator => try out.append(a, t.text),
    };
    return out.toOwnedSlice(a);
}

/// The options of the AUR steps: pacman's options that also apply to AUR
/// packages, and the AUR-only ones. Others only reach pacman. The tokens
/// read are appended to `shown`.
fn aurFlags(a: Allocator, inv: *const args.Invocation, shown: *std.ArrayList([]const u8), diag: *Diagnostic) Error!Flags {
    var flags = Flags{ .quiet = inv.mods.quiet, .all = inv.mods.clean >= 2 };
    if (flags.all) try shown.append(a, "--all");
    var ignore: std.ArrayList([]const u8) = .empty;
    const eql = std.mem.eql;

    var i: usize = 0;
    while (i < inv.tokens.len) : (i += 1) {
        const t = inv.tokens[i];
        if (t.kind != .flag and t.kind != .aur_flag) continue;
        const eq = std.mem.indexOfScalar(u8, t.text, '=');
        const name = t.text[0 .. eq orelse t.text.len];

        // The operand: after `=`, or the next token.
        var value: ?[]const u8 = if (eq) |e| t.text[e + 1 ..] else null;
        var value_token: ?[]const u8 = null;
        if (value == null and i + 1 < inv.tokens.len) {
            const next = inv.tokens[i + 1];
            if (next.kind == .flag_arg or next.kind == .aur_flag_arg) {
                value = next.text;
                value_token = next.text;
            }
        }

        const known = blk: {
            if (eql(u8, name, "--needed")) flags.needed = true else if (eql(u8, name, "--noconfirm")) flags.noconfirm = true else if (eql(u8, name, "--asdeps")) flags.asdeps = true else if (eql(u8, name, "--asexplicit")) flags.asexplicit = true else if (eql(u8, name, "--noshow")) flags.noshow = true else if (eql(u8, name, "--rebuild")) flags.rebuild = true else if (eql(u8, name, "--chroot")) flags.chroot = true else if (eql(u8, name, "--devel")) flags.devel = true else if (eql(u8, name, "--all")) flags.all = true else if (eql(u8, name, "--ignore")) {
                var it = std.mem.splitScalar(u8, value orelse "", ',');
                while (it.next()) |pkg| {
                    const trimmed = std.mem.trim(u8, pkg, " ");
                    if (trimmed.len > 0) try ignore.append(a, trimmed);
                }
            } else if (eql(u8, name, "--by")) {
                flags.by = core.aur.SearchField.fromString(value orelse "") orelse {
                    diag.option = name;
                    return error.InvalidValue;
                };
            } else if (eql(u8, name, "--sort") or eql(u8, name, "--rsort")) {
                const field = types.SortField.fromString(value orelse "") orelse {
                    diag.option = name;
                    return error.InvalidValue;
                };
                if (name[2] == 's') flags.sort = field else flags.rsort = field;
            } else break :blk false;
            break :blk true;
        };
        if (known) {
            try shown.append(a, t.text);
            if (value_token) |v| try shown.append(a, v);
        }
        if (value_token != null) i += 1;
    }

    flags.ignore = try ignore.toOwnedSlice(a);
    return flags;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Names starting with "o" are official, "l" in the local AUR repository;
/// the rest are in neither.
const FakeClassifier = struct {
    pub fn source(_: FakeClassifier, name: []const u8) classify.Source {
        return switch (name[0]) {
            'o' => .official,
            'l' => .local_aur,
            else => .neither,
        };
    }
};

fn planOf(argv: []const []const u8) !Plan {
    var inv = try args.parse(testing.allocator, argv);
    defer inv.deinit();
    var diag: Diagnostic = .{};
    return build(testing.allocator, &inv, FakeClassifier{}, &diag);
}

fn expectPacman(step: Step, argv: []const []const u8, elevate: bool) !void {
    try testing.expect(step == .pacman);
    try testing.expectEqual(elevate, step.pacman.elevate);
    try testing.expectEqual(argv.len, step.pacman.argv.len);
    for (argv, step.pacman.argv) |want, got| try testing.expectEqualStrings(want, got);
}

fn expectAur(step: Step, op: AurOp, targets: []const []const u8) !void {
    try testing.expect(step == .aur);
    try testing.expectEqual(op, step.aur.op);
    try testing.expectEqual(targets.len, step.aur.targets.len);
    for (targets, step.aur.targets) |want, got| try testing.expectEqualStrings(want, got);
}

test "-S splits targets: official to pacman first, the rest to the AUR" {
    var plan = try planOf(&.{ "p", "-S", "--asdeps", "ofoo", "lbar", "baz" });
    defer plan.deinit();
    try testing.expectEqual(@as(usize, 2), plan.steps.len);
    try expectPacman(plan.steps[0], &.{ "-S", "--asdeps", "ofoo" }, true);
    try expectAur(plan.steps[1], .sync, &.{ "lbar", "baz" });
    try testing.expect(plan.flags.asdeps);
}

test "-S with only AUR targets has no pacman step" {
    var plan = try planOf(&.{ "p", "-S", "baz" });
    defer plan.deinit();
    try testing.expectEqual(@as(usize, 1), plan.steps.len);
    try expectAur(plan.steps[0], .sync, &.{"baz"});
}

test "-Sy refreshes with pacman even when every target is from the AUR" {
    var plan = try planOf(&.{ "p", "-Sy", "baz" });
    defer plan.deinit();
    try testing.expectEqual(@as(usize, 2), plan.steps.len);
    try expectPacman(plan.steps[0], &.{"-Sy"}, true);
    try expectAur(plan.steps[1], .sync, &.{"baz"});
}

test "-S without targets goes to pacman" {
    var plan = try planOf(&.{ "p", "-S" });
    defer plan.deinit();
    try testing.expectEqual(@as(usize, 1), plan.steps.len);
    try expectPacman(plan.steps[0], &.{"-S"}, true);
}

test "aur/ forces a target to the AUR, and a repository prefix to pacman" {
    var plan = try planOf(&.{ "p", "-S", "aur/ofoo", "core/baz" });
    defer plan.deinit();
    try expectPacman(plan.steps[0], &.{ "-S", "core/baz" }, true);
    try expectAur(plan.steps[1], .sync, &.{"ofoo"});
}

test "-Sw builds AUR targets and -Si splits without elevating" {
    var w = try planOf(&.{ "p", "-Sw", "ofoo", "baz" });
    defer w.deinit();
    try expectPacman(w.steps[0], &.{ "-Sw", "ofoo" }, true);
    try expectAur(w.steps[1], .build, &.{"baz"});

    var i = try planOf(&.{ "p", "-Si", "ofoo", "baz" });
    defer i.deinit();
    try expectPacman(i.steps[0], &.{ "-Si", "ofoo" }, false);
    try expectAur(i.steps[1], .info, &.{"baz"});
}

test "-Syu runs pacman, then the AUR upgrade" {
    var plan = try planOf(&.{ "p", "-Syu", "--devel" });
    defer plan.deinit();
    try expectPacman(plan.steps[0], &.{"-Syu"}, true);
    try expectAur(plan.steps[1], .upgrade, &.{});
    try testing.expect(plan.flags.devel);
}

test "-Ss searches both, and only pacman without terms" {
    var plan = try planOf(&.{ "p", "-Ss", "--sort", "votes", "editor" });
    defer plan.deinit();
    try expectPacman(plan.steps[0], &.{ "-Ss", "editor" }, false);
    try expectAur(plan.steps[1], .search, &.{"editor"});
    try testing.expectEqual(types.SortField.votes, plan.flags.sort.?);

    var bare = try planOf(&.{ "p", "-Ss" });
    defer bare.deinit();
    try testing.expectEqual(@as(usize, 1), bare.steps.len);
}

test "-Qu lists both without elevating" {
    var plan = try planOf(&.{ "p", "-Qu" });
    defer plan.deinit();
    try expectPacman(plan.steps[0], &.{"-Qu"}, false);
    try expectAur(plan.steps[1], .outdated, &.{});
}

test "-Sc cleans both, and -Scc removes all built packages" {
    var c = try planOf(&.{ "p", "-Sc" });
    defer c.deinit();
    try expectPacman(c.steps[0], &.{"-Sc"}, true);
    try expectAur(c.steps[1], .clean, &.{});
    try testing.expect(!c.flags.all);

    var cc = try planOf(&.{ "p", "-Scc" });
    defer cc.deinit();
    try testing.expect(cc.flags.all);
}

test "other operations go to pacman unchanged" {
    var plan = try planOf(&.{ "p", "-Rns", "ofoo", "--noconfirm" });
    defer plan.deinit();
    try testing.expectEqual(@as(usize, 1), plan.steps.len);
    try expectPacman(plan.steps[0], &.{ "-Rns", "ofoo", "--noconfirm" }, true);

    var q = try planOf(&.{ "p", "-Qi", "ofoo" });
    defer q.deinit();
    try expectPacman(q.steps[0], &.{ "-Qi", "ofoo" }, false);
}

test "AUR-only options never reach pacman" {
    var plan = try planOf(&.{ "p", "-S", "--rebuild", "--chroot", "ofoo", "baz", "--noshow" });
    defer plan.deinit();
    try expectPacman(plan.steps[0], &.{ "-S", "ofoo" }, true);
    try testing.expect(plan.flags.rebuild and plan.flags.chroot and plan.flags.noshow);
}

test "an AUR-only option without an AUR step is an error naming it" {
    var inv = try args.parse(testing.allocator, &.{ "p", "-R", "--chroot", "ofoo" });
    defer inv.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.AurOnlyFlag, build(testing.allocator, &inv, FakeClassifier{}, &diag));
    try testing.expectEqualStrings("--chroot", diag.option);

    var only_official = try args.parse(testing.allocator, &.{ "p", "-S", "--devel", "ofoo" });
    defer only_official.deinit();
    try testing.expectError(error.AurOnlyFlag, build(testing.allocator, &only_official, FakeClassifier{}, &diag));
}

test "an invalid search option value is an error naming the option" {
    var inv = try args.parse(testing.allocator, &.{ "p", "-Ss", "--by", "colour", "foo" });
    defer inv.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidValue, build(testing.allocator, &inv, FakeClassifier{}, &diag));
    try testing.expectEqualStrings("--by", diag.option);
}

test "shared options apply to both sides, --ignore split on commas" {
    var plan = try planOf(&.{ "p", "-S", "--needed", "--ignore", "a,b", "--ignore=c", "ofoo", "baz" });
    defer plan.deinit();
    try expectPacman(plan.steps[0], &.{ "-S", "--needed", "--ignore", "a,b", "--ignore=c", "ofoo" }, true);
    try testing.expect(plan.flags.needed);
    try testing.expectEqual(@as(usize, 3), plan.flags.ignore.len);
    try testing.expectEqualStrings("c", plan.flags.ignore[2]);
}

test "--repo sends everything to pacman, --aur to the AUR side" {
    var r = try planOf(&.{ "p", "--repo", "-S", "baz" });
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.steps.len);
    try expectPacman(r.steps[0], &.{ "-S", "baz" }, true);

    var a = try planOf(&.{ "p", "--aur", "-Syu" });
    defer a.deinit();
    try testing.expectEqual(@as(usize, 1), a.steps.len);
    try expectAur(a.steps[0], .upgrade, &.{});

    var s = try planOf(&.{ "p", "--aur", "-S", "ofoo" });
    defer s.deinit();
    try expectAur(s.steps[0], .sync, &.{"ofoo"});
}

test "--aur with a pacman-only operation is an error" {
    var inv = try args.parse(testing.allocator, &.{ "p", "--aur", "-R", "foo" });
    defer inv.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.NotAurOperation, build(testing.allocator, &inv, FakeClassifier{}, &diag));
}

test "the plan reports elevation and AUR builds" {
    var s = try planOf(&.{ "p", "-S", "ofoo", "baz" });
    defer s.deinit();
    try testing.expect(s.needsElevation());
    try testing.expect(s.buildsAur());

    var q = try planOf(&.{ "p", "-Si", "baz" });
    defer q.deinit();
    try testing.expect(!q.needsElevation());
    try testing.expect(!q.buildsAur());
}
