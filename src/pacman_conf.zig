const std = @import("std");
const alpm = @import("alpm.zig");

/// Parsed pacman.conf state returned by registerSyncDbs.
pub const PacmanConf = struct {
    sync_dbs: []alpm.Database,
    verbose_pkg_lists: bool,
    color: bool,
    ignore_pkgs: []const []const u8,
};

/// Parse a "Key = Value" config line, returning trimmed value if key matches.
fn parseDirectiveValue(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    return std.mem.trim(u8, line[eq_pos + 1 ..], " \t");
}

/// Parse /etc/pacman.conf and register each [repo] section as a sync database.
/// Handles Include directives for mirror server lists.
pub fn registerSyncDbs(allocator: std.mem.Allocator, handle: alpm.Handle) !PacmanConf {
    var dbs: std.ArrayList(alpm.Database) = .empty;
    defer dbs.deinit(allocator);

    // pacman.conf is small — read entire file
    var buf: [64 * 1024]u8 = undefined;
    const content = std.Io.Dir.readFile(std.Io.Dir.cwd(), std.Options.debug_io, "/etc/pacman.conf", &buf) catch
        return error.PacmanConfNotFound;

    var current_repo: ?alpm.Database = null;
    var in_options = false;
    var verbose_pkg_lists = false;
    var color_opt = false;
    var ignore_pkgs: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip comments and empty lines
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Section header: [reponame]
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            const name = trimmed[1 .. trimmed.len - 1];
            if (std.mem.eql(u8, name, "options")) {
                current_repo = null;
                in_options = true;
                continue;
            }
            in_options = false;

            const db = handle.registerSyncDb(name, .use_default) catch {
                current_repo = null;
                continue;
            };
            try dbs.append(allocator, db);
            current_repo = db;
            continue;
        }

        // Options section directives
        if (in_options) {
            if (std.mem.eql(u8, trimmed, "VerbosePkgLists")) verbose_pkg_lists = true;
            if (std.mem.eql(u8, trimmed, "Color")) color_opt = true;
            if (parseDirectiveValue(trimmed, "IgnorePkg")) |value| {
                var it = std.mem.tokenizeAny(u8, value, " \t");
                while (it.next()) |pkg| {
                    try ignore_pkgs.append(allocator, try allocator.dupe(u8, pkg));
                }
            }
        }

        if (current_repo) |repo| {
            if (parseDirectiveValue(trimmed, "Include")) |path| {
                addServersFromMirrorlist(repo, path);
            }
            if (parseDirectiveValue(trimmed, "Server")) |url| {
                repo.addServer(url) catch {};
            }
        }
    }

    return .{
        .sync_dbs = try dbs.toOwnedSlice(allocator),
        .verbose_pkg_lists = verbose_pkg_lists,
        .color = color_opt,
        .ignore_pkgs = try ignore_pkgs.toOwnedSlice(allocator),
    };
}

/// Read a mirrorlist file and add each Server= URL to the database.
fn addServersFromMirrorlist(db: alpm.Database, path: []const u8) void {
    var buf: [256 * 1024]u8 = undefined;
    const content = std.Io.Dir.readFile(std.Io.Dir.cwd(), std.Options.debug_io, path, &buf) catch return;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (parseDirectiveValue(trimmed, "Server")) |url| {
            db.addServer(url) catch {};
        }
    }
}

/// Return true when running on an Arch Linux system (has pacman local db).
pub fn isArchLinux() bool {
    std.Io.Dir.accessAbsolute(std.Options.debug_io, "/var/lib/pacman/local", .{}) catch return false;
    return true;
}

test {
    std.testing.refAllDecls(@This());
}
