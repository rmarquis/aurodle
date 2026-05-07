const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DEFAULT_PKGEXT = ".pkg.tar.zst";

/// Parsed makepkg.conf values used by Repository initialization.
pub const MakepkgConfig = struct {
    pkgdest: ?[]const u8 = null,
    pkgext: []const u8 = DEFAULT_PKGEXT,
    owns_pkgext: bool = false,
    pacman_auth: ?[]const u8 = null,

    pub fn deinit(self: MakepkgConfig, allocator: Allocator) void {
        if (self.pkgdest) |p| allocator.free(p);
        if (self.owns_pkgext) allocator.free(self.pkgext);
        if (self.pacman_auth) |a| allocator.free(a);
    }
};

/// Parse PKGDEST and PKGEXT from makepkg.conf files.
/// Reads /etc/makepkg.conf first, then ~/.makepkg.conf (user overrides).
/// Environment variables override config files.
pub fn parseMakepkgConf(allocator: Allocator) !MakepkgConfig {
    var config = MakepkgConfig{};

    // System config
    parseMakepkgConfFromFile(allocator, "/etc/makepkg.conf", &config) catch {};

    // User config (overrides system)
    if (std.c.getenv("HOME")) |ptr| {
        const user_conf = try std.fs.path.join(allocator, &.{ std.mem.span(ptr), ".makepkg.conf" });
        defer allocator.free(user_conf);
        parseMakepkgConfFromFile(allocator, user_conf, &config) catch {};
    }

    // Environment variables override everything
    if (std.c.getenv("PKGDEST")) |ptr| {
        if (config.pkgdest) |old| allocator.free(old);
        config.pkgdest = try allocator.dupe(u8, std.mem.span(ptr));
    }
    if (std.c.getenv("PKGEXT")) |ptr| {
        if (config.owns_pkgext) allocator.free(config.pkgext);
        config.pkgext = try allocator.dupe(u8, std.mem.span(ptr));
        config.owns_pkgext = true;
    }
    if (std.c.getenv("PACMAN_AUTH")) |ptr| {
        if (config.pacman_auth) |old| allocator.free(old);
        config.pacman_auth = try allocator.dupe(u8, std.mem.span(ptr));
    }

    return config;
}

/// Parse a single makepkg.conf file for PKGDEST and PKGEXT.
pub fn parseMakepkgConfFromFile(allocator: Allocator, path: []const u8, config: *MakepkgConfig) !void {
    var buf: [64 * 1024]u8 = undefined;
    const content = std.Io.Dir.readFile(std.Io.Dir.cwd(), std.Options.debug_io, path, &buf) catch return error.RepoAddFailed;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (parseAssignment(trimmed, "PKGDEST")) |val| {
            if (config.pkgdest) |old| allocator.free(old);
            config.pkgdest = try allocator.dupe(u8, stripQuotes(val));
        } else if (parseAssignment(trimmed, "PKGEXT")) |val| {
            if (config.owns_pkgext) allocator.free(config.pkgext);
            config.pkgext = try allocator.dupe(u8, stripQuotes(val));
            config.owns_pkgext = true;
        } else if (parseAssignment(trimmed, "PACMAN_AUTH")) |val| {
            if (config.pacman_auth) |old| allocator.free(old);
            config.pacman_auth = try allocator.dupe(u8, stripBashArray(stripQuotes(val)));
        }
    }
}

// ── Internal Helpers ─────────────────────────────────────────────────────

/// Parse "KEY=value" and return value if key matches.
fn parseAssignment(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    if (line.len <= key.len or line[key.len] != '=') return null;
    return line[key.len + 1 ..];
}

/// Strip surrounding single or double quotes from a value.
fn stripQuotes(val: []const u8) []const u8 {
    if (val.len >= 2) {
        if ((val[0] == '"' and val[val.len - 1] == '"') or
            (val[0] == '\'' and val[val.len - 1] == '\''))
        {
            return val[1 .. val.len - 1];
        }
    }
    return val;
}

/// Strip bash array syntax: "(content)" → "content".
/// Also strips quotes from the inner content.
/// Handles: (sudo), ("doas"), ('doas -s'), (sudo --askpass)
fn stripBashArray(val: []const u8) []const u8 {
    if (val.len >= 2 and val[0] == '(' and val[val.len - 1] == ')') {
        return stripQuotes(val[1 .. val.len - 1]);
    }
    return val;
}

test {
    std.testing.refAllDecls(@This());
}
