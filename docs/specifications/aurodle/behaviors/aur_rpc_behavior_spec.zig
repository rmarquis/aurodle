// Behavior specification for AUR RPC Integration
//
// Derived from acceptance criteria in requirements.
//
// Requirements: docs/requirements/aurodle-aur-helper.md
// Traces: FR-1 (AUR RPC Integration)

const std = @import("std");
const testing = std.testing;

// TODO: Replace with real imports when implementation exists
// const aur = @import("../../../../src/aur.zig");

// ============================================================================
// FR-1: AUR RPC Integration
// ============================================================================

// --- FR-1 AC: Fetch package info via the AUR RPC info endpoint ---

test "given a valid package name when fetching info then returns complete metadata" {
    // Given: A package "yay" exists in AUR
    // When: info("yay") is called
    // Then: Returns Package with all metadata fields populated:
    //       name, pkgbase, version, description, depends, makedepends,
    //       checkdepends, optdepends, provides, conflicts, maintainer,
    //       votes, popularity, last_modified, url, licenses
}

test "given multiple package names when using multi-info then returns all in one request" {
    // Given: Packages "yay", "paru", "aurutils" exist in AUR
    // When: multiInfo(["yay", "paru", "aurutils"]) is called
    // Then: Returns all three Package structs from a single HTTP request
    //       to the AUR multi-info endpoint
}

// --- FR-1 AC: Search packages via AUR RPC search endpoint ---

test "given a search query when searching by name-desc then returns matching packages" {
    // Given: Multiple packages match the query "terminal"
    // When: search("terminal", .name_desc) is called
    // Then: Returns a non-empty slice of matching Package structs
}

// --- FR-1 AC: Parse JSON responses including PackageBase field ---

test "given an AUR info response when parsed then pkgbase field is populated" {
    // Given: AUR returns JSON with PackageBase field (may differ from Name)
    // When: The response is parsed into a Package struct
    // Then: Package.pkgbase is set to the PackageBase value from JSON
    //       Package.name is set to the Name value
    //       These may differ for split packages
}

test "given a split package when fetching info then pkgbase differs from name" {
    // Given: "lib32-mesa" has pkgbase "mesa" in AUR
    // When: info("lib32-mesa") is called
    // Then: Package.name == "lib32-mesa"
    //       Package.pkgbase == "mesa"
    //       This distinction is critical for git clone URLs
}

// --- FR-1 AC: Resolve pkgname to pkgbase ---

test "given a pkgname when fetching info then pkgbase is available for clone URL" {
    // Given: Any AUR package
    // When: info(pkgname) returns a Package
    // Then: Package.pkgbase can be used to construct
    //       "https://aur.archlinux.org/{pkgbase}.git"
}

// --- FR-1 AC: Handle API errors with clear error messages ---

test "given a network timeout when querying AUR then returns clear error" {
    // Given: AUR API is unreachable (network timeout)
    // When: Any AUR operation is attempted
    // Then: Returns error.NetworkError (not a generic failure)
    //       Error message includes "AUR API" context
}

test "given a rate limit response when querying AUR then fails fast" {
    // Given: AUR returns HTTP 429 (rate limited)
    // When: Any AUR operation is attempted
    // Then: Returns error.RateLimited immediately
    //       No automatic retry or backoff (design decision #5)
    //       Error advises user to wait and retry
}

test "given a malformed JSON response when parsing then returns clear error" {
    // Given: AUR returns invalid JSON or missing required fields
    // When: The response is parsed
    // Then: Returns error.MalformedResponse
    //       Not a generic JSON parse error
}

// --- FR-1 AC: Use Zig std.http client ---

test "given any AUR operation when HTTP is needed then uses std.http.Client" {
    // Given: Any AUR RPC call
    // When: HTTP transport is needed
    // Then: Uses Zig std.http.Client (not libcurl, not external HTTP library)
    //       Per NFR-6: no external Zig dependencies beyond std and libalpm
}
