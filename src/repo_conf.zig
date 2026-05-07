const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DEFAULT_REPO_NAME = "aur";

/// Check if [repo_name] is configured in a pacman.conf file.
pub fn isConfiguredFromPath(path: []const u8) bool {
    return isConfiguredFromPathWithName(path, DEFAULT_REPO_NAME);
}

/// Check if [name] is configured in a pacman.conf file.
fn isConfiguredFromPathWithName(path: []const u8, name: []const u8) bool {
    // pacman.conf is small — read entire file
    var buf: [64 * 1024]u8 = undefined;
    const content = std.Io.Dir.readFile(std.Io.Dir.cwd(), std.Options.debug_io, path, &buf) catch return false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        // Match [name] section header
        if (trimmed.len < 3 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') continue;
        if (std.mem.eql(u8, trimmed[1 .. trimmed.len - 1], name)) return true;
    }
    return false;
}

/// Derive the local AUR repository name from pacman.conf by finding a section
/// whose `Server = file://` URL matches the given PKGDEST path.
///
/// For example, if PKGDEST is `/var/lib/aurodle/mypkgs` and pacman.conf contains:
///   [mypkgs]
///   Server = file:///var/lib/aurodle/mypkgs
///
/// This returns "mypkgs".
pub fn deriveRepoNameFromPacmanConf(allocator: Allocator, pkgdest: []const u8) !?[]const u8 {
    var buf: [64 * 1024]u8 = undefined;
    const content = std.Io.Dir.readFile(std.Io.Dir.cwd(), std.Options.debug_io, "/etc/pacman.conf", &buf) catch return null;

    var current_section: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Section header: [reponame]
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            const name = trimmed[1 .. trimmed.len - 1];
            if (std.mem.eql(u8, name, "options")) {
                current_section = null;
            } else {
                current_section = name;
            }
            continue;
        }

        // Server directive with file:// protocol
        if (current_section != null and std.mem.startsWith(u8, trimmed, "Server")) {
            const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const url = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

            // Match "file:///path" against pkgdest
            if (std.mem.startsWith(u8, url, "file://")) {
                const server_path = url["file://".len..];
                if (std.mem.eql(u8, server_path, pkgdest)) {
                    return try allocator.dupe(u8, current_section.?);
                }
            }
        }
    }

    return null;
}

test {
    std.testing.refAllDecls(@This());
}
