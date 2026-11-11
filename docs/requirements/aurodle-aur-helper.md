# Aurodle AUR Helper - Requirements Document

## Overview

Aurodle is a minimalist AUR helper written in Zig that builds AUR packages into a local pacman repository. It combines the build-order visualization of auracle, the local repository architecture of aurutils, and the minimal-interaction philosophy of pacaur into a single unified tool.

This document is a living specification: it describes aurodle's current behavior. Requirements that are not implemented are tracked in [ideas.md](../ideas.md).

**Primary Goals:**

- Build AUR packages and manage them through a local pacman repository
- Provide transparent dependency resolution with build-order visualization
- Minimize user interaction through sensible defaults and upfront prompting
- Leverage Zig's safety guarantees and C interop for direct libalpm integration

**Named after Urodela** (the salamander order), as a nod to Zig's mascot Suzie.

## Functional Requirements

### FR-1: AUR RPC Integration

**Description**: Query the AUR RPC API to retrieve package metadata for search, info, and dependency resolution operations.

**Acceptance Criteria**:
- Fetch package info via the AUR RPC v5 `info` endpoint (single and multi-info)
- Search packages via the AUR RPC v5 `search` endpoint
- Parse JSON responses into internal package metadata structures, including the `PackageBase` field for pkgbase resolution
- Resolve pkgname to pkgbase via RPC info response (pkgbase is required for git clone URLs and split package handling)
- Handle API errors (timeouts, malformed responses, rate limits) with clear error messages
- Use Zig `std.http` client for all HTTP transport

**Priority**: Must Have

---

### FR-2: Package Info Display

**Description**: Display detailed metadata for one or more AUR packages.

**Acceptance Criteria**:
- `aurodle info <packages...>` (alias `-Si`) fetches and displays package metadata
- Shows: name, version, description, URL, licenses, maintainer, submitter
- Shows: depends, makedepends, checkdepends, optdepends
- Shows: votes, popularity, last modified date, out-of-date status
- Exits with code 1 if any requested package is not found

**Priority**: Must Have

---

### FR-3: Package Search

**Description**: Search AUR packages and display results.

**Acceptance Criteria**:
- `aurodle search <terms...>` (alias `-Ss`) queries AUR and displays matching packages
- Multiple terms return the intersection of results: the first term is sent to the AUR, the remaining terms filter the results client-side
- Default output shows: name, version, votes, popularity, and description; out-of-date packages are highlighted
- Returns exit code 0 with no output if no results found
- `-q, --quiet` shows only package names
- `--by <field>` searches by a specific field: name, name-desc (default), depends, makedepends, checkdepends, optdepends, maintainer, submitter, provides, conflicts, replaces, keywords, groups, comaintainers
- `--sort <field>` / `--rsort <field>` sorts by name, votes, or popularity (default: popularity descending)

**Priority**: Must Have (basic search), Should Have (sort/filter)

---

### FR-4: Libalpm Database Integration

**Description**: Query local and sync databases via direct libalpm C FFI to determine installed packages, repository contents, and version satisfaction. Libalpm is used exclusively for **read operations**; all package installation is delegated to `pacman` CLI to ensure hooks, scriptlets, and privilege handling execute correctly.

**Acceptance Criteria**:
- Initialize libalpm handle and register sync databases from pacman.conf
- Query installed package database for package presence and version
- Query sync databases for official repository packages
- Compare package versions using `alpm_pkg_vercmp()`
- Determine if installed packages satisfy versioned dependency constraints (`>=`, `<=`, `=`, `>`, `<`)
- Never use libalpm for package installation or removal (pacman hooks and install scriptlets are handled by `pacman`, not by libalpm directly)
- Query provider information (packages that `provide` virtual dependencies)
- Query conflict and replacement information between packages

**Priority**: Must Have (queries, version compare), Should Have (providers, conflicts)

---

### FR-5: Dependency Resolution

**Description**: Resolve the complete dependency tree for target packages, classifying each dependency by source.

**Acceptance Criteria**:
- For each target package, recursively discover all `depends`, `makedepends`, and `checkdepends`
- Classify each dependency as: AUR (must build), REPOS (install via pacman), REPOAUR (already current in the local repository), SATISFIEDAUR or SATISFIEDREPOS (already installed), or UNKNOWN (not found)
- Check installed packages first, then official repos, then AUR
- Fail fast with clear error message when a dependency cannot be resolved
- Handle versioned dependencies (`package>=1.0.0`, `package=2.0.0`)
- Handle `provides` for virtual dependency resolution
- Batch AUR RPC requests using multi-info endpoint
- Detect and report circular dependencies
- Detect package conflicts and replacements (see FR-10)

**Priority**: Must Have (basic resolution), Should Have (advanced resolution)

---

### FR-6: Dependency Provider Resolution

**Description**: Resolve dependency strings to packages that satisfy them.

**Acceptance Criteria**:
- `aurodle resolve <packages...>` displays the resolved dependency tree without building anything
- Shows whether provider is in AUR or official repos
- Handles versioned dependency strings
- Resolves virtual dependencies via `provides` field

**Priority**: Must Have (basic), Should Have (virtual providers)

---

### FR-7: Build Order Generation

**Description**: Compute and display the topological build order for a set of packages. Builds on FR-6 (provider resolution) to determine what satisfies each dependency before ordering.

**Acceptance Criteria**:
- `aurodle buildorder <packages...>` prints one entry per line, intended for scripting
- Uses topological sort to order packages respecting dependency constraints
- Line format is `PREFIX pkgbase pkgname`, or `PREFIX pkgname` when the pkgbase is not known. The pkgbase is always present for AUR and TARGETAUR entries; repository entries carry only a pkgname
- Dependency prefixes: AUR, REPOS, REPOAUR, SATISFIEDAUR, SATISFIEDREPOS, UNKNOWN
- Explicitly requested packages use the TARGETAUR or TARGETREPO prefix
- Fails with clear error if topological sort is impossible (cycle detected)

**Priority**: Must Have

---

### FR-8: Git Clone Management

**Description**: Clone AUR package git repositories to local cache.

**Acceptance Criteria**:
- `aurodle clone <packages...>` clones AUR git repos to the cache directory
- Cache location: `$AURDEST` if set, otherwise `$XDG_CACHE_HOME/aurodle`, falling back to `~/.cache/aurodle`
- Resolves pkgname to pkgbase via AUR RPC before cloning (git repos are per-pkgbase, not per-pkgname)
- Clones from `https://aur.archlinux.org/<pkgbase>.git`
- Clone directory named after pkgbase
- Skips clone if directory already exists (reports as already cloned)
- `--recurse` recursively clones AUR dependencies
- Clones run in parallel

**Priority**: Must Have (basic clone), Should Have (recurse)

---

### FR-9: Package Building

**Description**: Build packages using makepkg into the local repository.

**Acceptance Criteria**:
- `aurodle build <packages...>` (alias `-Sw`) runs the sync workflow (FR-10) up to adding packages to the local repository, without installing them
- Builds each package via `makepkg -s --noconfirm` in its clone directory (pkgbase directory); `makepkg -s` installs missing dependencies (both official repo and AUR deps from local repo) and marks them with `--asdeps`
- makepkg writes built packages directly into `$PKGDEST`, which is the local repository directory (see FR-14); aurodle then adds them via `repo-add -R`
- When building multiple packages, builds in topological order (see FR-7). After each successful build, the local repository database is copied into pacman's sync directory so subsequent `makepkg -s` calls can resolve newly built AUR dependencies without a `pacman -Sy` (which would cause a partial system update)
- Build output is displayed in real time
- When a build produces multiple packages (split packages), all are added to the repository
- A failed build skips every remaining package that depends on it, but other packages still build. If makepkg is killed by a signal, the build loop stops
- Reports build failures with the makepkg exit code
- Skips packages whose built files already exist in `$PKGDEST` (checked via `makepkg --packagelist`)
- VCS packages build in two passes: `makepkg --nobuild` runs `pkgver()`, then the build is skipped if that version is already in the repository, otherwise `makepkg --noextract --holdver` builds it
- `--rebuild` forces rebuild even if up to date (`makepkg -f`)
- `--chroot` builds in a clean chroot via `makechrootpkg -c -u` (requires devtools), in `$CHROOT_DIR` (default `/var/lib/aurodle/chroot`):
  - the chroot gets its own `pacman.conf`, generated once from the host's repositories (including the local repository) and never overwritten afterwards
  - the chroot is created with `mkarchroot` on first use, and its root is upgraded once per run
  - AUR dependencies are installed from the local repository inside the chroot, so they work whether they were built in this run or earlier
  - makechrootpkg runs as the user (`-U`, `SUDO_USER`) whatever the `PACMAN_AUTH` tool, with `PKGDEST` and makepkg's environment variables passed on
  - fails with a clear error when `$CHROOT_DIR` is on a `nosuid` mount
  - nothing is installed on the host, including chosen providers

**Priority**: Must Have (build + repo-add), Should Have (rebuild), Nice to Have (chroot)

---

### FR-10: Package Sync (Full Workflow)

**Description**: Complete workflow combining resolution, clone, review, build, and install operations.

**Acceptance Criteria**:
- `aurodle sync <packages...>` (alias `-S`) executes: resolve -> conflicts -> provider selection -> display plan and confirm -> clone/fetch -> review -> build -> install
- Resolves full dependency tree and displays the build plan before proceeding
- Detected conflicts and replacements are offered for resolution one by one (remove the conflicting package, or continue anyway); declining any of them aborts
- When a repository dependency has several providers, prompts the user to choose one; choices are reused for later dependencies the same package provides
- Prompts for a single confirmation before cloning and building
- Clones or fetches all AUR packages in the dependency chain in parallel. Fetching does not apply new AUR commits until the review is done (see FR-11)
- Offers each package's build files for review (see FR-11)
- Builds packages in dependency order (see FR-9); intermediate AUR dependencies are installed by `makepkg --syncdeps` as dependencies (`--asdeps`)
- Installs only user-requested target packages, from the local repository, in a single `pacman -S` transaction (split sub-packages are in the repo but not auto-installed)
- `--asdeps` / `--asexplicit` and `--needed` are passed to pacman
- `--rebuild` forces rebuilds (see FR-9)
- `--noconfirm` skips the plan confirmation and conflict prompts, and picks the first provider when several are available; the review step still runs
- `--noshow` skips the review step entirely
- `--ignore <pkg>[,<pkg>...]` excludes packages; accepts a comma-separated list or repeated flags and is merged with `IgnorePkg` from pacman.conf

**Priority**: Must Have (full workflow), Should Have (install flags), Nice to Have (noconfirm/noshow/ignore)

---

### FR-11: Package Show/Review

**Description**: Display package build files for security review.

**Acceptance Criteria**:
- `aurodle show <package>` opens the clone directory (PKGBUILD, install scripts, patches) in the viewer
- Requires package to be cloned first; errors if not found
- Viewer is chosen from `$PAGER`, then `$VISUAL`, then `$EDITOR`, falling back to `vim`
- During sync, build, and upgrade, the review step asks per package whether to view:
  - a package cloned for the first time: all files in the viewer
  - a package with new AUR commits: `git diff` from the version last accepted, even if the commits were fetched during an earlier, interrupted run; the commits are applied once the review is done
  - a package with no AUR changes: only local changes, if any (such as the `pkgver` makepkg rewrote for a VCS package); nothing is shown otherwise

**Priority**: Should Have

---

### FR-12: Outdated Package Detection

**Description**: Compare installed AUR packages against current AUR versions.

**Acceptance Criteria**:
- `aurodle outdated [packages...]` (alias `-Qu`) lists installed packages with newer AUR versions available
- Considers foreign packages (not in any official sync database) and packages present in the local repository
- Compares installed version against AUR version using `alpm_pkg_vercmp()`
- Displays: package name, installed version, AUR version
- With arguments, checks only the given packages
- `-q, --quiet` shows only package names
- `--devel` also checks VCS packages by fetching their upstream source (see FR-13)
- Exit code 1 when packages were checked but none are outdated, like `pacman -Qu`

**Priority**: Should Have

---

### FR-13: Package Upgrade

**Description**: Upgrade outdated AUR packages through the full build workflow.

**Acceptance Criteria**:
- `aurodle upgrade [packages...]` (alias `-Su`) upgrades outdated AUR packages
- With no arguments, upgrades all outdated AUR packages (as found by FR-12)
- With arguments, upgrades only specified packages
- Runs the outdated check, then the sync workflow (FR-10) on the outdated packages, including the review diff of AUR changes
- Packages in `IgnorePkg` or `--ignore` are skipped with a warning
- `--devel` includes VCS development packages (`-git`, `-svn`, `-hg`, `-bzr` suffixes); runs `makepkg --nobuild` (in parallel across packages) to execute `pkgver()` and determine the current upstream version, then compares against the installed version and only rebuilds if the version has changed. Version checks run on the version last accepted: new AUR commits are only applied after the review
- `--needed`, `--rebuild`, `--noconfirm`, `--noshow`, `--ignore` behave as in FR-10

**Priority**: Should Have

---

### FR-14: Local Repository Management

**Description**: Maintain the local pacman repository database and package files.

**Acceptance Criteria**:
- Repository location and name as defined in Repository Constraints
- Creates the repository directory if it doesn't exist on first build
- Repository database updated automatically after each successful build via `repo-add -R` (which also removes old package versions)
- When `PKGDEST` is not set, or no pacman.conf repository matches it, fail with a clear error message including copy-pasteable configuration instructions

**Priority**: Must Have

---

### FR-15: Global CLI Options

**Description**: Provide consistent global options across all commands.

**Acceptance Criteria**:
- `-h, --help` displays help for the tool or specific command
- `-V, --version` displays version information
- Unknown commands or flags produce clear usage errors (exit code 2)
- `-q, --quiet` reduces output verbosity
- Pacman-style aliases for the main commands: `-S` (sync), `-Sw` (build), `-Su` (upgrade), `-Ss` (search), `-Si` (info), `-Qu` (outdated), `-Sc` (clean), `-Scc` (clean --all)

**Priority**: Must Have (help/version), Should Have (quiet, aliases)

---

### FR-16: Privilege Escalation for Pacman Operations

**Description**: Elevate privileges when running pacman install/sync operations.

**Acceptance Criteria**:
- Use the `PACMAN_AUTH` command from the environment or makepkg.conf, following makepkg's semantics: the command is prefixed, or `%c` is substituted with the command to run
- Supports sudo, run0, doas, su, and compatible tools; defaults to sudo, falling back to su
- Credentials are acquired only after the user confirms the plan and finishes the review
- Keeps the credential session alive during builds, so long builds don't hit an authentication prompt or failure midway
- Never run makepkg as root (makepkg itself refuses)

**Priority**: Should Have

---

### FR-17: Pacman Configuration Integration

**Description**: Read and respect relevant pacman.conf settings.

**Acceptance Criteria**:
- Respect `Color` setting for colored output
- Respect `VerbosePkgLists` for detailed package info display
- Read pacman.conf to discover registered repositories and the local repository (see FR-14)
- Respect `IgnorePkg` during sync and upgrade operations

**Priority**: Should Have

---

### FR-18: Cache Cleanup

**Description**: Remove stale clone directories, built packages, and database entries.

**Acceptance Criteria**:
- `aurodle clean` (alias `-Sc`) removes built packages and clones of packages no longer installed, old package files the repository database no longer references, and database entries of uninstalled packages whose file is missing
- `aurodle clean --all` (alias `-Scc`) removes all built packages and clone directories
- Displays what will be removed and prompts for confirmation before deleting (the `--all` prompt defaults to no); `--noconfirm` skips the prompt

**Priority**: Should Have

---

### FR-19: Infrastructure Status

**Description**: Report the health of Arch Linux infrastructure.

**Acceptance Criteria**:
- `aurodle status` fetches the monitor list from status.archlinux.org
- Shows an overall status, each monitor's state, its daily uptime over the last 30 days, and its 90-day uptime ratio

**Priority**: Nice to Have

## Non-Functional Requirements

### NFR-1: Performance

- **Search operations**: Complete and display results within 2 seconds for typical queries (excluding network latency)
- **Dependency resolution**: Complete within 5 seconds for dependency trees of up to 50 packages
- **Build operations**: Overhead from aurodle (excluding makepkg execution time) should be under 1 second per package
- **Memory usage**: Stay under 50 MB RSS for typical operations (search, info, buildorder with < 100 packages)
- **Parallelism**: Clones, fetches, and `--devel` version checks run in parallel (up to 8 jobs); builds run sequentially

### NFR-2: Reliability

- **Atomic repository updates**: Repository database is only modified through `repo-add` and `repo-remove`
- **Build isolation**: A failed build for one package must not prevent building remaining packages that don't depend on it
- **Interrupted review**: An interrupted run leaves clones at the version last accepted, so the next run shows the same diff

### NFR-3: Security

- **No PKGBUILD parsing or execution**: Dependency resolution uses only AUR RPC metadata, never parses or executes PKGBUILD shell code
- **No config execution**: makepkg.conf is parsed, never sourced, so shell expansions are taken literally
- **Review-by-default**: The review step runs before building unless explicitly skipped with `--noshow`; `--noconfirm` does not skip it
- **No automated security heuristics**: No static analysis or malware detection; user is responsible for review
- **No root builds**: makepkg is never run as root

### NFR-4: Usability

- **Error format**: pacman-style `error:` and `warning:` prefixes
- **Exit codes**: 0 = success, 1 = operational error, 2 = usage/configuration error, 3 = build failed, 128 = a build was killed by a signal
- **Colored output**: Enabled by pacman.conf `Color` on a terminal; disabled by `NO_COLOR` or `TERM=dumb`
- **Upfront prompting**: Conflict, provider, and plan confirmation prompts all come before any clone or build; the review comes before any build. No prompts during builds

### NFR-5: Compatibility

- **Target platform**: Arch Linux with latest stable pacman/libalpm
- **Zig version**: Target current stable Zig release
- **libalpm**: Link directly via Zig C FFI against system libalpm.so
- **HTTP transport**: Zig `std.http` client for all AUR RPC communication
- **Git**: Requires `git` in PATH for clone operations
- **makepkg**: Requires `makepkg` in PATH for build operations
- **devtools**: Required only for `--chroot`

### NFR-6: Maintainability

- **Modular architecture**: Separate modules for AUR RPC, libalpm integration, dependency resolution, build management, CLI parsing, and repository management
- **No external Zig dependencies beyond std and libalpm C headers**: Minimize third-party dependency surface

## Constraints

### Technical Constraints

- **Language**: Zig (leveraging C interop for libalpm)
- **Platform**: Linux only (Arch Linux and derivatives)
- **libalpm for reads, pacman for writes**: libalpm is used for database queries and version comparison; all package installation/removal is done via `pacman` CLI to ensure pacman hooks and install scriptlets execute correctly
- **No network caching**: AUR API responses are not cached across invocations
- **AUR RPC v5**: Target current AUR RPC API version

### Design Constraints

- **No GUI**: Command-line interface only
- **No TUI**: Prompts are plain yes/no questions or numbered choices; no full-screen selection menus
- **No configuration file**: Aurodle is configured entirely through makepkg.conf, pacman.conf, and environment variables
- **No foreign package installation**: All packages installed through pacman via local repository
- **Pacman handles removal**: No `aurodle remove` command; users use `pacman -R` directly

### Repository Constraints

- **Repository location**: `$PKGDEST`, read from the environment or makepkg.conf (`/etc/makepkg.conf`, then `/etc/makepkg.conf.d/*.conf` in sorted order, then `$XDG_CONFIG_HOME/pacman/makepkg.conf` or `~/.makepkg.conf`; the last assignment wins)
- **Repository name**: Any name; detected from the pacman.conf section whose `Server = file://` URL matches `$PKGDEST`
- **Database format**: `<name>.db.tar.xz` (standard repo-add output)
- **Cache directory**: `$AURDEST`, `$XDG_CACHE_HOME/aurodle`, or `~/.cache/aurodle` (clones)

## Out of Scope

- **No AUR account integration**: No voting, flagging, commenting, or package submission. Aurodle is a build tool, not an AUR management client.
- **No rebuild detection**: No tracking of soname bumps or library changes that would require dependent packages to be rebuilt (e.g., what `rebuild-detector` provides).
- **No download-only / offline mode**: No ability to download sources without building, or to build from previously cached sources without network access.
- **No multi-repo support**: Only the single repository matching `$PKGDEST`. No support for managing multiple local repositories or routing packages to different repos.
- **No PKGBUILD modification or local patching**: PKGBUILDs are cloned from AUR and built as-is. The review step (FR-11) is for security inspection only, not for editing. Dependency resolution relies entirely on AUR RPC metadata; local PKGBUILD modifications would create inconsistencies between resolved and actual dependencies.
- **No persistent VCS version tracking**: VCS package version checking (via `makepkg --nobuild`) is done on-demand at upgrade time, not tracked in a local database. There is no persistent record of previously built VCS commit hashes.

## Assumptions

- User has a working Arch Linux installation with pacman, makepkg, and git available
- User has internet access to reach `aur.archlinux.org`
- User has set `PKGDEST` and manually configured a matching repository section in `/etc/pacman.conf` with `SigLevel = Optional TrustAll`
- User understands the security implications of building AUR packages
- User can authenticate with the `PACMAN_AUTH` tool (or accepts password prompts)
- System libalpm.so version matches the latest stable pacman release
- Zig compiler and build tools are available for compilation

## Test Strategy

### Unit Tests

**Required unit test areas**:
- **Version comparison**: Test `alpm_pkg_vercmp()` wrapper with edge cases (epoch, pkgrel, alpha/beta versions)
- **Dependency parsing**: Parse versioned dependency strings (`pkg>=1.0`, `pkg=2.0.0-1`, `pkg<3`)
- **Topological sort**: Correct ordering, cycle detection, multiple valid orderings
- **AUR RPC response parsing**: Valid responses, malformed JSON, empty results, error responses
- **Dependency classification**: Correct REPOS/AUR/REPOAUR/SATISFIED/UNKNOWN categorization
- **CLI argument parsing**: Valid commands, aliases, invalid flags, missing required arguments, help/version output
- **Configuration parsing**: makepkg.conf (`PKGDEST`, `PACMAN_AUTH`) and pacman.conf

### Integration Tests

**Required integration test areas**:
- **libalpm integration**: Initialize handle, query real (or mock) pacman databases, register sync databases
- **AUR RPC integration**: Real HTTP requests to AUR API (can be recorded/replayed for CI)
- **Git clone operations**: Clone, fetch, and apply upstream on test repositories
- **Repository operations**: Build a minimal test package, `repo-add` to test repository, verify database
- **Full sync workflow**: End-to-end test of resolve -> clone -> build -> repo-add (using a trivial test PKGBUILD)

### Test Infrastructure

- **Zig built-in test runner**: Use `zig test` for all unit tests
- **Mock libalpm**: Provide a mock/stub libalpm interface for unit tests that don't need real database access
- **Recorded AUR responses**: Store known AUR API responses as test fixtures for deterministic testing
- **Test PKGBUILD**: Maintain a minimal valid PKGBUILD for build integration tests
- **CI integration**: All tests runnable in CI via `zig build test`

## Resolved Design Decisions

1. **pacman.conf configuration**: Manual only. Aurodle will never modify `/etc/pacman.conf`. Setup instructions are documented in README and the man page. When no repository matches `$PKGDEST`, commands that need it fail with a clear error message including copy-pasteable configuration instructions.

2. **Makepkg.conf integration**: Fully respect makepkg.conf. `$PKGDEST` is the local repository directory, so makepkg writes built packages straight into the repository and no copying is needed. Aurodle reads makepkg.conf files in makepkg's order and parses them without executing them. Other variables such as `$SRCDEST` and `$BUILDDIR` are left to makepkg.

3. **Architecture support**: Host architecture only. Aurodle builds exclusively for the host architecture. No cross-compilation support. Architecture validation is delegated to makepkg, which natively checks the PKGBUILD `arch` array against the host.

4. **Split packages**: Add all sub-packages to the local repository, install only requested. When a pkgbase produces multiple `.pkg.tar` files (split packages), all are added to the local repository via `repo-add`. However, only the packages explicitly requested by the user are installed via pacman. This ensures sibling dependencies are available without installing unwanted packages.

5. **AUR RPC rate limiting**: Fail fast. If the AUR API returns a rate-limit response, aurodle immediately fails with a clear error message advising the user to wait and retry. No automatic retries or backoff. The multi-info endpoint should be used where possible to minimize request count.

6. **Repository database signing**: Unsigned. The local repository database is not signed. Users configure `SigLevel = Optional TrustAll` (or equivalent) for the local repository section in pacman.conf. This matches aurutils' default behavior and avoids GPG key management complexity.

7. **pkgbase vs pkgname**: Always resolve via AUR RPC. The pkgname-to-pkgbase mapping is obtained from the RPC info response and used throughout (clone URLs, directory names, split package grouping). See FR-1 and FR-8.

8. **Dependency installation before build**: Fully delegated to `makepkg --syncdeps`, which handles both official repo and local repo dependencies and marks them as `--asdeps`. Between builds, aurodle copies only the local repository database into pacman's sync directory to avoid partial system updates. See FR-9.

9. **makepkg invocation**: Minimal flags (`--syncdeps --noconfirm`, plus `-f` for `--rebuild` and the two-pass flags for VCS packages), no `--clean` or `--cleanbuild`. Build output is shown in real time. See FR-9.

10. **VCS/devel packages**: When `--devel` is specified, run `makepkg --nobuild` to execute `pkgver()` and compare against the installed version; only rebuild if the version has changed. This avoids unnecessary rebuilds while still using the authoritative version source. The prepared sources are reused by the build when nothing changed since. See FR-13.

11. **Cache cleanup**: `aurodle clean` for stale artifacts and `clean --all` for everything, both with a confirmation prompt. See FR-18.

12. **Credential keepalive**: Aurodle keeps the privilege escalation session alive during builds. A long build would otherwise outlast the sudo timestamp and stop at an authentication prompt or fail at install time, which goes against the upfront-prompting goal. See FR-16.

13. **Review after confirmation**: The plan is confirmed before cloning, and the review happens after fetching, so the review can show exactly what will be built. AUR commits are applied only after the review, so an interrupted run shows the same diff again. See FR-10 and FR-11.

14. **Clean chroot builds**: Follow aurutils. The chroot's own `pacman.conf` includes the local repository; arch-nspawn bind-mounts `file://` repositories read-only, so makepkg in the chroot resolves AUR dependencies itself. Injecting built packages with `makechrootpkg -I` was dropped: it could not provide dependencies of dependencies or AUR packages built in earlier runs. The configuration is generated once and left for the user to edit, as with aurutils. See FR-9.

## Traceability Matrix

| Requirement | Spec Section | Spec Priority |
|---|---|---|
| FR-1: AUR RPC Integration | 4 (Dependency Resolution) | Core |
| FR-2: Package Info Display | 3 (Primary Operations - Query) | Core |
| FR-3: Package Search | 3 (Primary Operations - Query) | Core |
| FR-4: Libalpm Database Integration | 4 (Dependency Resolution) | Core |
| FR-5: Dependency Resolution | 4 (Dependency Resolution) | Core + Standard |
| FR-6: Dependency Provider Resolution | 3 (Dependency Analysis) | Core + Standard |
| FR-7: Build Order Generation | 3 (Dependency Analysis) | Core + Standard |
| FR-8: Git Clone Management | 3 (Clone and Review) | Core + Standard |
| FR-9: Package Building | 3 (Build Operations) | Core |
| FR-10: Package Sync | 3 (Build Operations) | Core + Standard |
| FR-11: Package Show/Review | 3 (Clone and Review) | Standard |
| FR-12: Outdated Detection | 3 (Query Operations) | Standard |
| FR-13: Package Upgrade | 3 (Build Operations) | Standard |
| FR-14: Local Repository Management | 5 (Configuration - Repository) | Core |
| FR-15: Global CLI Options | 6 (CLI Interface) | Core + Standard |
| FR-16: Privilege Escalation | 5 (Privilege Escalation) | Standard |
| FR-17: Pacman Config Integration | 5 (Configuration) | Standard + Advanced |
| FR-18: Cache Cleanup | — (new) | Standard |
| FR-19: Infrastructure Status | — (new) | Advanced |
