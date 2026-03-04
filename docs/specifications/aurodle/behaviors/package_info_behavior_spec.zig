// Behavior specification for Package Info Display
//
// Derived from acceptance criteria in requirements.
//
// Requirements: docs/requirements/aurodle-aur-helper.md
// Traces: FR-2 (Package Info Display)

const std = @import("std");
const testing = std.testing;

// ============================================================================
// FR-2: Package Info Display — Must Have
// ============================================================================

test "given aurodle info <package> when package exists then displays all metadata" {
    // Given: Package "yay" exists in AUR with complete metadata
    // When: `aurodle info yay` is executed
    // Then: Output includes all required fields:
    //       - Name, Version, Description, URL
    //       - Licenses, Maintainer, Submitter
    //       - Depends, MakeDepends, CheckDepends, OptDepends
    //       - Votes, Popularity, Last Modified, Out-of-Date status
}

test "given aurodle info <packages...> when multiple packages then displays each" {
    // Given: Packages "yay" and "paru" exist in AUR
    // When: `aurodle info yay paru` is executed
    // Then: Metadata for both packages is displayed
    //       Each package's info is clearly separated
}

test "given aurodle info <package> when package not found then exits with code 1" {
    // Given: Package "zzz-nonexistent" does not exist in AUR
    // When: `aurodle info zzz-nonexistent` is executed
    // Then: Exit code is 1
    //       Error message clearly states package was not found
}

test "given aurodle info <packages...> when any package not found then exits with code 1" {
    // Given: "yay" exists but "zzz-fake" does not
    // When: `aurodle info yay zzz-fake` is executed
    // Then: Exit code is 1 (because at least one package was not found)
    //       "yay" info is still displayed
    //       Error for "zzz-fake" is reported
}

// ============================================================================
// FR-2: Package Info Display — Should Have
// ============================================================================

test "given aurodle info --raw <package> when package exists then outputs raw JSON" {
    // Given: Package "yay" exists in AUR
    // When: `aurodle info --raw yay` is executed
    // Then: Output is valid JSON from the AUR RPC response
    //       No formatted display, just raw JSON
}

// ============================================================================
// FR-2: Package Info Display — Nice to Have
// ============================================================================

test "given aurodle info --format '{name} {version}' then uses custom format" {
    // Given: Package "yay" version "12.0.0" exists
    // When: `aurodle info --format '{name} {version}' yay` is executed
    // Then: Output is "yay 12.0.0"
    //       Custom format string replaces field placeholders
}

test "given --format with array field and delimiter then joins with delimiter" {
    // Given: Package "yay" has depends ["pacman", "git"]
    // When: `aurodle info --format '{depends:, }' yay`
    // Then: Output is "pacman, git"
}

test "given --format with date field and strftime then formats date" {
    // Given: Package "yay" was last modified at a known timestamp
    // When: `aurodle info --format '{modified:%Y-%m-%d}' yay`
    // Then: Output is the formatted date string
}
