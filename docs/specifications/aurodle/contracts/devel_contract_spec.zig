// Contract specification for devel.zig — VCS Package Version Checking
//
// Verifies the formal contract for VCS package detection and upstream
// version checking via makepkg --nobuild + --printsrcinfo.
//
// Architecture: docs/architecture/class_commands.md
// Module: devel
//
// Tests use direct function calls (pure functions) and mock process execution.

const std = @import("std");
const testing = std.testing;

// TODO: Replace with real import when implementation exists
// const devel = @import("../../../../src/devel.zig");

// ============================================================================
// isVcsPackage() Contracts
// ============================================================================

test "isVcsPackage returns true for -git suffix" {
    // Contract: isVcsPackage("foo-git") returns true.
    // The -git suffix indicates a package tracking a Git repository.
    //
    // try testing.expect(devel.isVcsPackage("neovim-git"));
}

test "isVcsPackage returns true for -svn suffix" {
    // Contract: isVcsPackage("foo-svn") returns true.
    // The -svn suffix indicates a Subversion-tracked package.
    //
    // try testing.expect(devel.isVcsPackage("wine-svn"));
}

test "isVcsPackage returns true for -hg suffix" {
    // Contract: isVcsPackage("foo-hg") returns true.
    // The -hg suffix indicates a Mercurial-tracked package.
    //
    // try testing.expect(devel.isVcsPackage("mercurial-tool-hg"));
}

test "isVcsPackage returns true for -bzr suffix" {
    // Contract: isVcsPackage("foo-bzr") returns true.
    // The -bzr suffix indicates a Bazaar-tracked package.
    //
    // try testing.expect(devel.isVcsPackage("launchpad-client-bzr"));
}

test "isVcsPackage returns false for non-VCS packages" {
    // Contract: Packages without a VCS suffix return false, even if
    // the name contains VCS-related substrings like "git" or "svn".
    //
    // try testing.expect(!devel.isVcsPackage("git"));
    // try testing.expect(!devel.isVcsPackage("git-lfs"));
    // try testing.expect(!devel.isVcsPackage("python-pygit2"));
    // try testing.expect(!devel.isVcsPackage("neovim"));
}

// ============================================================================
// parseSrcinfoVersion() Contracts
// ============================================================================

test "parseSrcinfoVersion returns pkgver-pkgrel for standard SRCINFO" {
    // Contract: Given SRCINFO content with pkgver and pkgrel fields,
    // returns the combined version string "pkgver-pkgrel".
    //
    // const srcinfo = "pkgbase = foo-git\n\tpkgver = 1.0.r5.gabc\n\tpkgrel = 1\npkgname = foo-git\n";
    // const version = try devel.parseSrcinfoVersion(testing.allocator, srcinfo);
    // defer testing.allocator.free(version);
    // try testing.expectEqualStrings("1.0.r5.gabc-1", version);
}

test "parseSrcinfoVersion includes epoch when present" {
    // Contract: When SRCINFO contains an epoch field, the version
    // string is "epoch:pkgver-pkgrel".
    //
    // const srcinfo = "pkgbase = mesa-git\n\tepoch = 2\n\tpkgver = 24.1.0\n\tpkgrel = 1\npkgname = mesa-git\n";
    // const version = try devel.parseSrcinfoVersion(testing.allocator, srcinfo);
    // defer testing.allocator.free(version);
    // try testing.expectEqualStrings("2:24.1.0-1", version);
}

test "parseSrcinfoVersion fails on missing pkgver" {
    // Contract: If SRCINFO lacks a pkgver field, returns error.SrcinfoParseFailed.
    //
    // const srcinfo = "pkgbase = broken\n\tpkgrel = 1\npkgname = broken\n";
    // try testing.expectError(error.SrcinfoParseFailed, devel.parseSrcinfoVersion(testing.allocator, srcinfo));
}

test "parseSrcinfoVersion fails on missing pkgrel" {
    // Contract: If SRCINFO lacks a pkgrel field, returns error.SrcinfoParseFailed.
    //
    // const srcinfo = "pkgbase = broken\n\tpkgver = 1.0\npkgname = broken\n";
    // try testing.expectError(error.SrcinfoParseFailed, devel.parseSrcinfoVersion(testing.allocator, srcinfo));
}

test "parseSrcinfoVersion reads only pkgbase section" {
    // Contract: Only fields from the pkgbase section (before the first
    // pkgname line) are read. Per-package overrides in pkgname sections
    // are ignored. This matters for split packages.
    //
    // const srcinfo = "pkgbase = split\n\tpkgver = 1.0\n\tpkgrel = 2\npkgname = split\n\tpkgver = 9.9\n";
    // const version = try devel.parseSrcinfoVersion(testing.allocator, srcinfo);
    // defer testing.allocator.free(version);
    // try testing.expectEqualStrings("1.0-2", version);
}

// ============================================================================
// checkVersion() Contracts
// ============================================================================

test "checkVersion clones or updates the AUR repository" {
    // Contract: checkVersion() calls git.cloneOrUpdate() to ensure
    // the package source is present and up to date before checking
    // the VCS version.
}

test "checkVersion runs makepkg --nobuild to execute pkgver()" {
    // Contract: After clone/update, checkVersion() runs
    // `makepkg --nobuild --noconfirm --noextract` in the clone directory.
    // This executes pkgver() without re-extracting already-present sources.
    // If that fails (e.g. sources not yet extracted), it retries with
    // `makepkg --nobuild --noconfirm` (without --noextract) to allow
    // full source preparation.
}

test "checkVersion runs makepkg --printsrcinfo to extract version" {
    // Contract: After --nobuild, checkVersion() runs
    // `makepkg --printsrcinfo` to generate SRCINFO with the
    // updated version from pkgver().
}

test "checkVersion returns null on clone failure" {
    // Contract: If git.cloneOrUpdate() fails, checkVersion()
    // returns null rather than propagating the error. This allows
    // the caller to skip individual VCS packages gracefully.
}

test "checkVersion returns null on printsrcinfo failure" {
    // Contract: If makepkg --printsrcinfo exits non-zero,
    // checkVersion() returns null. The package is silently skipped.
}

test "checkVersion returns VcsVersionResult with full version string" {
    // Contract: On success, checkVersion() returns a VcsVersionResult
    // containing the full version string (epoch:pkgver-pkgrel).
    // The caller is responsible for calling deinit() to free memory.
}
