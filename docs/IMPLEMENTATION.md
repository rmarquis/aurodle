# Implementation Plan

A phased approach to implementing the AUR helper based on the prioritized specification in SPEC.md.

## Implementation Philosophy

- **Priority-Driven Development**: Focus on 🔴 Core features first, then 🟡 Standard, then 🟢 Advanced
- **Incremental Functionality**: Each phase builds working components that can be tested independently
- **Hardcoded to Configurable**: Start with sensible hardcoded defaults, add configurability later
- **Minimal Viable Product**: Core phases provide basic but fully functional AUR helper

---

## Phase 1: Foundation and Core CLI (🔴 Core Priority)

**Goal**: Establish project foundation with basic CLI framework and hardcoded sensible defaults.

### 1.1 Project Setup

- Initialize Zig project with proper build.zig configuration
- Set up directory structure: `src/`, `tests/`, `build/`
- Configure development environment and basic tooling
- Create minimal README with build instructions

### 1.2 Core CLI Framework

- Implement argument parsing for global and command-specific options
- **Global flags**: `-h/--help`, `-v/--version` (🔴 Core)
- Basic command structure: `aurodle <command> [args]`
- Help system with command descriptions
- Version information display

### 1.3 Hardcoded Configuration (🔴 Core Implementation)

- Fixed cache directory: `~/.cache/aurodle`
- Fixed repository name: `aurpkgs`
- Fixed repository location: `~/.cache/aurodle/aurpkgs`
- Basic error handling and logging to stdout/stderr
- Exit codes: 0=success, 1=error

**Deliverable**: CLI that shows help, version, and recognizes commands

---

## Phase 2: AUR RPC Integration and Query Commands (🔴 Core Priority)

**Goal**: Implement AUR API communication and core query functionality.

### 2.1 HTTP Client and AUR RPC

- Implement HTTP client using Zig's std.http
- Basic error handling for network failures
- AUR RPC v5 endpoints: `info`, `search`
- JSON parsing for AUR responses
- Package metadata structures

### 2.2 Core Query Commands

#### 🔴 `info` Command

- Fetch package information from AUR RPC
- Display basic package metadata (name, version, description)
- Support multiple packages
- Handle package not found errors

#### 🔴 `search` Command

- Basic text search by name/description
- Display: package name, version, description, popularity
- Handle empty search results
- Basic result limiting (e.g., max 20 results)

### 2.3 Error Handling

- Network timeout and connection failures
- Invalid package names
- AUR API error responses
- Clear error messages with actionable suggestions

**Deliverable**: Working `info` and `search` commands with AUR integration

---

## Phase 3: Package Cloning and Local Repository (🔴 Core Priority)

**Goal**: Implement package cloning and local repository management.

### 3.1 Git Integration

- Git clone functionality for AUR packages
- Clone to hardcoded cache directory: `~/.cache/aurodle/`
- Basic git operations: clone, pull for updates
- Handle git errors (network, authentication, invalid repos)

#### 🔴 `clone` Command

- Clone AUR packages: `aurodle clone package1 package2`
- Create package directories in cache
- Basic progress indication
- Skip if already cloned (initially, no update logic)

### 3.2 Local Repository Infrastructure

- Create repository directory structure in `~/.cache/aurodle/aurpkgs/`
- Basic `repo-add` integration for database management
- Repository database: `aurpkgs.db.tar.xz`
- Automatic cleanup with `repo-add -R`

### 3.3 Basic Package Building

#### 🔴 `build` Command

- Integrate with makepkg for package building
- Basic dependency resolution (fail if dependencies missing)
- Add built packages to local repository
- Handle build failures with clear error messages

**Deliverable**: Package cloning and basic building with local repository

---

## Phase 4: Dependency Resolution and Build Order (🔴 Core Priority)

**Goal**: Implement basic dependency resolution and build ordering.

### 4.1 Dependency Resolution Engine

- Parse dependency strings from AUR metadata
- Basic name matching for dependencies (🔴 Core)
- Query libalpm for installed packages and official repositories
- Basic version comparison using libalpm

#### 🔴 `resolve` Command

- Resolve dependency strings to packages
- Show which packages provide dependencies
- Basic AUR vs repo classification
- Handle unresolvable dependencies

#### 🔴 `buildorder` Command

- Basic topological sorting for build sequence
- Display tabular output with AUR/REPOS/UNKNOWN classification
- Show SATISFIED and TARGET prefixes
- Basic build order validation

### 4.2 Build Order Integration

- Complete dependency analysis before building
- Clear build sequence display
- Source indicators (AUR vs repository dependencies)
- Fail fast on unresolvable dependencies

**Deliverable**: Working dependency resolution with build order calculation

---

## Phase 5: Package Installation Workflow (🔴 Core Priority)

**Goal**: Complete package installation workflow with pacman integration.

### 5.1 Installation Integration

#### 🔴 `sync` Command

- Complete workflow: clone + build + install
- Basic dependency resolution (name matching)
- Pacman integration for installation
- Local repository database updates
- Basic progress indication

### 5.2 Build Process Management

- Execute build order sequentially
- Handle build failures gracefully
- Update repository database after successful builds
- Install packages via pacman from local repository

### 5.3 Basic Error Recovery

- Clean failure states
- Repository consistency checks
- Clear error messages for build/install failures
- Atomic repository updates

**Deliverable**: Complete working AUR helper with installation capability

---

## Phase 6: Standard Features and Environment Variables (🟡 Standard Priority)

**Goal**: Add important usability features and basic configurability.

### 6.1 Environment Variable Support (🟡 Standard Implementation)

- `$AURDEST`: AUR package clone location (default: `~/.cache/aurodle`)
- `$EDITOR`: Editor for build file review
- Basic makepkg integration: `$PKGDEST`, `$SRCDEST`
- Command-line flags override environment variables

### 6.2 Enhanced Commands

#### 🟡 `outdated` Command

- Compare installed AUR packages with AUR versions
- Show packages that can be upgraded
- Basic filtering by specific packages

#### 🟡 `show` Command

- Display PKGBUILD content (basic text display)
- Required step before building for security review
- Basic file display functionality

#### 🟡 `upgrade` Command

- Check for updates in AUR vs installed versions
- Clone and review updated packages
- Install updated packages via pacman

### 6.3 Enhanced CLI Options

- 🟡 `-q/--quiet`: Minimal output
- 🟡 `--raw`: Raw JSON output for info/search
- 🟡 Various command-specific flags per SPEC.md
- 🟡 `--needed`: Skip up-to-date packages
- 🟡 `--rebuild`: Force rebuild even if up-to-date

**Deliverable**: Feature-complete AUR helper with enhanced usability

---

## Phase 7: Advanced Features (🟢 Advanced Priority)

**Goal**: Add advanced features for power users and edge cases.

### 7.1 Advanced Configuration (🟢 Advanced Implementation)

- Full configuration file system
- XDG Base Directory specification compliance
- Pacman.conf style configuration format
- System-wide and user-specific config files

### 7.2 Advanced CLI Features

- 🟢 Custom output formatting with field placeholders
- 🟢 Advanced search options (`--literal`, `--by`, `--sort`)
- 🟢 Advanced dependency resolution control (`--resolve-deps`)
- 🟢 File-specific display (`aurodle show --file filename`)

### 7.3 Advanced Dependency Resolution

- Provider resolution for virtual dependencies
- Circular dependency detection with smart suggestions
- Complex version ranges support
- Conflict detection and resolution

### 7.4 Enhanced User Experience

- Progress tracking for complex dependency trees
- Resume capability for partial failures
- Advanced error recovery mechanisms
- Comprehensive logging and debugging support

**Deliverable**: Production-ready AUR helper with advanced capabilities

---

## Phase 8: Future Enhancements (🔵 Future Priority)

**Goal**: Implement nice-to-have features for comprehensive functionality.

### 8.1 Advanced Build Features

- Clean chroot builds for reproducibility
- Package signing with GPG support
- Local patch application using .SRCINFO and git rebase
- Development package tracking with git commit hashes

### 8.2 User Experience Enhancements

- Pacman aliases (`-S`, `-Si`, `-Ss`, `-Su`, `-Sy`)
- Regex search support for complex queries
- Advanced output formatting customization
- Arch Linux news integration before upgrades
- Arch Linux service status check

### 8.3 Performance Optimizations

- Request batching and caching
- Parallel processing where beneficial
- Memory usage optimizations
- Network request optimization

**Deliverable**: Comprehensive AUR helper with all planned features

---

## Implementation Guidelines

### Development Approach

1. **Test-Driven Development**: Write tests for each component before implementation
2. **Incremental Testing**: Each phase should have working, testable functionality
3. **Error-First Design**: Implement error handling alongside happy path functionality
4. **Documentation**: Update documentation with each phase completion

### Code Quality Standards

- Follow Zig style guidelines and idioms
- Comprehensive error handling with structured error types
- Memory safety and resource management
- Clear code organization and module separation

### Testing Strategy

#### Unit Testing

- Individual function and algorithm testing
- Command-line argument parsing validation
- AUR API response parsing
- Dependency resolution logic testing

#### Integration Testing

- End-to-end command workflow testing
- AUR API integration with real/mock servers
- Local repository management testing
- Pacman integration testing

#### System Testing

- Full package installation workflows
- Multi-package dependency scenarios
- Error condition and recovery testing
- Performance testing with large dependency trees

### Release Strategy

- Alpha releases after Phase 5 (Core functionality complete)
- Beta releases after Phase 6 (Standard features complete)
- Stable releases after Phase 7 (Advanced features complete)
- Feature releases for Phase 8 enhancements

### Performance Targets

- Search operations: < 2 seconds for typical queries
- Info commands: < 1 second for single packages
- Dependency resolution: < 5 seconds for moderate complexity
- Build operations: Minimal overhead beyond makepkg

---

## Priority Implementation Summary

### Phase 1-5: 🔴 Core (Minimal Viable Product)

Essential functionality required for a working AUR helper:

- Basic CLI with help/version
- AUR package info and search
- Package cloning and building
- Basic dependency resolution
- Complete installation workflow

### Phase 6: 🟡 Standard (Enhanced Usability)

Important features that make the tool practical:

- Environment variable configuration
- Package upgrade functionality
- Enhanced CLI options
- Build file review capabilities

### Phase 7: 🟢 Advanced (Power User Features)

Nice-to-have features for enhanced experience:

- Full configuration system
- Advanced dependency resolution
- Custom output formatting
- Comprehensive error recovery

### Phase 8: 🔵 Future (Comprehensive Functionality)

Ideas for future consideration:

- Chroot builds and signing
- Regex search and aliases
- Performance optimizations
- News integration

This implementation plan ensures a working AUR helper is available early (Phase 5) while providing a clear path for progressive enhancement based on user feedback and development resources.
