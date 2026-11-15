//! pacsaur: pacman's command line for official and AUR packages.
//!
//! Parses a pacman-style command line, routes it (`route`), then runs the
//! steps in order: pacman as a child process, the AUR commands in-process.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const utils = core.utils;
const output = @import("ui").output;
const commands = @import("commands");
const ExitCode = commands.types.ExitCode;
const args = @import("args.zig");
const classify = @import("classify.zig");
const route = @import("route.zig");

const version_string = @import("build_options").version;

pub fn main(init: std.process.Init) u8 {
    utils.global_io = init.io;
    defer utils.flushStdout();

    return run(init.gpa, init.io, init.minimal.args) catch |err| {
        utils.flushStdout();
        std.debug.print("error: unexpected failure: {}\n", .{err});
        return 1;
    };
}

fn run(allocator: Allocator, io: std.Io, raw_args: std.process.Args) !u8 {
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    var it = std.process.Args.Iterator.init(raw_args);
    while (it.next()) |arg| try argv_list.append(allocator, arg);

    var inv = args.parse(allocator, argv_list.items) catch |err| switch (err) {
        error.OwnFlagConflict => return usageError("--repo and --aur cannot be used together", .{}),
        error.ContradictoryHint => return usageError("--repo cannot be used with an aur/ target", .{}),
        error.MissingArgument => return usageError("missing argument for an option", .{}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer inv.deinit();

    if (inv.own.help) {
        printHelp();
        return 0;
    }
    if (inv.own.version) {
        output.getStdout().writeAll("pacsaur " ++ version_string ++ "\n");
        return 0;
    }

    var diag: route.Diagnostic = .{};
    var plan = buildPlan(allocator, &inv, &diag) catch |err| switch (err) {
        error.AurOnlyFlag => return usageError("{s} only applies to AUR packages", .{diag.option}),
        error.NotAurOperation => return usageError("--aur cannot be used with this operation", .{}),
        error.InvalidValue => return usageError("invalid value for {s}", .{diag.option}),
        error.Reported => return 1,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer plan.deinit();

    if (inv.own.dry_run) {
        printPlan(&plan);
        return 0;
    }

    const root = std.c.geteuid() == 0;
    // makepkg refuses to run as root, and would only do so after pacman
    // has changed the system.
    if (root and plan.buildsAur()) {
        std.debug.print("error: AUR packages cannot be built as root\n", .{});
        return 1;
    }
    if (plan.hasPacmanStep() and !utils.findOnPath("pacman")) {
        std.debug.print("error: pacman not found on PATH\n", .{});
        return 1;
    }

    var auth: ?core.auth.Auth = null;
    defer if (auth) |*a| a.deinit();
    if (!root and plan.needsElevation()) {
        auth = initAuth(allocator) orelse return 1;
        if (!try authenticate(&auth.?)) return 1;
    }

    var status: u8 = 0;
    for (plan.steps) |step| {
        status = switch (step) {
            .pacman => |p| try runPacman(allocator, p, if (p.elevate) auth else null),
            .aur => |a| @backingInt(try runAur(allocator, io, a, plan.flags)),
        };
    }
    return status;
}

fn buildPlan(allocator: Allocator, inv: *const args.Invocation, diag: *route.Diagnostic) (route.Error || error{Reported})!route.Plan {
    if (inv.own.force != null or inv.class != .split) {
        return route.build(allocator, inv, NoClassifier{}, diag);
    }
    var classifier = classify.Classifier.init(allocator) catch |err| {
        std.debug.print("error: failed to read the sync databases: {}\n", .{err});
        return error.Reported;
    };
    defer classifier.deinit();
    return route.build(allocator, inv, &classifier, diag);
}

/// For plans that never classify a target.
const NoClassifier = struct {
    pub fn source(_: NoClassifier, _: []const u8) classify.Source {
        unreachable;
    }
};

fn initAuth(allocator: Allocator) ?core.auth.Auth {
    const conf = core.makepkg.parseMakepkgConf(allocator) catch core.makepkg.MakepkgConfig{};
    defer conf.deinit(allocator);
    return core.auth.Auth.init(allocator, conf.pacman_auth) catch |err| {
        if (err == error.NoAuthMethod) {
            std.debug.print("error: no privilege escalation method found (sudo/su not on PATH)\n", .{});
        } else {
            std.debug.print("error: failed to initialize auth: {}\n", .{err});
        }
        return null;
    };
}

/// Get credentials before any step runs, so that a refused password
/// changes nothing rather than failing pacman and going on to the AUR.
/// Runs pacman itself rather than `sudo -v`, which a rule allowing only
/// pacman without a password would answer with a prompt.
fn authenticate(auth: *const core.auth.Auth) !bool {
    if (!auth.cachesCredentials()) return true;
    const result = try auth.runCaptured(&.{ "pacman", "--version" });
    defer result.deinit(auth.allocator);
    if (result.success()) return true;
    std.debug.print("error: authentication failed\n", .{});
    return false;
}

fn runPacman(allocator: Allocator, step: route.PacmanStep, auth: ?core.auth.Auth) !u8 {
    const argv = try allocator.alloc([]const u8, step.argv.len + 1);
    defer allocator.free(argv);
    argv[0] = "pacman";
    @memcpy(argv[1..], step.argv);
    if (auth) |a| return a.runInteractive(argv, null);
    return utils.runInteractive(allocator, argv, null);
}

fn runAur(allocator: Allocator, io: std.Io, step: route.AurStep, flags: commands.types.Flags) !ExitCode {
    var aur_client = core.aur.Client.init(allocator);
    defer aur_client.deinit();

    const cache_root = core.git.defaultCacheRoot(allocator) catch {
        std.debug.print("error: could not determine cache directory (HOME not set)\n", .{});
        return .general_error;
    };
    defer allocator.free(cache_root);

    switch (step.op) {
        .info, .search => {
            var qctx = commands.query_context.QueryContext.init(allocator, io, &aur_client, cache_root, flags);
            if (step.op == .info) return commands.query.info(&qctx, step.targets);
            if (step.targets.len == 0) return usageErrorCode("--aur -Ss requires a search term");
            return commands.query.search(&qctx, step.targets);
        },
        else => {},
    }

    // Opened now rather than up front, so that it reads the databases as
    // the pacman step left them.
    var stack: commands.stack.Stack = undefined;
    stack.init(allocator, io, &aur_client, cache_root, flags) catch |err| switch (err) {
        error.Reported => return .general_error,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer stack.deinit();
    var bctx = stack.buildContext();

    return switch (step.op) {
        .sync => commands.build_cmd.sync(&bctx, step.targets),
        .build => commands.build_cmd.build(&bctx, step.targets),
        .upgrade => commands.build_cmd.upgrade(&bctx, step.targets),
        .outdated => commands.query.outdated(&bctx, step.targets),
        .clean => commands.build_cmd.clean(&bctx),
        .info, .search => unreachable,
    };
}

fn usageError(comptime fmt: []const u8, a: anytype) u8 {
    std.debug.print("error: " ++ fmt ++ "\n", a);
    std.debug.print("Try 'pacsaur --help' for usage information.\n", .{});
    return @backingInt(ExitCode.usage_error);
}

fn usageErrorCode(comptime message: []const u8) ExitCode {
    _ = usageError(message, .{});
    return .usage_error;
}

fn printPlan(plan: *const route.Plan) void {
    const w = output.getStdout();
    for (plan.steps) |step| switch (step) {
        .pacman => |p| {
            w.writeAll(if (p.elevate) "pacman (root):" else "pacman:");
            for (p.argv) |arg| w.print(" {s}", .{arg});
            w.writeByte('\n');
        },
        .aur => |a| {
            w.print("aur: {s}", .{@tagName(a.op)});
            for (plan.aur_options) |opt| w.print(" {s}", .{opt});
            for (a.targets) |t| w.print(" {s}", .{t});
            w.writeByte('\n');
        },
    };
}

fn printHelp() void {
    output.getStdout().writeAll(
        \\pacsaur: pacman's command line for official and AUR packages
        \\
        \\Usage: pacsaur <operation> [options] [targets...]
        \\
        \\Operations covering official and AUR packages:
        \\  -S                     Install packages
        \\  -Sw                    Download or build packages without installing
        \\  -Si                    Display package information
        \\  -Ss                    Search packages
        \\  -Su, -Syu              Upgrade packages
        \\  -Qu                    List upgradable packages
        \\  -Sc, -Scc              Clean package caches and built packages
        \\
        \\Any other operation goes to pacman alone.
        \\
        \\Targets:
        \\  aur/<name>             Take <name> from the AUR
        \\
        \\Options:
        \\  -h, --help             Show this help
        \\  -V, --version          Show version
        \\  --dry-run              Show what would run, without running it
        \\  --repo                 Send the whole command to pacman
        \\  --aur                  Send the whole command to the AUR side
        \\
        \\AUR options:
        \\  --noshow               Skip build file review
        \\  --rebuild              Force rebuild
        \\  --chroot               Build in a clean chroot
        \\  --devel                Check VCS packages for updates (-Su, -Qu)
        \\  --all                  Also check local repository packages that
        \\                         are not installed (-Su, -Qu)
        \\  --by <field>           Search by: name, name-desc, maintainer
        \\  --sort <field>         Sort by: name, votes, popularity
        \\  --rsort <field>        Reverse sort
        \\
        \\--needed, --noconfirm, --asdeps, --asexplicit, --ignore and -q apply
        \\to both sides. Other options go to pacman only.
        \\
    );
}

test {
    _ = args;
    _ = classify;
    _ = route;
}
