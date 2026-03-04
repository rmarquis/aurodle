// Behavior specification for Package Building
//
// Derived from acceptance criteria in requirements.
//
// Requirements: docs/requirements/aurodle-aur-helper.md
// Traces: FR-9 (Package Building)

const std = @import("std");
const testing = std.testing;

// ============================================================================
// FR-9: Package Building — Must Have
// ============================================================================

test "given aurodle build <packages> when packages specified then builds via makepkg" {
    // Given: Package "test-pkg" is cloned at ~/.cache/aurodle/test-pkg/
    // When: `aurodle build test-pkg` is executed
    // Then: makepkg is invoked in the clone directory (pkgbase directory)
    //       Build proceeds with standard makepkg behavior
}

test "given a build when invoking makepkg then passes --syncdeps flag" {
    // Given: Package being built has dependencies
    // When: makepkg is invoked
    // Then: --syncdeps (-s) flag is passed
    //       makepkg auto-installs missing dependencies from both
    //       official repos AND local aurpkgs repo
    //       Installed dependencies are marked --asdeps
}

test "given multiple packages when building then builds in topological order" {
    // Given: Packages A (depends on B), B (no deps), both need building
    // When: `aurodle build A B` is executed
    // Then: B is built BEFORE A
    //       Build order respects dependency constraints
}

test "given successful build followed by another when building sequentially then refreshes aurpkgs db" {
    // Given: Package B was just built and added to aurpkgs repo
    //        Package A depends on B
    // When: A's build starts
    // Then: aurpkgs database was refreshed via alpm_db_update()
    //       ONLY aurpkgs is refreshed (not official repos)
    //       This allows makepkg -s to find B when building A
}

test "given a successful build when adding to repo then captures and adds all built packages" {
    // Given: makepkg completed successfully
    // When: Built packages are added to repository
    // Then: Locates built .pkg.tar.* files by resolving $PKGDEST from makepkg.conf
    //       Falls back to build directory if $PKGDEST is unset
    //       Copies packages to repository directory
    //       Runs `repo-add -R` to register in database
}

test "given a split package when building then adds all sub-packages to repository" {
    // Given: pkgbase "mesa" produces multiple packages (mesa, lib32-mesa, etc.)
    // When: Build completes successfully
    // Then: ALL .pkg.tar.* files are found and added to the repository
    //       Single repo-add call for all files
}

test "given build output when building then captures to log and displays in real-time" {
    // Given: makepkg produces build output
    // When: Build is running
    // Then: Output is displayed to terminal in real-time
    //       Output is simultaneously captured to log file
    //       Log location: ~/.cache/aurodle/logs/{pkgbase}.log
}

test "given a build failure when makepkg exits non-zero then reports with log path" {
    // Given: makepkg build fails
    // When: Build failure is detected
    // Then: Reports the makepkg exit code
    //       Includes the log file path for debugging
    //       Error follows format: "Error: Build Failure: makepkg returned exit code N"
}

// ============================================================================
// FR-9: Package Building — Should Have
// ============================================================================

test "given --needed flag when building then skips up-to-date packages" {
    // Given: Package "pkg" version 1.0 is already in the repository
    //        AUR version is also 1.0
    // When: `aurodle build --needed pkg` is executed
    // Then: Build is skipped for "pkg"
    //       Reports "pkg is up to date -- skipping"
}

test "given --rebuild flag when building then forces rebuild regardless" {
    // Given: Package "pkg" version 1.0 is already in the repository
    // When: `aurodle build --rebuild pkg` is executed
    // Then: Package is rebuilt even though it's up-to-date
}
