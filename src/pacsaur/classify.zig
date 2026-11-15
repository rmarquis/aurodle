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

    /// An exact name wins over a group or provider, so a package built
    /// into the local repository is not taken for an official provider.
    pub fn source(self: *const Classifier, name: []const u8) Source {
        if (self.pacman.findInOfficialDbs(name) != null) return .official;
        if (self.pacman.isInSyncDb(name)) return .local_aur;
        if (self.pacman.isOfficialGroup(name)) return .official;
        // Providers and versioned names (`sh`, `foo>=1.0`).
        if (self.pacman.findSyncPkgForDep(name) != null) return .official;
        return .neither;
    }
};

/// The local AUR repository's name, or "" if PKGDEST is unset or no
/// pacman.conf repository serves it. Caller owns the result.
fn localRepoName(allocator: Allocator) ![]const u8 {
    const conf = core.makepkg.parseMakepkgConf(allocator) catch return allocator.dupe(u8, "");
    defer conf.deinit(allocator);
    const pkgdest = conf.pkgdest orelse return allocator.dupe(u8, "");
    const name = core.repo_conf.deriveRepoNameFromPacmanConf(allocator, pkgdest) catch null;
    return name orelse allocator.dupe(u8, "");
}
