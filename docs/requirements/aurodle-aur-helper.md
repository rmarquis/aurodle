# Aurodle AUR Helper - Requirements Document

## Overview

Aurodle is a minimalist AUR helper written in Zig that builds AUR packages into a local pacman repository. It combines the build-order visualization of auracle, the local repository architecture of aurutils, and the minimal-interaction philosophy of pacaur into a single unified tool.

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
- Fetch package info via the AUR RPC `info` endpoint (single and multi-info)
- Search packages via the AUR RPC `search` endpoint by name-desc
- Parse JSON responses into internal package metadata structures
- Handle API errors (timeouts, malformed responses, rate limits) with clear error messages
- Use Zig `std.http` client for all HTTP transport

**Priority**: Must Have

---

### FR-2: Package Info Display

**Description**: Display detailed metadata for one or more AUR packages.

**Acceptance Criteria**:
- `aurodle info <packages...>` fetches and displays package metadata
- Shows: name, version, description, URL, licenses, maintainer, submitter
- Shows: depends, makedepends, checkdepends, optdepends
- Shows: votes, popularity, last modified date, out-of-date status
- Exits with code 1 if any requested package is not found
- *[Should Have]* `--raw` flag outputs raw JSON from AUR RPC
- *[Nice to Have]* `--format <string>` supports custom output with field placeholders (`{name}`, `{version}`, `{depends:,}`, `{modified:%Y-%m-%d}`)

**Priority**: Must Have (core), Should Have (--raw), Nice to Have (--format)

---

### FR-3: Package Search

**Description**: Search AUR packages and display results.

**Acceptance Criteria**:
- `aurodle search <terms...>` queries AUR and displays matching packages
- Default output shows: name, version, description, popularity
- Results displayed in a readable columnar or list format
- Returns exit code 0 with no output if no results found
- *[Should Have]* `--by <field>` searches by specific field (name, name-desc, maintainer, depends, makedepends, optdepends, checkdepends)
- *[Should Have]* `--sort <field>` / `--rsort <field>` sorts by name, votes, popularity, firstsubmitted, lastmodified (default: popularity descending)
- *[Should Have]* `--raw` outputs raw JSON
- *[Nice to Have]* `--literal` disables regex matching
- *[Nice to Have]* `--format <string>` for custom output formatting

**Priority**: Must Have (basic search), Should Have (sort/filter/raw), Nice to Have (literal/format)

---

### FR-4: Libalpm Database Integration

**Description**: Query local and sync databases via direct libalpm C FFI to determine installed packages, repository contents, and version satisfaction.

**Acceptance Criteria**:
- Initialize libalpm handle and register sync databases from pacman.conf
- Query installed package database for package presence and version
- Query sync databases for official repository packages
- Compare package versions using `alpm_pkg_vercmp()`
- Determine if installed packages satisfy versioned dependency constraints (`>=`, `<=`, `=`, `>`, `<`)
- *[Should Have]* Query provider information (packages that `provide` virtual dependencies)
- *[Should Have]* Query conflict information between packages

**Priority**: Must Have (queries, version compare), Should Have (providers, conflicts)

---

### FR-5: Dependency Resolution

**Description**: Resolve the complete dependency tree for target packages, classifying each dependency by source.

**Acceptance Criteria**:
- For each target package, recursively discover all `depends` and `makedepends`
- Classify each dependency as: AUR (must build), REPOS (install via pacman), SATISFIED (already installed), or UNKNOWN (not found)
- Check installed packages first, then official repos, then AUR
- Fail fast with clear error message when a dependency cannot be resolved
- Handle versioned dependencies (`package>=1.0.0`, `package=2.0.0`)
- *[Should Have]* Resolve `checkdepends`
- *[Should Have]* Handle `provides` for virtual dependency resolution
- *[Should Have]* Batch AUR RPC requests using multi-info endpoint
- *[Should Have]* Detect and report circular dependencies
- *[Should Have]* Detect and report package conflicts

**Priority**: Must Have (basic resolution), Should Have (advanced resolution)

---

### FR-6: Build Order Generation

**Description**: Compute and display the topological build order for a set of packages.

**Acceptance Criteria**:
- `aurodle buildorder <packages...>` displays ordered build sequence
- Uses topological sort to order packages respecting dependency constraints
- Output includes dependency classification (AUR, REPOS, UNKNOWN) per entry
- Marks already-satisfied dependencies with SATISFIED prefix
- Marks explicitly requested packages with TARGET prefix
- Fails with clear error if topological sort is impossible (cycle detected)
- *[Should Have]* `--quiet` shows only AUR packages that need building
- *[Nice to Have]* `--resolve-deps <deplist>` controls which dependency types are considered

**Priority**: Must Have (basic ordering), Should Have (quiet), Nice to Have (resolve-deps)

---

### FR-7: Dependency Provider Resolution

**Description**: Resolve dependency strings to packages that satisfy them.

**Acceptance Criteria**:
- `aurodle resolve <packages...>` displays which packages provide each dependency
- Shows whether provider is in AUR or official repos
- Handles versioned dependency strings
- *[Should Have]* Resolves virtual dependencies via `provides` field

**Priority**: Must Have (basic), Should Have (virtual providers)

---

### FR-8: Git Clone Management

**Description**: Clone and update AUR package git repositories to local cache.

**Acceptance Criteria**:
- `aurodle clone <packages...>` clones AUR git repos to cache directory
- Default cache location: `~/.cache/aurodle/`
- Clones from `https://aur.archlinux.org/<pkgbase>.git`
- Skips clone if directory already exists (reports as up-to-date)
- *[Should Have]* Updates existing clones via `git pull` when already cloned
- *[Should Have]* `--recurse` recursively clones dependencies
- *[Nice to Have]* `--clean` removes existing clone before re-cloning
- *[Nice to Have]* Supports `$AURDEST` environment variable for custom clone location

**Priority**: Must Have (basic clone), Should Have (update/recurse), Nice to Have (clean/AURDEST)

---

### FR-9: Package Building

**Description**: Build packages using makepkg and add built packages to the local repository.

**Acceptance Criteria**:
- `aurodle build <packages...>` builds each package via `makepkg` in clone directory
- Adds successfully built packages to local repository using `repo-add -R`
- Repository location: `~/.cache/aurodle/aurpkgs/`
- Repository database: `aurpkgs.db.tar.xz`
- Creates repository directory and database if they don't exist
- Reports build failures with makepkg exit code and log location
- `repo-add -R` automatically removes old package versions
- *[Should Have]* `--needed` skips packages already at current version in repository
- *[Should Have]* `--rebuild` forces rebuild even if up-to-date
- *[Nice to Have]* `--rmdeps` removes makedepends after successful build

**Priority**: Must Have (build + repo-add), Should Have (needed/rebuild), Nice to Have (rmdeps)

---

### FR-10: Package Sync (Full Workflow)

**Description**: Complete workflow combining clone, review, build, and install operations.

**Acceptance Criteria**:
- `aurodle sync <packages...>` executes: dependency resolution -> clone -> review -> build -> install
- Resolves full dependency tree and displays build order before proceeding
- Clones all AUR packages in dependency chain
- Displays build files (PKGBUILD) for user review before building
- Prompts for single confirmation before beginning build phase
- Builds packages in dependency order
- Adds all built packages to local repository
- Installs packages via `pacman -S` from local repository
- *[Should Have]* `--asdeps` / `--asexplicit` flags passed to pacman
- *[Should Have]* `--needed` / `--rebuild` flags for build control
- *[Nice to Have]* `--noconfirm` skips confirmation (preserves file review)
- *[Nice to Have]* `--noshow` skips build file display entirely
- *[Nice to Have]* `--ignore <packages>` excludes specific packages

**Priority**: Must Have (full workflow), Should Have (install flags), Nice to Have (noconfirm/noshow/ignore)

---

### FR-11: Package Show/Review

**Description**: Display package build files for security review.

**Acceptance Criteria**:
- `aurodle show <package>` displays PKGBUILD content from cloned repository
- Requires package to be cloned first; errors if not found
- *[Should Have]* Syntax highlighting for PKGBUILD display
- *[Should Have]* Lists all files in clone directory (patches, .install, etc.)
- *[Nice to Have]* `--file <filename>` shows specific file from clone
- *[Nice to Have]* `--diff` shows changes since last version (requires git history)

**Priority**: Should Have

---

### FR-12: Outdated Package Detection

**Description**: Compare installed AUR packages against current AUR versions.

**Acceptance Criteria**:
- `aurodle outdated` lists installed packages with newer AUR versions available
- Identifies AUR packages by checking which installed packages are not in any sync database
- Compares installed version against AUR version using `alpm_pkg_vercmp()`
- Displays: package name, installed version, AUR version
- *[Should Have]* `--quiet` shows only package names
- *[Should Have]* Filterable by specific packages

**Priority**: Should Have

---

### FR-13: Package Upgrade

**Description**: Upgrade outdated AUR packages through the full build workflow.

**Acceptance Criteria**:
- `aurodle upgrade [packages...]` upgrades outdated AUR packages
- With no arguments, upgrades all outdated AUR packages
- With arguments, upgrades only specified packages
- Executes: outdated check -> clone/update -> review -> build -> install
- Displays summary of packages to upgrade before proceeding
- *[Should Have]* `--needed` skips up-to-date packages
- *[Should Have]* `--rebuild` forces rebuild of all specified packages
- *[Should Have]* `--devel` includes -git/-svn/-hg development packages
- *[Nice to Have]* `--noconfirm` / `--noshow` / `--ignore` flags
- *[Nice to Have]* Shows diff of PKGBUILD changes for updated packages

**Priority**: Should Have

---

### FR-14: Local Repository Management

**Description**: Maintain the local pacman repository database and package files.

**Acceptance Criteria**:
- Repository at `~/.cache/aurodle/aurpkgs/` with database `aurpkgs.db.tar.xz`
- Repository database updated automatically after each successful build via `repo-add -R`
- Old package versions removed automatically by `repo-add -R`
- Repository is a valid pacman custom repository (usable with `[aurpkgs]` section in pacman.conf)
- *[Should Have]* Instruct user on required pacman.conf configuration if not present
- *[Should Have]* Validate repository integrity on startup

**Priority**: Must Have

---

### FR-15: Global CLI Options

**Description**: Provide consistent global options across all commands.

**Acceptance Criteria**:
- `-h, --help` displays help for the tool or specific command
- `-v, --version` displays version information
- Unknown commands or flags produce clear usage errors (exit code 2)
- *[Should Have]* `-q, --quiet` reduces output verbosity across all commands

**Priority**: Must Have (help/version), Should Have (quiet)

---

### FR-16: Privilege Escalation for Pacman Operations

**Description**: Elevate privileges when running pacman install/sync operations.

**Acceptance Criteria**:
- Detect whether the current user has sufficient privileges for pacman operations
- Use `sudo` by default for privilege escalation
- *[Should Have]* Support `run0` (systemd) as an alternative to sudo
- Never run makepkg as root (fail fast if detected)
- Do not implement sudo timeout prevention loops

**Priority**: Should Have

---

### FR-17: Pacman Configuration Integration

**Description**: Read and respect relevant pacman.conf settings.

**Acceptance Criteria**:
- *[Should Have]* Respect `Color` setting for colored output
- *[Should Have]* Respect `VerbosePkgLists` for detailed package info display
- *[Should Have]* Read pacman.conf to discover registered repositories and mirrors
- *[Nice to Have]* Respect `IgnorePkg` during upgrade operations

**Priority**: Should Have (Color, VerbosePkgLists, repos), Nice to Have (IgnorePkg)

## Non-Functional Requirements

### NFR-1: Performance

- **Search operations**: Complete and display results within 2 seconds for typical queries (excluding network latency)
- **Info commands**: Display results within 1 second for cached packages
- **Dependency resolution**: Complete within 5 seconds for dependency trees of up to 50 packages
- **Build operations**: Overhead from aurodle (excluding makepkg execution time) should be under 1 second per package
- **Memory usage**: Stay under 50 MB RSS for typical operations (search, info, buildorder with < 100 packages)
- **Initial implementation is sequential**; parallelism (concurrent HTTP requests, parallel builds) is a future optimization

### NFR-2: Reliability

- **Atomic repository updates**: Repository database is only modified after a successful `repo-add` operation; partial writes must not corrupt the database
- **Build isolation**: A failed build for one package must not prevent building remaining packages in the queue
- **Clean failure state**: Failed operations must not leave the repository, cache, or clone directories in an inconsistent state
- **Lock file management**: Prevent concurrent aurodle instances from corrupting shared state (repository database, clone directories)

### NFR-3: Security

- **No PKGBUILD parsing or execution**: Dependency resolution uses only AUR RPC metadata, never parses or executes PKGBUILD shell code
- **Review-by-default**: Build file display is mandatory before building unless explicitly skipped with `--noshow`
- **No automated security heuristics**: No static analysis or malware detection; user is responsible for review
- **No root builds**: Refuse to run makepkg as root; fail immediately with clear error

### NFR-4: Usability

- **Consistent error format**: All errors follow the structure: `Error: <Category>: <Specific Issue>` with context and solution
- **Exit codes**: 0 = success, 1 = operational error, 2 = usage/configuration error
- **Colored output**: When enabled (via pacman.conf or terminal detection), use color to distinguish error levels and package sources
- **Upfront prompting**: All user decisions collected before execution begins; no mid-operation prompts

### NFR-5: Compatibility

- **Target platform**: Arch Linux with latest stable pacman/libalpm
- **Zig version**: Target current stable Zig release
- **libalpm**: Link directly via Zig C FFI against system libalpm.so
- **HTTP transport**: Zig `std.http` client for all AUR RPC communication
- **Git**: Requires `git` in PATH for clone operations
- **makepkg**: Requires `makepkg` in PATH for build operations

### NFR-6: Maintainability

- **Modular architecture**: Separate modules for AUR RPC, libalpm integration, dependency resolution, build management, CLI parsing, and repository management
- **No external Zig dependencies beyond std and libalpm C headers**: Minimize third-party dependency surface
- **Structured logging**: All log output uses consistent, parseable format

## Constraints

### Technical Constraints

- **Language**: Zig (leveraging C interop for libalpm)
- **Platform**: Linux only (Arch Linux and derivatives)
- **libalpm dependency**: Runtime dependency on `libalpm.so` (provided by pacman package)
- **No network caching in v1**: Initial implementation does not cache AUR API responses across invocations
- **Sequential execution**: Initial implementation processes operations sequentially; parallelism deferred to future releases
- **AUR RPC v5**: Target current AUR RPC API version

### Design Constraints

- **No GUI**: Command-line interface only
- **No interactive menus**: No TUI selection menus; fail on ambiguity rather than prompt
- **No configuration file in v1**: Hardcoded defaults only; configuration file system is a Nice to Have
- **No foreign package installation**: All packages installed through pacman via local repository
- **Pacman handles removal**: No `aurodle remove` command; users use `pacman -R` directly

### Repository Constraints

- **Fixed repository name**: `aurpkgs` (hardcoded)
- **Fixed repository location**: `~/.cache/aurodle/aurpkgs/`
- **Fixed cache directory**: `~/.cache/aurodle/`
- **Database format**: `aurpkgs.db.tar.xz` (standard repo-add output)

## Assumptions

- User has a working Arch Linux installation with pacman, makepkg, and git available
- User has internet access to reach `aur.archlinux.org`
- User has configured `[aurpkgs]` repository section in `/etc/pacman.conf` pointing to `~/.cache/aurodle/aurpkgs/`
- User understands the security implications of building AUR packages
- System libalpm.so version matches the latest stable pacman release
- Zig compiler and build tools are available for compilation

## Test Strategy

### Unit Tests

**Coverage Target**: 80% line coverage for core logic modules.

**Required unit test areas**:
- **Version comparison**: Test `alpm_pkg_vercmp()` wrapper with edge cases (epoch, pkgrel, alpha/beta versions)
- **Dependency parsing**: Parse versioned dependency strings (`pkg>=1.0`, `pkg=2.0.0-1`, `pkg<3`)
- **Topological sort**: Correct ordering, cycle detection, multiple valid orderings
- **AUR RPC response parsing**: Valid responses, malformed JSON, empty results, error responses
- **Dependency classification**: Correct REPOS/AUR/SATISFIED/UNKNOWN categorization
- **CLI argument parsing**: Valid commands, invalid flags, missing required arguments, help/version output
- **Format string parsing**: Field placeholders, array delimiters, date formatting (Nice to Have feature)
- **Error message formatting**: Consistent structure across all error types

### Integration Tests

**Required integration test areas**:
- **libalpm integration**: Initialize handle, query real (or mock) pacman databases, register sync databases
- **AUR RPC integration**: Real HTTP requests to AUR API (can be recorded/replayed for CI)
- **Git clone operations**: Clone a known AUR package, verify directory structure
- **Repository operations**: Build a minimal test package, `repo-add` to test repository, verify database
- **Full sync workflow**: End-to-end test of resolve -> clone -> build -> repo-add (using a trivial test PKGBUILD)

### Test Infrastructure

- **Zig built-in test runner**: Use `zig test` for all unit tests
- **Mock libalpm**: Provide a mock/stub libalpm interface for unit tests that don't need real database access
- **Recorded AUR responses**: Store known AUR API responses as test fixtures for deterministic testing
- **Test PKGBUILD**: Maintain a minimal valid PKGBUILD for build integration tests
- **CI integration**: All tests runnable in CI via `zig build test`

## Open Questions

1. **pacman.conf auto-configuration**: Should aurodle offer to automatically add the `[aurpkgs]` repository section to `/etc/pacman.conf`, or should this always be a manual step documented in setup instructions?

2. **Makepkg.conf integration depth**: How deeply should aurodle respect makepkg.conf settings like `$PKGDEST`, `$SRCDEST`, `$BUILDDIR`? These could redirect built packages away from the expected repository location.

3. **Multiple architecture support**: Should aurodle handle `arch=('x86_64' 'aarch64')` or assume the host architecture only?

4. **Split packages**: How should aurodle handle pkgbases that produce multiple packages (split packages)? Should all sub-packages be added to the repository, or only the requested one?

5. **AUR RPC rate limiting**: What backoff strategy should be used if the AUR API rate-limits requests? The spec doesn't define retry behavior.

6. **Repository database signing**: Should the local repository database be signed, or is an unsigned database acceptable for a local-only repository?

## Traceability Matrix

| Requirement | Spec Section | Spec Priority |
|---|---|---|
| FR-1: AUR RPC Integration | 4 (Dependency Resolution) | Core |
| FR-2: Package Info Display | 3 (Primary Operations - Query) | Core |
| FR-3: Package Search | 3 (Primary Operations - Query) | Core |
| FR-4: Libalpm Database Integration | 4 (Dependency Resolution) | Core |
| FR-5: Dependency Resolution | 4 (Dependency Resolution) | Core + Standard |
| FR-6: Build Order Generation | 3 (Dependency Analysis) | Core + Standard |
| FR-7: Dependency Provider Resolution | 3 (Dependency Analysis) | Core + Standard |
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
