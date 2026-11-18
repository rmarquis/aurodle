//! Classification: does a target name an official or an AUR package?
//!
//! Reads only the local sync databases through libalpm; no network. The
//! local AUR repository is the pacman.conf repository whose `file://`
//! server is PKGDEST, as for the build commands.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

pub const Source = enum {
    /// A package, group or provider in an official repository: pacman
    /// installs it.
    official,
    /// A package in the local AUR repository: the AUR side checks it for an
    /// update rather than installing the built package as it is.
    local_aur,
    /// In no repository: a new AUR package.
    neither,
};

pub const Classifier = struct {
    allocator: Allocator,
    pacman: core.pacman.Pacman,
    /// Owned; `pacman` borrows it. Empty when no local AUR repository is
    /// set up, in which case nothing is `local_aur`.
    repo_name: []const u8,

    pub fn init(allocator: Allocator) !Classifier {
        const repo_name = try localRepoName(allocator);
        errdefer allocator.free(repo_name);
        return .{
            .allocator = allocator,
            .pacman = try core.pacman.Pacman.init(allocator, repo_name),
            .repo_name = repo_name,
        };
    }

    pub fn deinit(self: *Classifier) void {
        self.pacman.deinit();
        self.allocator.free(self.repo_name);
        self.* = undefined;
    }

    pub fn source(self: *const Classifier, name: []const u8) Source {
        return sourceOf(self.pacman, name);
    }
};

/// An exact name wins over a group or provider, so a package built into
/// the local repository is not taken for an official provider.
///
/// Generic over `pm` so tests can use a mock. `pm` must provide
/// findInOfficialDbs, isInSyncDb, isOfficialGroup and findSyncPkgForDep,
/// as Pacman does.
fn sourceOf(pm: anytype, name: []const u8) Source {
    if (pm.findInOfficialDbs(name) != null) return .official;
    if (pm.isInSyncDb(name)) return .local_aur;
    if (pm.isOfficialGroup(name)) return .official;
    // Providers and versioned names (`sh`, `foo>=1.0`).
    if (pm.findSyncPkgForDep(name) != null) return .official;
    return .neither;
}

/// The local AUR repository's name, or "" if PKGDEST is unset or no
/// pacman.conf repository serves it. Caller owns the result.
fn localRepoName(allocator: Allocator) ![]const u8 {
    const conf = core.makepkg.parseMakepkgConf(allocator) catch return allocator.dupe(u8, "");
    defer conf.deinit(allocator);
    const pkgdest = conf.pkgdest orelse return allocator.dupe(u8, "");
    const name = core.repo_conf.deriveRepoNameFromPacmanConf(allocator, pkgdest) catch null;
    return name orelse allocator.dupe(u8, "");
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

const MockPackage = struct {
    name: []const u8,
    provides: []const []const u8 = &.{},
};

/// The four Pacman lookups over in-memory databases. `official` stands for
/// every sync database but the local AUR repository.
const MockPacman = struct {
    official: []const MockPackage = &.{},
    local_repo: []const []const u8 = &.{},
    groups: []const []const u8 = &.{},

    fn findInOfficialDbs(self: MockPacman, name: []const u8) ?MockPackage {
        for (self.official) |pkg| {
            if (std.mem.eql(u8, pkg.name, name)) return pkg;
        }
        return null;
    }

    fn isInSyncDb(self: MockPacman, name: []const u8) bool {
        if (self.findInOfficialDbs(name) != null) return true;
        return contains(self.local_repo, name);
    }

    fn isOfficialGroup(self: MockPacman, name: []const u8) bool {
        return contains(self.groups, name);
    }

    /// Matches a name or a provide; any version constraint is ignored.
    fn findSyncPkgForDep(self: MockPacman, dep: []const u8) ?MockPackage {
        const end = std.mem.indexOfAny(u8, dep, "<>=") orelse dep.len;
        const name = dep[0..end];
        for (self.official) |pkg| {
            if (std.mem.eql(u8, pkg.name, name) or contains(pkg.provides, name)) return pkg;
        }
        return null;
    }

    fn contains(names: []const []const u8, name: []const u8) bool {
        for (names) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }
};

const mock: MockPacman = .{
    .official = &.{
        .{ .name = "bash", .provides = &.{"sh"} },
        .{ .name = "nodejs", .provides = &.{"nodejs-lts"} },
    },
    .local_repo = &.{ "yay", "nodejs-lts", "base-devel" },
    .groups = &.{ "gnome", "base-devel" },
};

test "official package name is official" {
    try testing.expectEqual(Source.official, sourceOf(mock, "bash"));
}

test "local repository package is local_aur" {
    try testing.expectEqual(Source.local_aur, sourceOf(mock, "yay"));
}

test "official group is official" {
    try testing.expectEqual(Source.official, sourceOf(mock, "gnome"));
}

test "official provider is official" {
    try testing.expectEqual(Source.official, sourceOf(mock, "sh"));
}

test "versioned name is official when an official package satisfies it" {
    try testing.expectEqual(Source.official, sourceOf(mock, "bash>=5.0"));
}

test "unknown name is neither" {
    try testing.expectEqual(Source.neither, sourceOf(mock, "paru"));
}

test "local repository package wins over an official provider of the same name" {
    try testing.expectEqual(Source.local_aur, sourceOf(mock, "nodejs-lts"));
}

test "local repository package wins over an official group of the same name" {
    try testing.expectEqual(Source.local_aur, sourceOf(mock, "base-devel"));
}
