# Architecture

This document defines the architecture for the AUR helper, designed for pragmatic development that starts simple and grows organically based on user needs.

**Related Documents:**

- [SPEC.md](./SPEC.md) - Detailed feature specifications, CLI interface, and requirements
- [IMPLEMENTATION.md](./IMPLEMENTATION.md) - Phase-based implementation plan

## Architecture Philosophy

Aurodle is a **focused command-line tool** that prioritizes:

- **Simplicity first** - Start with the minimal viable structure
- **Organic growth** - Add complexity only when proven necessary
- **Clear responsibilities** - Each file has one clear purpose
- **Easy debugging** - Straightforward data flow and error paths
- **Fast iteration** - Quick to understand, modify, and test

## Simplified File Organization

Start with a minimal structure that can grow organically:

```
src/
├── main.zig              # Entry point, CLI parsing, command dispatch
├── commands.zig          # All command implementations in one file initially
├── aur.zig               # AUR API client and JSON parsing
├── git.zig               # Git operations for package cloning
├── repo.zig              # Local repository management
├── solver.zig            # Dependency resolution and build ordering
└── utils.zig             # Shared utilities (HTTP, process, file ops)
```

**Total: 7 files** - Simple enough to hold in your head, complex enough to be organized.

## Growth Strategy

As features are added and files grow large, split them logically:

### Phase 1 Splits (🔴 Core → 🟡 Standard)

When `commands.zig` becomes unwieldy (~500+ lines):

```
commands/
├── query.zig             # info, search, outdated
├── build.zig             # clone, show, build, sync, upgrade
└── solver.zig            # resolve, buildorder
```

When `utils.zig` becomes complex:

```
utils/
├── http.zig              # HTTP client functionality
├── process.zig           # Command execution
└── fs.zig                # File system operations
```

### Phase 2 Splits (🟡 Standard → 🟢 Advanced)

When dependency resolution becomes sophisticated:

```
solver/
├── resolver.zig          # Main resolution logic
├── graph.zig             # Dependency graph building
└── providers.zig         # Provider resolution and conflicts
```

When system integration grows:

```
system/
├── config.zig            # Configuration management
├── cache.zig             # Cache and artifact management
└── logging.zig           # Advanced error handling and recovery
```

## Core Architectural Requirements

These architectural patterns are essential for a reliable AUR helper and must be implemented from the start:

### 1. Atomic Operations (Data Integrity)

```zig
// repo.zig must implement atomic database updates
fn updateDatabase(self: *Self) !void {
    const temp_db = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.db_path});
    defer self.allocator.free(temp_db);

    // Build new database
    try utils.runCommand(&[_][]const u8{ "repo-add", temp_db, "*.pkg.tar.*" });

    // Atomic replace (prevents corruption)
    try utils.renameFile(temp_db, self.db_path);
}
```

### 2. Basic Caching (Performance)

```zig
// aur.zig needs simple caching to avoid API rate limits
pub const Client = struct {
    cache: std.StringHashMap(AurPackage), // Simple memory cache

    pub fn getPackageInfo(self: *Self, package: []const u8) !?AurPackage {
        if (self.cache.get(package)) |cached| {
            return cached;
        }

        const info = try self.fetchFromAUR(package);
        if (info) |pkg_info| {
            try self.cache.put(package, pkg_info);
        }
        return info;
    }
};
```

### 3. Error Context Preservation (Debugging)

```zig
// utils.zig must preserve error context for troubleshooting
pub const BuildError = struct {
    operation: []const u8,
    package: []const u8,
    details: []const u8,
    log_path: ?[]const u8,

    pub fn format(self: Self) ![]u8 {
        return try std.fmt.allocPrint(allocator,
            "Error: {s}\n  Package: {s}\n  Details: {s}\n  Log: {s}",
            .{ self.operation, self.package, self.details, self.log_path orelse "none" });
    }
};
```

### 4. Build Log Preservation (Essential for Debugging)

```zig
// commands.zig must preserve build logs
fn buildPackage(allocator: std.mem.Allocator, pkg: []const u8) !void {
    const log_path = try std.fmt.allocPrint(allocator, "/tmp/aurodle-build-{s}.log", .{pkg});
    const result = try utils.runCommandWithLog(&[_][]const u8{ "makepkg", "-si" }, log_path);

    if (result.exit_code != 0) {
        // Preserve log for debugging
        std.debug.print("Build failed for {s}. Log saved to: {s}\n", .{ pkg, log_path });
        return BuildError{ .operation = "Build", .package = pkg,
                          .details = "makepkg failed", .log_path = log_path };
    }
}
```

### 5. Security Review Integration (Critical for Safety)

```zig
// commands.zig must integrate security review before building
fn handleSync(allocator: std.mem.Allocator, cmd: Command) !void {
    const build_order = try solver.resolve(allocator, cmd.packages);

    // Clone packages
    for (build_order) |pkg| {
        try git.clonePackage(allocator, pkg);
    }

    // Security review (unless --noshow flag)
    if (!cmd.flags.no_show) {
        for (build_order) |pkg| {
            try showPackageFiles(allocator, pkg); // Display PKGBUILD, etc.
        }

        const confirmed = try promptUser("Proceed with build? [y/N]: ");
        if (!confirmed) return;
    }

    // Build and install...
}
```

### 6. Batch Processing Framework (Performance)

```zig
// aur.zig should support batch requests to avoid API rate limits
pub fn getMultiplePackageInfo(self: *Self, packages: []const []const u8) ![]AurPackage {
    const MAX_BATCH_SIZE = 100; // AUR API limit

    var results = std.ArrayList(AurPackage).init(self.allocator);

    var i: usize = 0;
    while (i < packages.len) {
        const end = @min(i + MAX_BATCH_SIZE, packages.len);
        const batch = packages[i..end];

        const batch_results = try self.fetchBatch(batch);
        try results.appendSlice(batch_results);

        i = end;
    }

    return results.toOwnedSlice();
}
```

## Command Architecture Alignment

The architecture must support all commands specified in SPEC.md with their priority classifications:

### 🔴 Core Commands (MVP)

```zig
// commands.zig must implement these first
pub const CoreCommands = enum {
    info,        // Package information
    search,      // Search packages
    clone,       // Clone AUR packages
    build,       // Build packages
    sync,        // Full workflow
    resolve,     // Dependency resolution
    buildorder,  // Build sequence
};
```

### 🟡 Standard Commands (Post-MVP)

```zig
pub const StandardCommands = enum {
    outdated,    // Check for updates
    show,        // Display package files
    upgrade,     // Upgrade packages
};
```

### CLI Interface Implementation

- Refer to SPEC.md Section 6 for complete CLI flag specifications
- Each command implementation must support the flags defined in SPEC
- Command-line parsing in `main.zig` should validate against SPEC requirements

## Local Repository Architecture

Following SPEC.md design philosophy, the architecture centers on local repository management:

```zig
// repo.zig implements the core architectural principle
pub const LocalRepository = struct {
    // Key principle: All AUR packages become normal pacman packages
    // Location: ~/.cache/aurodle/aurpkgs
    // Database: aurpkgs.db.tar.xz maintained automatically

    pub fn addBuiltPackage(self: *Self, pkg_path: []const u8) !void {
        // 1. Copy package file to repository
        // 2. Update database atomically with repo-add -R
        // 3. Clean old versions automatically
        // Result: Package installable via normal pacman -S
    }
};
```

**Architectural Benefits**:

- Consistent package management through pacman
- Proper dependency tracking and conflict resolution
- Standard package upgrade/downgrade operations
- Integration with pacman hooks and events
- No foreign package database maintenance

## Performance Requirements

The architecture must meet performance targets specified in SPEC.md:

```zig
// Performance targets to architect for:
pub const PerformanceTargets = struct {
    const SEARCH_TARGET_MS = 2000;        // < 2 seconds for searches
    const INFO_TARGET_MS = 1000;          // < 1 second for info commands
    const DEPENDENCY_TARGET_MS = 5000;    // < 5 seconds for dep resolution
    // Build operations: minimize overhead, focus on makepkg efficiency
};
```

**Implementation Strategy:**

- Phase 1: Simple sequential operations (acceptable for MVP)
- Phase 2: Add caching when performance issues reported
- Phase 3: Add batching and concurrency for complex operations

## Error Handling Architecture

Must implement structured error handling per SPEC.md:

```zig
// Structured error format from SPEC
pub const Error = struct {
    category: []const u8,     // e.g., "Dependency Resolution", "Build Failure"
    issue: []const u8,        // Specific problem description
    context: ?[]const u8,     // Relevant details
    solution: ?[]const u8,    // Actionable resolution steps

    pub fn format(self: Self) []const u8 {
        return std.fmt.allocPrint(
            "Error: {s}: {s}\n  Context: {s}\n  Solution: {s}",
            .{ self.category, self.issue, self.context orelse "none", self.solution orelse "see docs" }
        );
    }
};
```

**Exit Code Standards**:

- 0: Success
- 1: Operational errors (network, build failures, etc.)
- 2: Critical errors (configuration, missing tools, etc.)

## Dependency Resolution Architecture

Critical component detailed in SPEC.md Section 4. The `solver.zig` module must implement:

### Three-Phase Resolution Process

```zig
// Implement phased approach
pub fn resolve(allocator: std.mem.Allocator, targets: []const []const u8) !ResolutionResult {
    // Phase 1: Discovery
    var graph = try buildDependencyGraph(allocator, targets);

    // Phase 2: Conflict Resolution
    try resolveConflicts(allocator, &graph);

    // Phase 3: Build Order Generation
    const build_order = try generateBuildOrder(allocator, &graph);

    return ResolutionResult{ .build_order = build_order, .graph = graph };
}
```

### Integration Requirements

- **Libalpm Integration**: Query installed packages and repositories
- **AUR Integration**: Batch API requests for efficiency
- **Performance Optimization**: Implement caching and early pruning
- **Error Handling**: Clear messages for unresolvable dependencies

### Build Order Output Format

Per SPEC.md, `buildorder` command must output tabular format with:

- **AUR**: Packages needing to be built
- **REPOS**: Packages available in official repositories
- **UNKNOWN**: Missing packages (broken dependency chain)
- **SATISFIED** prefix: Already installed packages
- **TARGET** prefix: User-specified packages

## Core Module Responsibilities

### main.zig

```zig
// Simple entry point with clear error handling
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const command = parseArgs(args) catch |err| switch (err) {
        error.InvalidArgs => {
            printUsage();
            std.process.exit(2);
        },
        else => return err,
    };

    try commands.execute(allocator, command);
}
```

### commands.zig

```zig
// All commands in one place initially - easy to understand and modify
pub fn execute(allocator: std.mem.Allocator, cmd: Command) !void {
    switch (cmd.operation) {
        .info => try handleInfo(allocator, cmd),
        .search => try handleSearch(allocator, cmd),
        .clone => try handleClone(allocator, cmd),
        .build => try handleBuild(allocator, cmd),
        .sync => try handleSync(allocator, cmd),
        // ... other commands
    }
}

fn handleSync(allocator: std.mem.Allocator, cmd: Command) !void {
    // 1. Resolve dependencies
    const build_order = try solver.resolve(allocator, cmd.packages);

    // 2. Clone packages
    for (build_order) |pkg| {
        try git.clonePackage(allocator, pkg);
    }

    // 3. Build in order
    for (build_order) |pkg| {
        try buildPackage(allocator, pkg);
        try repo.addPackage(allocator, pkg);
    }

    // 4. Install via pacman
    try installFromRepo(allocator, cmd.packages);
}
```

### aur.zig

```zig
// Simple AUR API client
pub const Client = struct {
    allocator: std.mem.Allocator,

    pub fn getPackageInfo(self: *Self, package: []const u8) !?AurPackage {
        const url = try std.fmt.allocPrint(self.allocator,
            "https://aur.archlinux.org/rpc/v5/info?arg={s}", .{package});
        defer self.allocator.free(url);

        const response = try utils.httpGet(self.allocator, url);
        defer self.allocator.free(response);

        return parseInfoResponse(self.allocator, response);
    }

    pub fn searchPackages(self: *Self, query: []const u8) ![]AurPackage {
        // Similar simple implementation
    }
};
```

### solver.zig

```zig
// Simple dependency resolution - implements 3-phase approach:
// Phase 1: Discovery (build dependency graph)
// Phase 2: Conflict Resolution (handle providers/conflicts)
// Phase 3: Build Order (topological sort)
// Start simple, grow into full phased approach as needed

pub fn resolve(allocator: std.mem.Allocator, packages: []const []const u8) ![][]const u8 {
    var resolved = std.ArrayList([]const u8).init(allocator);
    var visited = std.StringHashMap(void).init(allocator);

    for (packages) |pkg| {
        try resolveRecursive(allocator, pkg, &resolved, &visited);
    }

    // Simple topological sort (upgrade to parallel build detection later)
    return topologicalSort(allocator, resolved.items);
}

fn resolveRecursive(allocator: std.mem.Allocator, pkg: []const u8,
                   resolved: *std.ArrayList([]const u8),
                   visited: *std.StringHashMap(void)) !void {
    if (visited.contains(pkg)) return;

    try visited.put(pkg, {});

    // Get package info and dependencies
    const info = try aur.getPackageInfo(pkg) orelse return error.PackageNotFound;

    // Resolve dependencies first
    for (info.depends) |dep| {
        try resolveRecursive(allocator, dep, resolved, visited);
    }

    try resolved.append(pkg);
}
```

## Key Design Principles

### 1. Start Simple, Grow Organically

```zig
// Phase 1: Simple string matching for dependencies
fn isDependencySatisfied(dep: []const u8) bool {
    return utils.isPackageInstalled(dep);
}

// Phase 2: Add version checking when needed
fn isDependencySatisfied(dep: []const u8) bool {
    const parsed = parseDependencyString(dep);
    return utils.isPackageInstalled(parsed.name) and
           utils.checkVersionSatisfied(parsed.name, parsed.version_spec);
}
```

### 2. Clear Error Handling

```zig
// Simple error messages that are easy to understand and extend
pub const Error = error{
    PackageNotFound,
    NetworkError,
    BuildFailed,
    DependencyResolutionFailed,
};

pub fn handleError(err: Error, context: []const u8) void {
    switch (err) {
        error.PackageNotFound => std.debug.print("Error: Package '{s}' not found in AUR\n", .{context}),
        error.NetworkError => std.debug.print("Error: Network request failed: {s}\n", .{context}),
        error.BuildFailed => std.debug.print("Error: Build failed for package '{s}'\n", .{context}),
        error.DependencyResolutionFailed => std.debug.print("Error: Cannot resolve dependencies for '{s}'\n", .{context}),
    }
}
```

### 3. Straightforward Data Flow

```
User Input → CLI Parser → Command Handler → Core Logic → System Operations → Output
     ↓             ↓            ↓              ↓              ↓             ↓
  main.zig  →  main.zig  → commands.zig → aur.zig/solver.zig → utils.zig → stdout/stderr
```

### 4. Easy Testing Strategy

```zig
// Test individual functions with simple inputs/outputs
test "dependency resolution basic case" {
    const allocator = std.testing.allocator;
    const result = try solver.resolve(allocator, &[_][]const u8{"package1"});
    defer allocator.free(result);

    try std.testing.expect(result.len > 0);
    try std.testing.expectEqualStrings("package1", result[result.len - 1]);
}

// Integration tests that are easy to understand
test "full sync workflow" {
    // Mock AUR responses
    // Test complete sync operation
    // Verify final state
}
```

### Testing File Structure

```
tests/
├── unit/
│   ├── aur_client_test.zig
│   ├── solver_test.zig
│   ├── build_order_test.zig
│   └── repository_test.zig
├── integration/
│   ├── full_sync_test.zig
│   └── error_recovery_test.zig
└── fixtures/
    ├── mock_aur_responses/
    └── test_packages/
```

## Configuration: Keep It Simple

### Phase 1 (🔴 Core): Hardcoded Constants

```zig
// Embed defaults directly in code for simplicity
pub const DEFAULT_CACHE_DIR = "~/.cache/aurodle";
pub const DEFAULT_REPO_PATH = "~/.cache/aurodle/aurpkgs";
pub const DEFAULT_REPO_NAME = "aurpkgs";
```

### Phase 2 (🟡 Standard): Environment Variables

```zig
pub fn getConfig() Config {
    return Config{
        .cache_dir = std.os.getenv("AURDEST") orelse DEFAULT_CACHE_DIR,
        .editor = std.os.getenv("EDITOR"),
        .repo_path = DEFAULT_REPO_PATH,
    };
}
```

### Phase 3 (🟢 Advanced): Configuration Files

Only add when users actually request it and the simple approach proves insufficient.

## Performance: Optimize When Needed

### Start Simple

```zig
// Phase 1: Sequential API calls - simple and reliable
for (packages) |pkg| {
    const info = try aur.getPackageInfo(pkg);
    // Process immediately
}
```

### Add Complexity When Proven Necessary

```zig
// Phase 2: Batch requests only when users report slowness
const info_list = try aur.getMultiplePackageInfo(packages);
```

## Error Recovery: Fail Fast, Recover Gracefully

```zig
// Simple error handling that doesn't hide problems
fn buildPackage(allocator: std.mem.Allocator, pkg: []const u8) !void {
    const result = try utils.runCommand(&[_][]const u8{ "makepkg", "-si" });
    if (result.exit_code != 0) {
        std.debug.print("Build failed for {s}:\n{s}\n", .{ pkg, result.stderr });
        return error.BuildFailed;
    }
}

// For operations that should continue despite individual failures
fn buildAllPackages(allocator: std.mem.Allocator, packages: [][]const u8) !void {
    var failed_packages = std.ArrayList([]const u8).init(allocator);
    defer failed_packages.deinit();

    for (packages) |pkg| {
        buildPackage(allocator, pkg) catch {
            try failed_packages.append(pkg);
            continue;
        };
    }

    if (failed_packages.items.len > 0) {
        // Report failed packages and continue
        std.debug.print("Failed to build: ");
        for (failed_packages.items) |pkg| std.debug.print("{s} ", .{pkg});
        std.debug.print("\n");
    }
}
```

## Migration Path

This architecture supports clean growth:

1. **🔴 MVP (7 files)**: Implement core functionality quickly
2. **🟡 Standard (10-12 files)**: Split large files when they become unwieldy
3. **🟢 Advanced (15-20 files)**: Add sophisticated features only when needed
4. **🔵 Future**: Refactor into more complex patterns only if justified

## Benefits of This Approach

**For Development:**

- Quick to implement and iterate
- Easy to debug and understand
- Low cognitive load
- Simple testing strategy

**For Maintenance:**

- Clear upgrade paths
- Minimal abstraction overhead
- Predictable complexity growth
- Easy to onboard new contributors

**For Users:**

- Fast development cycle
- Reliable, simple behavior
- Clear error messages
- Predictable performance

This architecture embraces the Unix philosophy: do one thing well, and provide clear composition points for growth when needed.

## Evolution Strategy (Simple to Sophisticated)

The architecture is designed to start simple and evolve based on user needs. Key areas with planned evolution:

### 1. **Dependency Resolution: Simple → Sophisticated**

- **MVP**: Simple recursive resolution with basic conflict detection
- **Upgrade Path**: Implement 3-phase resolution (Discovery → Conflict Resolution → Build Order)
- **When**: When users report complex dependency resolution failures

### 2. **Error Recovery: Basic → Comprehensive**

- **MVP**: Basic error reporting with build log preservation
- **Upgrade Path**: Add rollback mechanisms, partial operation recovery, dependency graph updates
- **When**: When partial failures leave systems in inconsistent states

### 3. **Caching: Memory → Multi-level**

- **MVP**: Simple in-memory HashMap cache
- **Upgrade Path**: Add disk persistence, TTL management, cache invalidation
- **When**: When users report performance issues with repeated operations

### 4. **Concurrency: Sequential → Parallel**

- **MVP**: Sequential operations for simplicity and reliability
- **Upgrade Path**: Add thread pools for batch queries, parallel builds for independent packages
- **When**: Performance benchmarks show significant sequential bottlenecks

### 5. **Configuration: Hardcoded → Hierarchical**

- **MVP**: Hardcoded defaults with basic environment variable overrides
- **Upgrade Path**: Three-tier system (Core → Standard → Advanced) with config files
- **When**: Users request advanced configuration options

### 6. **Build Process: Simple → Sophisticated**

- **MVP**: Sequential building with basic error handling
- **Upgrade Path**: Parallel builds, chroot isolation, build artifact management
- **When**: Users need reproducible builds or faster build times

### 7. **Security Review: Optional → Integrated**

- **MVP**: Security review deferred to post-MVP
- **Upgrade Path**: Implement file review process with PKGBUILD display and user confirmation
- **When**: Moving from MVP to Standard phase implementation

## Architectural Debt and Mitigation

### Technical Debt Incurred

1. **Single large files** - commands.zig will grow unwieldy
2. **Simple error handling** - May not handle all edge cases
3. **No performance optimization** - Sequential operations may be slow
4. **Basic configuration** - Limited customization options

### Mitigation Strategy

1. **Clear splitting points** - Documented in growth strategy
2. **Error context preservation** - Foundation for sophisticated error handling
3. **Performance monitoring hooks** - Easy to add benchmarking later
4. **Configuration upgrade path** - Environment variables provide stepping stone

## Key Architectural Principles

The architecture maintains these critical architectural principles:

1. **Data Integrity** - Atomic operations prevent corruption
2. **User Safety** - Security review integration prevents malicious code execution
3. **Debuggability** - Error context and build log preservation enable troubleshooting
4. **Performance Awareness** - Basic caching and batch processing prevent major bottlenecks
5. **Maintainability** - Clear module boundaries and upgrade paths
6. **Testability** - Simple functions with clear inputs/outputs

This ensures the architecture can evolve into a sophisticated system without fundamental rewrites.
