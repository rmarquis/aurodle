const std = @import("std");
const output = @import("ui").output;
const aur = @import("core").aur;
const commands = @import("commands");
const cmd_types = commands.types;
const query_context = commands.query_context;
const git = @import("core").git;
const utils = @import("core").utils;
const Allocator = std.mem.Allocator;

const ExitCode = cmd_types.ExitCode;

const build_options = @import("build_options");
const version_string = build_options.version;

pub fn main(init: std.process.Init) u8 {
    const allocator = init.gpa;
    utils.global_io = init.io;
    defer utils.flushStdout();

    const result = run(allocator, init.io, init.minimal.args) catch |err| {
        utils.flushStdout();
        std.debug.print("error: unexpected failure: {}\n", .{err});
        return 1;
    };

    return @backingInt(result);
}

fn run(allocator: Allocator, io: std.Io, raw_args: std.process.Args) !ExitCode {
    var args_iter = std.process.Args.Iterator.init(raw_args);
    _ = args_iter.skip(); // skip argv[0]
    var args_buf: [256][]const u8 = undefined;
    var args_len: usize = 0;
    while (args_iter.next()) |arg| {
        if (args_len >= args_buf.len) {
            printUsageError("too many arguments");
            return .usage_error;
        }
        args_buf[args_len] = arg;
        args_len += 1;
    }
    const user_args = args_buf[0..args_len];

    // Parse arguments
    var arg_storage: ArgStorage = .{};
    const parsed = parseArgs(user_args, &arg_storage) catch |err| switch (err) {
        error.UnknownCommand => {
            printUsageError("unknown command");
            return .usage_error;
        },
        error.UnknownFlag => {
            printUsageError("unknown flag");
            return .usage_error;
        },
        error.MissingArgument => {
            printUsageError("missing required argument");
            return .usage_error;
        },
        error.TooManyArguments => {
            printUsageError("too many arguments");
            return .usage_error;
        },
        error.HelpRequested => {
            printHelp();
            return .success;
        },
        error.VersionRequested => {
            printVersion();
            return .success;
        },
    };

    // Handle command-specific help
    if (parsed.flags.help) {
        printHelp();
        return .success;
    }

    // Initialize AUR client (needed by all commands)
    var aur_client = aur.Client.init(allocator);
    defer aur_client.deinit();

    // Get cache root for git operations (needed by show/clone even in simple path)
    const cache_root = git.defaultCacheRoot(allocator) catch {
        std.debug.print("error: could not determine cache directory (HOME not set)\n", .{});
        return .general_error;
    };
    defer allocator.free(cache_root);

    // Commands that need the full module stack (pacman + registry + repo)
    if (parsed.operation.needsFullStack() or (parsed.operation == .clone and parsed.flags.recurse)) {
        return runWithFullStack(allocator, io, &aur_client, cache_root, parsed);
    }

    // Simple commands that only need the AUR client
    var qctx = query_context.QueryContext.init(allocator, io, &aur_client, cache_root, parsed.flags);

    return switch (parsed.operation) {
        .info => try commands.query.info(&qctx, parsed.targets),
        .search => blk: {
            if (parsed.targets.len == 0) {
                printUsageError("search requires a query term");
                break :blk .usage_error;
            }
            break :blk try commands.query.search(&qctx, parsed.targets);
        },
        .clone => try commands.build_cmd.clonePackages(&qctx, parsed.targets),
        .show => try commands.build_cmd.show(&qctx, parsed.targets[0]),
        .status => blk: {
            const code = try commands.status_cmd.run(qctx.allocator, qctx.stdout_color);
            break :blk if (code == 0) .success else .general_error;
        },
        // Full-stack commands handled above
        .sync, .build, .resolve, .buildorder, .outdated, .upgrade, .clean => unreachable,
    };
}

const Operation = enum {
    sync,
    build,
    clone,
    info,
    search,
    show,
    outdated,
    upgrade,
    clean,
    resolve,
    buildorder,
    status,

    fn fromString(s: []const u8) ?Operation {
        const map = std.StaticStringMap(Operation).initComptime(.{
            .{ "sync", .sync },
            .{ "build", .build },
            .{ "clone", .clone },
            .{ "info", .info },
            .{ "search", .search },
            .{ "show", .show },
            .{ "outdated", .outdated },
            .{ "upgrade", .upgrade },
            .{ "clean", .clean },
            .{ "resolve", .resolve },
            .{ "buildorder", .buildorder },
            .{ "status", .status },
        });
        return map.get(s);
    }

    fn isBuildOperation(self: Operation) bool {
        return switch (self) {
            .sync, .build, .upgrade => true,
            else => false,
        };
    }

    fn needsFullStack(self: Operation) bool {
        return switch (self) {
            .sync, .build, .resolve, .buildorder, .outdated, .upgrade, .clean => true,
            else => false,
        };
    }

    fn requiresTargets(self: Operation) bool {
        return switch (self) {
            .sync, .build, .clone, .info, .search, .show, .resolve, .buildorder => true,
            .outdated, .upgrade, .clean, .status => false,
        };
    }
};

const ParsedCommand = struct {
    operation: Operation,
    targets: []const []const u8,
    flags: cmd_types.Flags,
};

const ParseError = error{
    UnknownCommand,
    UnknownFlag,
    MissingArgument,
    TooManyArguments,
    HelpRequested,
    VersionRequested,
};

/// Storage for the slices in a ParsedCommand. Owned by the caller so that
/// the parsed targets and ignore list stay valid while the command runs.
const ArgStorage = struct {
    targets: [256][]const u8 = undefined,
    ignore: [256][]const u8 = undefined,
};

/// Parse raw argv into a structured command. The returned targets and
/// flags.ignore point into `storage`.
fn parseArgs(args: []const []const u8, storage: *ArgStorage) ParseError!ParsedCommand {
    const target_buf = &storage.targets;
    const ignore_buf = &storage.ignore;
    if (args.len == 0) {
        return ParseError.HelpRequested;
    }

    // Check for global flags before command
    if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        return ParseError.HelpRequested;
    }
    if (std.mem.eql(u8, args[0], "--version") or std.mem.eql(u8, args[0], "-V")) {
        return ParseError.VersionRequested;
    }

    // The first argument is the command.
    var flags = cmd_types.Flags{};
    const operation = Operation.fromString(args[0]) orelse return ParseError.UnknownCommand;
    var target_count: usize = 0;
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--help")) {
                flags.help = true;
            } else if (std.mem.eql(u8, arg, "--noconfirm")) {
                flags.noconfirm = true;
            } else if (std.mem.eql(u8, arg, "--noshow")) {
                flags.noshow = true;
            } else if (std.mem.eql(u8, arg, "--needed")) {
                flags.needed = true;
            } else if (std.mem.eql(u8, arg, "--rebuild")) {
                flags.rebuild = true;
            } else if (std.mem.eql(u8, arg, "--quiet")) {
                flags.quiet = true;
            } else if (std.mem.eql(u8, arg, "--asdeps")) {
                flags.asdeps = true;
            } else if (std.mem.eql(u8, arg, "--asexplicit")) {
                flags.asexplicit = true;
            } else if (std.mem.eql(u8, arg, "--devel")) {
                flags.devel = true;
            } else if (std.mem.eql(u8, arg, "--all")) {
                flags.all = true;
            } else if (std.mem.eql(u8, arg, "--recurse")) {
                flags.recurse = true;
            } else if (std.mem.eql(u8, arg, "--chroot")) {
                flags.chroot = true;
            } else if (std.mem.eql(u8, arg, "--ignore")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingArgument;
                // Parse comma-separated package names into ignore_buf
                var count: usize = flags.ignore.len;
                var it = std.mem.splitScalar(u8, args[i], ',');
                while (it.next()) |name| {
                    const trimmed = std.mem.trim(u8, name, " ");
                    if (trimmed.len == 0) continue;
                    if (count >= ignore_buf.len) return ParseError.TooManyArguments;
                    ignore_buf[count] = trimmed;
                    count += 1;
                }
                flags.ignore = ignore_buf[0..count];
            } else if (std.mem.eql(u8, arg, "--by")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingArgument;
                flags.by = aur.SearchField.fromString(args[i]) orelse
                    return ParseError.UnknownFlag;
            } else if (std.mem.eql(u8, arg, "--sort")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingArgument;
                flags.sort = cmd_types.SortField.fromString(args[i]) orelse
                    return ParseError.UnknownFlag;
            } else if (std.mem.eql(u8, arg, "--rsort")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingArgument;
                flags.rsort = cmd_types.SortField.fromString(args[i]) orelse
                    return ParseError.UnknownFlag;
            } else {
                return ParseError.UnknownFlag;
            }
        } else if (arg.len > 1 and arg[0] == '-') {
            // Short flags
            for (arg[1..]) |ch| {
                switch (ch) {
                    'h' => flags.help = true,
                    'q' => flags.quiet = true,
                    else => return ParseError.UnknownFlag,
                }
            }
        } else {
            // Positional argument = target
            if (target_count >= target_buf.len) return ParseError.TooManyArguments;
            target_buf[target_count] = arg;
            target_count += 1;
        }
    }

    // Validate: commands that require targets
    if (operation.requiresTargets() and target_count == 0) {
        return ParseError.MissingArgument;
    }

    return ParsedCommand{
        .operation = operation,
        .targets = target_buf[0..target_count],
        .flags = flags,
    };
}

/// Initialize the full module stack and run commands that need it.
/// Separated from run() to keep the initialization/cleanup lifecycle clear.
fn runWithFullStack(
    allocator: Allocator,
    io: std.Io,
    aur_client: *aur.Client,
    cache_root: []const u8,
    parsed: ParsedCommand,
) !ExitCode {
    var stack: commands.stack.Stack = undefined;
    stack.init(allocator, io, aur_client, cache_root, parsed.flags) catch |err| switch (err) {
        error.Reported => return .general_error,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer stack.deinit();
    var bctx = stack.buildContext();

    return switch (parsed.operation) {
        .sync => try commands.build_cmd.sync(&bctx, parsed.targets),
        .build => try commands.build_cmd.build(&bctx, parsed.targets),
        .resolve => try commands.analysis.resolve(&bctx, parsed.targets),
        .buildorder => try commands.analysis.buildorder(&bctx, parsed.targets),
        .outdated => try commands.query.outdated(&bctx, parsed.targets),
        .upgrade => try commands.build_cmd.upgrade(&bctx, parsed.targets),
        .clean => try commands.clean_cmd.run(&bctx),
        .clone => blk: {
            var qctx = query_context.QueryContext{
                .allocator = bctx.allocator,
                .io = bctx.io,
                .aur_client = bctx.aur_client,
                .pacman = bctx.pacman,
                .registry = bctx.registry,
                .cache_root = bctx.cache_root,
                .flags = bctx.flags,
                .stdout_color = bctx.stdout_color,
                .stderr_color = bctx.stderr_color,
                .err_writer = bctx.err_writer,
            };
            break :blk try commands.build_cmd.clonePackages(&qctx, parsed.targets);
        },
        else => unreachable,
    };
}

fn printHelp() void {
    output.getStdout().writeAll(
        \\aurodle: an AUR helper that builds packages into a local pacman repository
        \\
        \\Usage: aurodle <command> [options] [targets...]
        \\
        \\Commands:
        \\  sync                   Install AUR packages (resolve, clone, build, install)
        \\  build                  Build packages into local repository
        \\  upgrade                Upgrade outdated AUR packages
        \\  search <term>          Search AUR packages
        \\  info                   Display AUR package information
        \\  outdated               List outdated AUR packages
        \\  clean                  Remove uninstalled or all built packages
        \\  clone                  Clone AUR package repositories
        \\  show                   Display package build files
        \\  resolve                Show dependency tree
        \\  buildorder             Show build order (machine-readable)
        \\  status                 Check online service status
        \\
        \\Global options:
        \\  -h, --help             Show this help
        \\  -V, --version          Show version
        \\  -q, --quiet            Reduce output verbosity
        \\
        \\Build options:
        \\  --noconfirm            Skip confirmation prompts
        \\  --noshow               Skip build file review
        \\  --needed               Skip up-to-date packages
        \\  --rebuild              Force rebuild
        \\  --asdeps               Install as dependency
        \\  --asexplicit           Install as explicitly installed
        \\  --ignore <pkg,...>     Skip packages
        \\  --chroot               Build in a clean chroot (resolve,
        \\                         buildorder: resolve as for one)
        \\
        \\Clone options:
        \\  --recurse              Recursively clone AUR dependencies
        \\
        \\Clean options:
        \\  --all                  Remove all built packages and clones
        \\
        \\Outdated and upgrade options:
        \\  --devel                Check VCS packages for updates
        \\  --all                  Also check local repository packages that
        \\                         are not installed (upgrade builds them
        \\                         without installing)
        \\
        \\Search options:
        \\  --by <field>           Search by: name, name-desc, maintainer
        \\  --sort <field>         Sort by: name, votes, popularity
        \\  --rsort <field>        Reverse sort
        \\
    );
}

fn printVersion() void {
    output.getStdout().writeAll("aurodle " ++ version_string ++ "\n");
}

fn printUsageError(message: []const u8) void {
    std.debug.print("error: {s}\n", .{message});
    std.debug.print("Try 'aurodle --help' for usage information.\n", .{});
}

// ── Tests ────────────────────────────────────────────────────────────────

/// For error cases only: a successful result points into this
/// function's dead stack frame.
fn testParse(args: []const []const u8) ParseError!ParsedCommand {
    var buf: ArgStorage = .{};
    return parseArgs(args, &buf);
}

test "parseArgs: basic info command" {
    var buf: ArgStorage = .{};
    const parsed = try parseArgs(&.{ "info", "foo", "bar" }, &buf);
    try std.testing.expectEqual(Operation.info, parsed.operation);
    try std.testing.expectEqual(@as(usize, 2), parsed.targets.len);
    try std.testing.expectEqualStrings("foo", parsed.targets[0]);
    try std.testing.expectEqualStrings("bar", parsed.targets[1]);
}

test "parseArgs: flags mixed with targets" {
    var buf: ArgStorage = .{};
    const parsed = try parseArgs(&.{ "sync", "--needed", "foo", "--noconfirm" }, &buf);
    try std.testing.expectEqual(Operation.sync, parsed.operation);
    try std.testing.expectEqual(@as(usize, 1), parsed.targets.len);
    try std.testing.expectEqualStrings("foo", parsed.targets[0]);
    try std.testing.expect(parsed.flags.needed);
    try std.testing.expect(parsed.flags.noconfirm);
}

test "parseArgs: search with --by flag" {
    var buf: ArgStorage = .{};
    const parsed = try parseArgs(&.{ "search", "--by", "maintainer", "foo" }, &buf);
    try std.testing.expectEqual(Operation.search, parsed.operation);
    try std.testing.expect(parsed.flags.by != null);
    try std.testing.expectEqual(aur.SearchField.maintainer, parsed.flags.by.?);
}

test "parseArgs: empty args shows help" {
    try std.testing.expectError(ParseError.HelpRequested, testParse(&.{}));
}

test "parseArgs: --help before command" {
    try std.testing.expectError(ParseError.HelpRequested, testParse(&.{"--help"}));
}

test "parseArgs: --version flag" {
    try std.testing.expectError(ParseError.VersionRequested, testParse(&.{"--version"}));
    try std.testing.expectError(ParseError.VersionRequested, testParse(&.{"-V"}));
}

test "parseArgs: -v is not the version flag" {
    try std.testing.expectError(ParseError.UnknownCommand, testParse(&.{"-v"}));
}

test "parseArgs: unknown command" {
    try std.testing.expectError(ParseError.UnknownCommand, testParse(&.{"frobnicate"}));
}

test "parseArgs: unknown flag" {
    try std.testing.expectError(ParseError.UnknownFlag, testParse(&.{ "sync", "--turbo" }));
}

test "parseArgs: missing target for sync" {
    try std.testing.expectError(ParseError.MissingArgument, testParse(&.{"sync"}));
}

test "parseArgs: outdated with no targets is valid" {
    var buf: ArgStorage = .{};
    const parsed = try parseArgs(&.{"outdated"}, &buf);
    try std.testing.expectEqual(Operation.outdated, parsed.operation);
    try std.testing.expectEqual(@as(usize, 0), parsed.targets.len);
}

test "parseArgs: pacman-style operations are rejected" {
    try std.testing.expectError(ParseError.UnknownCommand, testParse(&.{ "-S", "foo" }));
    try std.testing.expectError(ParseError.UnknownCommand, testParse(&.{ "-Ss", "foo" }));
    try std.testing.expectError(ParseError.UnknownCommand, testParse(&.{"-Qu"}));
    try std.testing.expectError(ParseError.UnknownCommand, testParse(&.{"-Scc"}));
    try std.testing.expectError(ParseError.UnknownCommand, testParse(&.{ "S", "foo" }));
}

test "parseArgs: --recurse flag" {
    var buf: ArgStorage = .{};
    const parsed = try parseArgs(&.{ "clone", "--recurse", "foo" }, &buf);
    try std.testing.expectEqual(Operation.clone, parsed.operation);
    try std.testing.expect(parsed.flags.recurse);
}

test "parseArgs: combined short flags" {
    var buf: ArgStorage = .{};
    const parsed = try parseArgs(&.{ "search", "-q", "foo" }, &buf);
    try std.testing.expect(parsed.flags.quiet);
}

test "parseArgs: sort and rsort flags" {
    var buf1: ArgStorage = .{};
    const parsed = try parseArgs(&.{ "search", "--sort", "votes", "foo" }, &buf1);
    try std.testing.expectEqual(cmd_types.SortField.votes, parsed.flags.sort.?);

    var buf2: ArgStorage = .{};
    const parsed2 = try parseArgs(&.{ "search", "--rsort", "name", "foo" }, &buf2);
    try std.testing.expectEqual(cmd_types.SortField.name, parsed2.flags.rsort.?);
}

test "parseArgs: --noconfirm flag" {
    var buf: ArgStorage = .{};
    const parsed = try parseArgs(&.{ "sync", "--noconfirm", "foo" }, &buf);
    try std.testing.expect(parsed.flags.noconfirm);
}

test "parseArgs: --needed flag" {
    var buf: ArgStorage = .{};
    const parsed = try parseArgs(&.{ "build", "--needed", "foo" }, &buf);
    try std.testing.expect(parsed.flags.needed);
}

test "parseArgs: --rebuild flag" {
    var buf: ArgStorage = .{};
    const parsed = try parseArgs(&.{ "build", "--rebuild", "foo" }, &buf);
    try std.testing.expect(parsed.flags.rebuild);
}

test "parseArgs: --noshow flag" {
    var buf: ArgStorage = .{};
    const parsed = try parseArgs(&.{ "sync", "--noshow", "foo" }, &buf);
    try std.testing.expect(parsed.flags.noshow);
}

test "parseArgs: --asdeps and --asexplicit flags" {
    var buf1: ArgStorage = .{};
    const parsed = try parseArgs(&.{ "sync", "--asdeps", "foo" }, &buf1);
    try std.testing.expect(parsed.flags.asdeps);

    var buf2: ArgStorage = .{};
    const parsed2 = try parseArgs(&.{ "sync", "--asexplicit", "foo" }, &buf2);
    try std.testing.expect(parsed2.flags.asexplicit);
}

test "parseArgs: --devel flag" {
    var buf: ArgStorage = .{};
    const parsed = try parseArgs(&.{ "sync", "--devel", "foo" }, &buf);
    try std.testing.expect(parsed.flags.devel);
}

test "parseArgs: --all flag" {
    var buf: ArgStorage = .{};
    const parsed = try parseArgs(&.{ "clean", "--all" }, &buf);
    try std.testing.expect(parsed.flags.all);
}

test "parseArgs: --ignore flag with single package" {
    var buf: ArgStorage = .{};
    const parsed = try parseArgs(&.{ "sync", "--ignore", "foo", "bar" }, &buf);
    try std.testing.expectEqual(@as(usize, 1), parsed.flags.ignore.len);
    try std.testing.expectEqualStrings("foo", parsed.flags.ignore[0]);
}

test "parseArgs: --ignore flag with comma-separated packages" {
    var buf: ArgStorage = .{};
    const parsed = try parseArgs(&.{ "sync", "--ignore", "foo,bar,baz", "target" }, &buf);
    try std.testing.expectEqual(@as(usize, 3), parsed.flags.ignore.len);
    try std.testing.expectEqualStrings("foo", parsed.flags.ignore[0]);
    try std.testing.expectEqualStrings("bar", parsed.flags.ignore[1]);
    try std.testing.expectEqualStrings("baz", parsed.flags.ignore[2]);
}

test "parseArgs: --ignore with missing value returns MissingArgument" {
    try std.testing.expectError(ParseError.MissingArgument, testParse(&.{ "sync", "--ignore" }));
}

test "parseArgs: --by with missing value returns MissingArgument" {
    try std.testing.expectError(ParseError.MissingArgument, testParse(&.{ "search", "--by" }));
}

test "parseArgs: --sort with invalid value returns UnknownFlag" {
    try std.testing.expectError(ParseError.UnknownFlag, testParse(&.{ "search", "--sort", "invalid", "foo" }));
}

test "parseArgs: recognizes all command names" {
    const cmds = [_]struct { name: []const u8, op: Operation }{
        .{ .name = "sync", .op = .sync },
        .{ .name = "build", .op = .build },
        .{ .name = "clone", .op = .clone },
        .{ .name = "info", .op = .info },
        .{ .name = "search", .op = .search },
        .{ .name = "show", .op = .show },
        .{ .name = "resolve", .op = .resolve },
        .{ .name = "buildorder", .op = .buildorder },
    };
    for (cmds) |cmd| {
        var buf: ArgStorage = .{};
        const parsed = try parseArgs(&.{ cmd.name, "arg" }, &buf);
        try std.testing.expectEqual(cmd.op, parsed.operation);
    }
}

test "parseArgs: commands without required targets" {
    const cmds = [_][]const u8{ "outdated", "upgrade", "clean", "status" };
    for (cmds) |cmd| {
        var buf: ArgStorage = .{};
        const parsed = try parseArgs(&.{cmd}, &buf);
        try std.testing.expectEqual(@as(usize, 0), parsed.targets.len);
    }
}

test "Operation.isBuildOperation" {
    try std.testing.expect(Operation.sync.isBuildOperation());
    try std.testing.expect(Operation.build.isBuildOperation());
    try std.testing.expect(Operation.upgrade.isBuildOperation());
    try std.testing.expect(!Operation.clone.isBuildOperation());
    try std.testing.expect(!Operation.info.isBuildOperation());
    try std.testing.expect(!Operation.search.isBuildOperation());
    try std.testing.expect(!Operation.clean.isBuildOperation());
}

test "Operation.requiresTargets" {
    try std.testing.expect(Operation.sync.requiresTargets());
    try std.testing.expect(Operation.clone.requiresTargets());
    try std.testing.expect(Operation.info.requiresTargets());
    try std.testing.expect(Operation.search.requiresTargets());
    try std.testing.expect(!Operation.outdated.requiresTargets());
    try std.testing.expect(!Operation.upgrade.requiresTargets());
    try std.testing.expect(!Operation.clean.requiresTargets());
}

test "parseArgs: ignore list lives in caller storage and survives copies" {
    var storage: ArgStorage = .{};
    const parsed = try parseArgs(&.{ "sync", "--ignore", "foo,bar", "pkg" }, &storage);
    // A copy of Flags (as passed to every context) shares the storage, so
    // it stays valid however often it is copied or returned.
    const copy = parsed.flags;
    var ctx = query_context.QueryContext.init(std.testing.allocator, std.testing.io, undefined, "/tmp", copy);
    _ = &ctx;
    try std.testing.expectEqual(@as([*]const []const u8, &storage.ignore), ctx.flags.ignore.ptr);
    try std.testing.expectEqual(@as(usize, 2), ctx.flags.ignore.len);
    try std.testing.expectEqualStrings("bar", ctx.flags.ignore[1]);
}

test "parseArgs: overflowing an argument buffer is TooManyArguments" {
    // The command plus 257 targets: one more than the target storage holds.
    var many: [258][]const u8 = undefined;
    many[0] = "sync";
    for (many[1..]) |*a| a.* = "pkg";
    try std.testing.expectError(ParseError.TooManyArguments, testParse(&many));

    // 257 comma-separated names, one more than the ignore storage holds.
    var names_buf: [257 * 2]u8 = undefined;
    for (0..257) |i| {
        names_buf[2 * i] = 'a';
        names_buf[2 * i + 1] = ',';
    }
    const names = names_buf[0 .. names_buf.len - 1];
    try std.testing.expectError(ParseError.TooManyArguments, testParse(&.{ "sync", "--ignore", names, "pkg" }));
}
