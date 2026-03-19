const std = @import("std");
const aurodle = @import("aurodle");
const aur = aurodle.aur;
const commands = aurodle.commands;
const git = aurodle.git;
const pacman_mod = aurodle.pacman;
const registry_mod = aurodle.registry;
const repo_mod = aurodle.repo;
const utils = aurodle.utils;
const Allocator = std.mem.Allocator;

const ExitCode = commands.ExitCode;

const version_string = "0.0.0";

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const check = gpa.deinit();
        if (check == .leak) {
            std.log.err("memory leak detected", .{});
        }
    }
    const allocator = gpa.allocator();

    const result = run(allocator) catch |err| {
        const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
        const w = stderr.deprecatedWriter();
        w.print("error: unexpected failure: {}\n", .{err}) catch {};
        return 1;
    };

    return @intFromEnum(result);
}

fn run(allocator: Allocator) !ExitCode {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Skip argv[0] (the program name)
    const user_args = if (args.len > 1) args[1..] else args[0..0];

    // Parse arguments
    var target_buf: [256][]const u8 = undefined;
    const parsed = parseArgs(user_args, &target_buf) catch |err| switch (err) {
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

    // Commands that need the full module stack (pacman + registry + repo)
    if (parsed.operation.needsFullStack() or (parsed.operation == .clone and parsed.flags.recurse)) {
        return runWithFullStack(allocator, &aur_client, parsed);
    }

    // Simple commands that only need the AUR client
    var cmds = commands.Commands.init(allocator, &aur_client, parsed.flags);

    return switch (parsed.operation) {
        .info => try cmds.info(parsed.targets),
        .search => blk: {
            if (parsed.targets.len == 0) {
                printUsageError("search requires a query term");
                break :blk .usage_error;
            }
            break :blk try cmds.search(parsed.targets[0]);
        },
        .clone => try cmds.clonePackages(parsed.targets),
        .show => try cmds.show(parsed.targets[0]),
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
        });
        return map.get(s);
    }

    /// Pacman-style short aliases, only valid with dash prefix (-S, -Ss, etc.)
    fn fromShortAlias(s: []const u8) ?Operation {
        const map = std.StaticStringMap(Operation).initComptime(.{
            .{ "S", .sync },
            .{ "Sw", .build },
            .{ "G", .clone },
            .{ "Si", .info },
            .{ "Ss", .search },
            .{ "Qu", .outdated },
            .{ "Su", .upgrade },
            .{ "Sc", .clean },
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
            .outdated, .upgrade, .clean => false,
        };
    }
};

const ParsedCommand = struct {
    operation: Operation,
    targets: []const []const u8,
    flags: commands.Flags,
};

const ParseError = error{
    UnknownCommand,
    UnknownFlag,
    MissingArgument,
    HelpRequested,
    VersionRequested,
};

/// Parse raw argv into a structured command.
/// `target_buf` is caller-provided storage for target pointers.
fn parseArgs(args: []const []const u8, target_buf: [][]const u8) ParseError!ParsedCommand {
    if (args.len == 0) {
        return ParseError.HelpRequested;
    }

    // Check for global flags before command
    if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        return ParseError.HelpRequested;
    }
    if (std.mem.eql(u8, args[0], "--version") or std.mem.eql(u8, args[0], "-v")) {
        return ParseError.VersionRequested;
    }

    // First non-flag argument is the command.
    // Check pacman-style short aliases (-S, -Ss, -Si, etc.) then full names.
    var flags = commands.Flags{};
    const operation = if (args[0].len >= 2 and args[0][0] == '-' and args[0][1] != '-') blk: {
        const alias = args[0][1..];
        // -Scc is special: maps to clean --all
        if (std.mem.eql(u8, alias, "Scc")) {
            flags.all = true;
            break :blk Operation.clean;
        }
        // -Gr is special: maps to clone --recurse
        if (std.mem.eql(u8, alias, "Gr")) {
            flags.recurse = true;
            break :blk Operation.clone;
        }
        break :blk Operation.fromShortAlias(alias) orelse return ParseError.UnknownCommand;
    } else Operation.fromString(args[0]) orelse return ParseError.UnknownCommand;
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
            } else if (std.mem.eql(u8, arg, "--raw")) {
                flags.raw = true;
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
            } else if (std.mem.eql(u8, arg, "--ignore")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingArgument;
                // Parse comma-separated package names into ignore_buf
                var count: usize = flags.ignore.len;
                var it = std.mem.splitScalar(u8, args[i], ',');
                while (it.next()) |name| {
                    const trimmed = std.mem.trim(u8, name, " ");
                    if (trimmed.len == 0) continue;
                    if (count >= flags.ignore_buf.len) return ParseError.MissingArgument;
                    flags.ignore_buf[count] = trimmed;
                    count += 1;
                }
                flags.ignore = flags.ignore_buf[0..count];
            } else if (std.mem.eql(u8, arg, "--by")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingArgument;
                flags.by = aur.SearchField.fromString(args[i]) orelse
                    return ParseError.UnknownFlag;
            } else if (std.mem.eql(u8, arg, "--sort")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingArgument;
                flags.sort = commands.SortField.fromString(args[i]) orelse
                    return ParseError.UnknownFlag;
            } else if (std.mem.eql(u8, arg, "--rsort")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingArgument;
                flags.rsort = commands.SortField.fromString(args[i]) orelse
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
            if (target_count >= target_buf.len) return ParseError.MissingArgument;
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
    aur_client: *aur.Client,
    parsed: ParsedCommand,
) !ExitCode {
    // Initialize local repository first (derives repo name from pacman.conf + PKGDEST)
    var repository = repo_mod.Repository.init(allocator) catch |err| {
        const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
        const w = stderr.deprecatedWriter();
        if (err == error.PkgdestNotSet) {
            w.writeAll("error: PKGDEST is not set in /etc/makepkg.conf\n") catch {};
        } else if (err == error.RepoNotInPacmanConf) {
            w.writeAll("error: no pacman.conf repo has a Server = file:// matching PKGDEST\n") catch {};
            w.writeAll(repo_mod.Repository.configInstructions()) catch {};
            w.writeByte('\n') catch {};
        } else {
            w.print("error: failed to initialize repository: {}\n", .{err}) catch {};
        }
        return .general_error;
    };
    defer repository.deinit();

    // Initialize pacman (libalpm) with the derived repo name
    var pm = pacman_mod.Pacman.init(allocator, repository.repo_name) catch |err| {
        const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
        const w = stderr.deprecatedWriter();
        w.print("error: failed to initialize pacman: {}\n", .{err}) catch {};
        return .general_error;
    };
    defer pm.deinit();

    // Merge IgnorePkg from pacman.conf with --ignore flag
    var flags = parsed.flags;
    if (pm.ignore_pkgs.len > 0) {
        var count: usize = flags.ignore.len;
        for (pm.ignore_pkgs) |pkg| {
            if (count >= flags.ignore_buf.len) break;
            // Skip duplicates already in CLI --ignore
            var dup = false;
            for (flags.ignore) |existing| {
                if (std.mem.eql(u8, existing, pkg)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) {
                flags.ignore_buf[count] = pkg;
                count += 1;
            }
        }
        flags.ignore = flags.ignore_buf[0..count];
    }

    // Initialize registry (cascade lookup: installed -> sync -> AUR -> provider)
    var reg = registry_mod.PackageRegistry.init(allocator, &pm, aur_client);
    defer reg.deinit();

    // Enable interactive provider selection unless --noconfirm
    if (!parsed.flags.noconfirm) {
        reg.provider_chooser = &utils.promptProviderChoice;
    }

    // Get cache root for git operations
    const cache_root = git.defaultCacheRoot(allocator) catch {
        const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
        stderr.writeAll("error: could not determine cache directory (HOME not set)\n") catch {};
        return .general_error;
    };
    defer allocator.free(cache_root);

    var cmds = commands.Commands.initFull(
        allocator,
        aur_client,
        &pm,
        &reg,
        &repository,
        cache_root,
        flags,
    );

    return switch (parsed.operation) {
        .sync => try cmds.sync(parsed.targets),
        .build => try cmds.build(parsed.targets),
        .resolve => try cmds.resolve(parsed.targets),
        .buildorder => try cmds.buildorder(parsed.targets),
        .outdated => try cmds.outdated(parsed.targets),
        .upgrade => try cmds.upgrade(parsed.targets),
        .clean => try cmds.clean(),
        .clone => try cmds.clonePackages(parsed.targets),
        else => unreachable,
    };
}

fn printHelp() void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    stdout.writeAll(
        \\aurodle — newt your average AUR helper
        \\
        \\Usage: aurodle <command> [options] [targets...]
        \\
        \\Commands:
        \\  sync,  -S              Install AUR packages (resolve, clone, build, install)
        \\  build, -Sw             Build packages into local repository
        \\  clone, -G, -Gr         Clone AUR package repositories
        \\  info,  -Si             Display AUR package information
        \\  search, -Ss <term>     Search AUR packages
        \\  show                   Display package build files
        \\  resolve                Show dependency tree
        \\  buildorder             Show build order (machine-readable)
        \\  outdated, -Qu          List outdated AUR packages
        \\  upgrade, -Su           Upgrade outdated AUR packages
        \\  clean, -Sc, -Scc       Remove stale or all cache files
        \\
        \\Global options:
        \\  -h, --help             Show this help
        \\  -v, --version          Show version
        \\  -q, --quiet            Reduce output verbosity
        \\
        \\Build options:
        \\  --noconfirm            Skip confirmation prompts
        \\  --noshow               Skip build file review
        \\  --needed               Skip up-to-date packages
        \\  --rebuild              Force rebuild
        \\  --asdeps               Install as dependency
        \\  --asexplicit           Install as explicitly installed
        \\  --devel                Check VCS packages (-git, -svn, etc.) for updates
        \\  --ignore <pkg,...>     Skip packages (comma-separated)
        \\
        \\Clone options:
        \\  --recurse              Recursively clone AUR dependencies
        \\
        \\Clean options:
        \\  --all                  Remove all built packages (not just uninstalled)
        \\
        \\Search options:
        \\  --by <field>           Search by: name, name-desc, maintainer
        \\  --sort <field>         Sort by: name, votes, popularity
        \\  --rsort <field>        Reverse sort
        \\  --raw                  Output raw JSON
        \\
    ) catch {};
}

fn printVersion() void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    stdout.writeAll("aurodle " ++ version_string ++ "\n") catch {};
}

fn printUsageError(message: []const u8) void {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    const w = stderr.deprecatedWriter();
    w.print("error: {s}\n", .{message}) catch {};
    stderr.writeAll("Try 'aurodle --help' for usage information.\n") catch {};
}

// ── Tests ────────────────────────────────────────────────────────────────

fn testParse(args: []const []const u8) ParseError!ParsedCommand {
    var buf: [256][]const u8 = undefined;
    return parseArgs(args, &buf);
}

test "parseArgs: basic info command" {
    var buf: [256][]const u8 = undefined;
    const parsed = try parseArgs(&.{ "info", "foo", "bar" }, &buf);
    try std.testing.expectEqual(Operation.info, parsed.operation);
    try std.testing.expectEqual(@as(usize, 2), parsed.targets.len);
    try std.testing.expectEqualStrings("foo", parsed.targets[0]);
    try std.testing.expectEqualStrings("bar", parsed.targets[1]);
}

test "parseArgs: flags mixed with targets" {
    var buf: [256][]const u8 = undefined;
    const parsed = try parseArgs(&.{ "sync", "--needed", "foo", "--noconfirm" }, &buf);
    try std.testing.expectEqual(Operation.sync, parsed.operation);
    try std.testing.expectEqual(@as(usize, 1), parsed.targets.len);
    try std.testing.expectEqualStrings("foo", parsed.targets[0]);
    try std.testing.expect(parsed.flags.needed);
    try std.testing.expect(parsed.flags.noconfirm);
}

test "parseArgs: search with --by flag" {
    var buf: [256][]const u8 = undefined;
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
    var buf: [256][]const u8 = undefined;
    const parsed = try parseArgs(&.{"outdated"}, &buf);
    try std.testing.expectEqual(Operation.outdated, parsed.operation);
    try std.testing.expectEqual(@as(usize, 0), parsed.targets.len);
}

test "parseArgs: dashless short aliases are rejected" {
    try std.testing.expectError(ParseError.UnknownCommand, testParse(&.{ "S", "foo" }));
    try std.testing.expectError(ParseError.UnknownCommand, testParse(&.{ "Si", "foo" }));
    try std.testing.expectError(ParseError.UnknownCommand, testParse(&.{ "Ss", "foo" }));
    try std.testing.expectError(ParseError.UnknownCommand, testParse(&.{ "G", "foo" }));
    try std.testing.expectError(ParseError.UnknownCommand, testParse(&.{ "Gr", "foo" }));
    try std.testing.expectError(ParseError.UnknownCommand, testParse(&.{ "Sc", "foo" }));
    try std.testing.expectError(ParseError.UnknownCommand, testParse(&.{ "Scc", "foo" }));
}

test "parseArgs: dash-prefixed short aliases" {
    var buf1: [256][]const u8 = undefined;
    const parsed = try parseArgs(&.{ "-S", "foo" }, &buf1);
    try std.testing.expectEqual(Operation.sync, parsed.operation);

    var buf2: [256][]const u8 = undefined;
    const parsed2 = try parseArgs(&.{ "-Si", "foo" }, &buf2);
    try std.testing.expectEqual(Operation.info, parsed2.operation);

    var buf3: [256][]const u8 = undefined;
    const parsed3 = try parseArgs(&.{ "-Ss", "foo" }, &buf3);
    try std.testing.expectEqual(Operation.search, parsed3.operation);

    var buf4: [256][]const u8 = undefined;
    const parsed4 = try parseArgs(&.{"-Qu"}, &buf4);
    try std.testing.expectEqual(Operation.outdated, parsed4.operation);

    var buf5: [256][]const u8 = undefined;
    const parsed5 = try parseArgs(&.{"-Su"}, &buf5);
    try std.testing.expectEqual(Operation.upgrade, parsed5.operation);

    var buf6: [256][]const u8 = undefined;
    const parsed6 = try parseArgs(&.{ "-Sw", "foo" }, &buf6);
    try std.testing.expectEqual(Operation.build, parsed6.operation);

    var buf7: [256][]const u8 = undefined;
    const parsed7 = try parseArgs(&.{ "-G", "foo" }, &buf7);
    try std.testing.expectEqual(Operation.clone, parsed7.operation);

    var buf8: [256][]const u8 = undefined;
    const parsed8 = try parseArgs(&.{"-Sc"}, &buf8);
    try std.testing.expectEqual(Operation.clean, parsed8.operation);
    try std.testing.expect(!parsed8.flags.all);

    var buf9: [256][]const u8 = undefined;
    const parsed9 = try parseArgs(&.{"-Scc"}, &buf9);
    try std.testing.expectEqual(Operation.clean, parsed9.operation);
    try std.testing.expect(parsed9.flags.all);

    var buf10: [256][]const u8 = undefined;
    const parsed10 = try parseArgs(&.{ "-Gr", "foo" }, &buf10);
    try std.testing.expectEqual(Operation.clone, parsed10.operation);
    try std.testing.expect(parsed10.flags.recurse);
}

test "parseArgs: --recurse flag" {
    var buf: [256][]const u8 = undefined;
    const parsed = try parseArgs(&.{ "clone", "--recurse", "foo" }, &buf);
    try std.testing.expectEqual(Operation.clone, parsed.operation);
    try std.testing.expect(parsed.flags.recurse);
}

test "parseArgs: combined short flags" {
    var buf: [256][]const u8 = undefined;
    const parsed = try parseArgs(&.{ "search", "-q", "foo" }, &buf);
    try std.testing.expect(parsed.flags.quiet);
}

test "parseArgs: sort and rsort flags" {
    var buf1: [256][]const u8 = undefined;
    const parsed = try parseArgs(&.{ "search", "--sort", "votes", "foo" }, &buf1);
    try std.testing.expectEqual(commands.SortField.votes, parsed.flags.sort.?);

    var buf2: [256][]const u8 = undefined;
    const parsed2 = try parseArgs(&.{ "search", "--rsort", "name", "foo" }, &buf2);
    try std.testing.expectEqual(commands.SortField.name, parsed2.flags.rsort.?);
}

test "parseArgs: --noconfirm flag" {
    var buf: [256][]const u8 = undefined;
    const parsed = try parseArgs(&.{ "sync", "--noconfirm", "foo" }, &buf);
    try std.testing.expect(parsed.flags.noconfirm);
}

test "parseArgs: --needed flag" {
    var buf: [256][]const u8 = undefined;
    const parsed = try parseArgs(&.{ "build", "--needed", "foo" }, &buf);
    try std.testing.expect(parsed.flags.needed);
}

test "parseArgs: --rebuild flag" {
    var buf: [256][]const u8 = undefined;
    const parsed = try parseArgs(&.{ "build", "--rebuild", "foo" }, &buf);
    try std.testing.expect(parsed.flags.rebuild);
}

test "parseArgs: --raw flag" {
    var buf: [256][]const u8 = undefined;
    const parsed = try parseArgs(&.{ "info", "--raw", "foo" }, &buf);
    try std.testing.expect(parsed.flags.raw);
}

test "parseArgs: --noshow flag" {
    var buf: [256][]const u8 = undefined;
    const parsed = try parseArgs(&.{ "sync", "--noshow", "foo" }, &buf);
    try std.testing.expect(parsed.flags.noshow);
}

test "parseArgs: --asdeps and --asexplicit flags" {
    var buf1: [256][]const u8 = undefined;
    const parsed = try parseArgs(&.{ "sync", "--asdeps", "foo" }, &buf1);
    try std.testing.expect(parsed.flags.asdeps);

    var buf2: [256][]const u8 = undefined;
    const parsed2 = try parseArgs(&.{ "sync", "--asexplicit", "foo" }, &buf2);
    try std.testing.expect(parsed2.flags.asexplicit);
}

test "parseArgs: --devel flag" {
    var buf: [256][]const u8 = undefined;
    const parsed = try parseArgs(&.{ "sync", "--devel", "foo" }, &buf);
    try std.testing.expect(parsed.flags.devel);
}

test "parseArgs: --all flag" {
    var buf: [256][]const u8 = undefined;
    const parsed = try parseArgs(&.{ "clean", "--all" }, &buf);
    try std.testing.expect(parsed.flags.all);
}

test "parseArgs: --ignore flag with single package" {
    var buf: [256][]const u8 = undefined;
    const parsed = try parseArgs(&.{ "sync", "--ignore", "foo", "bar" }, &buf);
    try std.testing.expectEqual(@as(usize, 1), parsed.flags.ignore.len);
    try std.testing.expectEqualStrings("foo", parsed.flags.ignore[0]);
}

test "parseArgs: --ignore flag with comma-separated packages" {
    var buf: [256][]const u8 = undefined;
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
        var buf: [256][]const u8 = undefined;
        const parsed = try parseArgs(&.{ cmd.name, "arg" }, &buf);
        try std.testing.expectEqual(cmd.op, parsed.operation);
    }
}

test "parseArgs: commands without required targets" {
    const cmds = [_][]const u8{ "outdated", "upgrade", "clean" };
    for (cmds) |cmd| {
        var buf: [256][]const u8 = undefined;
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
