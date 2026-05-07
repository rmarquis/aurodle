# Aurodle — Architecture Status 7

> Reflects the codebase as of 2026-05 after the comprehensive structure analysis documented in `STRUCTURE_ANALYSIS_status6.md`.
> Supersedes `ARCHITECTURE_status6.md`.

**Module dependency graph:** [`docs/architecture_status/module-graph_status7.md`](module-graph_status7.md)

---

## Sentrux health metrics

### Current scan (structure analysis baseline)

| Dimension | Value | Assessment |
|---|---|---|
| **Quality Signal** | 0.5725 (57.25%) | Below healthy threshold |
| **Bottleneck** | Modularity | Primary target for improvement |
| **Acyclicity** | 1.0 (perfect) | No circular dependencies — good |
| **Depth** | 11 levels | Deep layering increases propagation cost |
| **File Size Equality** | 0.229 | Very uneven distribution |
| **Cross-Module Edges** | 97 / 121 (80%) | Loose module boundaries |
| **Test Coverage (sentrux)** | 0 / 68 source files | Tests exist but don't register as coverage |

99 files · 121 import edges · ~13 k source lines · 30,307 total lines · DSM propagation cost 27.23%

Bottleneck: **modularity** (raw 0.105) — depth is the secondary drag at 11 levels. The codebase has **clean layering** (no cycles, all dependencies flow downward) but **poor cohesion**. Files don't cluster into modules; instead, everything couples to everything through a few central hubs.

---

## Source layout

```
src/
├── main.zig                 746 lines   CLI parsing, command dispatch
├── commands.zig              32 lines   Thin hub: re-exports context, display + sub-commands
├── commands/
│   ├── context.zig          312 lines   Commands struct, shared types, I/O helpers
│   ├── display.zig          446 lines   Plan display helpers (displayPlan, displayInstallList)
│   ├── outdated.zig         170 lines   collectOutdated, checkDevelPackages
│   ├── query.zig            452 lines   info, search, outdated, VCS check
│   ├── build_cmd.zig        561 lines   Build pipeline orchestration
│   ├── build_cmd/
│   │   ├── build.zig        312 lines   makepkg/makechrootpkg mechanics, failure propagation
│   │   ├── install.zig      177 lines   pacman invocations, provider selection, cache purge
│   │   └── review.zig       122 lines   PKGBUILD review, diff viewing, conflict prompts
│   ├── analysis.zig         106 lines   resolve, buildorder (dep-tree display)
│   └── status.zig           160 lines   Arch Linux service status page
├── solver.zig             1 623 lines   Orchestrator: BFS discovery + plan assembly + tests; re-exports plan types
├── solver/
│   ├── graph.zig             83 lines   DepGraph data structure, alias resolution
│   ├── topo.zig              80 lines   Kahn's algorithm topological sort
│   ├── conflicts.zig        166 lines   Conflict detection; imports Conflict from plan.zig
│   └── mocks.zig            548 lines   Test doubles (MockRegistry, MockInstalledSet)
├── registry.zig           1 111 lines   Multi-source package lookup cascade
├── registry/
│   └── mocks.zig            239 lines   Test doubles (MockPacman, MockAurClient)
├── pacman.zig               977 lines   libalpm domain layer (installed/sync queries)
├── repo.zig               1 344 lines   Local pacman repository management; refreshAurpkgsSyncDb
├── plan.zig                  68 lines   Shared build plan types (Layer 1; no solver dep)
├── source.zig                12 lines   Source enum (Layer 0; shared by registry + solver/graph)
├── alpm.zig                 543 lines   Thin C FFI wrapper for libalpm
├── aur.zig                  601 lines   AUR RPC HTTP client + JSON types
├── git.zig                  580 lines   Git clone / update ops + CacheRoot helpers
├── auth.zig                 462 lines   Privilege escalation (sudo/su + keepalive)
├── devel.zig                194 lines   VCS package version check via makepkg
├── utils.zig                315 lines   Process execution, interactive prompts
├── provider.zig              18 lines   Shared provider selection types (Layer 0)
├── color.zig                 86 lines   Terminal ANSI colour styling
└── root.zig                  18 lines   Re-export hub: 12 public modules
```

**Size distribution:**

| Tier | Lines | Files |
|---|---|---|
| < 50 | `source.zig` (12), `provider.zig` (18), `root.zig` (18) |
| 50–300 | `plan.zig`, `color.zig`, `solver/topo.zig`, `solver/graph.zig`, etc. |
| 300–600 | `commands/build_cmd.zig`, `git.zig`, `alpm.zig`, `auth.zig` |
| 600–1000 | `pacman.zig` (977) |
| 1000–1700 | `registry.zig` (1111), `repo.zig` (1344), `solver.zig` (1623) |

The three largest files contain **~4 100 lines** — **40% of all source code** in just 3 files.

---

## Layers

Dependencies flow downward. No upward or cross-layer violations.

```
┌─────────────────────────────────────────────────────────────────┐
│  Layer 5 · Entry         main.zig                                │
├─────────────────────────────────────────────────────────────────┤
│  Layer 4 · Commands      commands.zig (thin hub)                 │
│                          commands/context.zig (shared types)     │
│                          commands/display.zig (plan display)     │
│                          commands/outdated.zig (outdated check)  │
│                          commands/{query, analysis, status}      │
│                          commands/build_cmd.zig (orchestrator)   │
│                          commands/build_cmd/{build,install,      │
│                                              review}             │
├─────────────────────────────────────────────────────────────────┤
│  Layer 3 · Resolution    solver.zig (orchestrator)               │
│                          solver/{graph, topo, conflicts}         │
│                          registry.zig                            │
├─────────────────────────────────────────────────────────────────┤
│  Layer 2 · Domain        pacman.zig  devel.zig                   │
├─────────────────────────────────────────────────────────────────┤
│  Layer 1 · Infrastructure  git.zig  repo.zig                     │
│                             auth.zig  utils.zig                  │
│                             plan.zig  (shared plan types)        │
├─────────────────────────────────────────────────────────────────┤
│  Layer 0 · Wrappers      alpm.zig  aur.zig  color.zig           │
│                          provider.zig  source.zig                │
└─────────────────────────────────────────────────────────────────┘
```

`plan.zig` sits at Layer 1 depth-wise (imports only `source.zig` and `provider.zig` from Layer 0) but is a pure types module with no infrastructure logic. It provides `BuildPlan`, `BuildEntry`, `DependencyEntry`, and `Conflict` to both Layer 3 (solver, conflicts) and Layer 4 (display, build phases) without pulling in solver machinery.

---

## Depth chain (11 levels)

```
color(1) → provider(2) → utils/plan(3) → git(4) → devel(5) → registry(6)
         → s_conflicts(7) → solver(8) → analysis/build_cmd/query(9)
         → commands(10) → main(11)
```

One level was saved since status5:
- Issue G: `display.zig` dropped from depth 9 to 8 by importing `plan.zig` (depth 3) instead of `solver.zig` (depth 8); `analysis.zig` dropped from 10 to 9.
- Issue G′: `build_cmd/build.zig` dropped from depth 9 to 8 by importing `plan.zig` instead of `solver.zig` and severing the hidden `build.zig → install.zig` import; `build_cmd.zig` dropped from 10 to 9, `commands.zig` from 11 to 10, `main.zig` from 12 to 11.

Three levels saved since status4 (14 → 11 total).

The remaining 11-level chain is structural: `solver.zig` (depth 8) is the key import for `analysis.zig`, `build_cmd.zig`, and `query.zig` (all depth 9) because they need the `Solver` type and its `resolve` method, not just plan types. Reducing further would require splitting `solver.zig` into a types/interface layer and a logic layer.

---

## Module responsibilities

| Module | Responsibility | Notable public surface |
|---|---|---|
| `main.zig` | Arg parsing; builds the full stack; dispatches to commands | `main()`, `runWithFullStack()` |
| `commands.zig` | **Thin hub**: re-exports context types, display helpers, and sub-commands | (re-exports only) |
| `commands/context.zig` | Shared context and types; I/O helpers | `Commands`, `Flags`, `ExitCode`, `BuildResult`, `OutdatedEntry`, `OutdatedList`, `handleResolveError`, `getStdout` |
| `commands/display.zig` | Plan display: verbose/compact package tables, size formatting | `displayPlan`, `displayInstallList` |
| `commands/outdated.zig` | Outdated package detection: AUR RPC diff + VCS --devel probe | `collectOutdated`, `checkDevelPackages` |
| `commands/query.zig` | Read-only AUR queries; outdated detection (re-exports from outdated.zig) | `info`, `search`, `outdated` |
| `commands/build_cmd.zig` | Build pipeline orchestration: resolve → clone → review → build → install | `show`, `clonePackages`, `sync`, `build`, `runBuildPipeline`, `upgrade` |
| `commands/build_cmd/build.zig` | makepkg / makechrootpkg mechanics; failure propagation | `runBuild`, `BuildError` |
| `commands/build_cmd/install.zig` | pacman install invocations; provider selection UI; cache purge | `installPackages`, `purgeCache` |
| `commands/build_cmd/review.zig` | PKGBUILD review: diff viewing, interactive accept/edit/abort; conflict presentation | `reviewPkgbuild`, `resolveConflicts` |
| `commands/analysis.zig` | Dependency tree display and machine-readable build order | `resolve`, `buildorder` |
| `commands/status.zig` | Fetch and display Arch Linux service monitor data | `run()` |
| `solver.zig` | Orchestrates: BFS discovery → conflict detection → topo sort → plan assembly; re-exports plan types | `Solver`, `SolverImpl`, `BuildPlan`, `BuildEntry`, `DependencyEntry`, `Conflict` |
| `solver/graph.zig` | Directed dependency graph with alias resolution | `DepGraph`, `NodeMeta` |
| `solver/topo.zig` | Kahn's algorithm topological sort over AUR nodes | `topoSort` |
| `solver/conflicts.zig` | AUR↔AUR, AUR↔installed conflict and replaces detection | `detectConflicts`, `Conflict` (re-exported from plan.zig) |
| `plan.zig` | **Layer 1 types:** `BuildPlan`, `BuildEntry`, `DependencyEntry`, `Conflict` — shared by solver and command layers without pulling in solver machinery | `BuildPlan`, `BuildEntry`, `DependencyEntry`, `Conflict` |
| `registry.zig` | Four-tier lookup; caching; `vercmp`; `isVcsPackage`; re-exports provider + Source types | `PackageRegistry`, `resolve`, `resolveMany`, `Source`, `vercmp`, `isVcsPackage` |
| `source.zig` | **Layer 0 type:** `Source` enum shared by `registry.zig` and `solver/graph.zig` | `Source` |
| `pacman.zig` | Domain queries on `alpm.zig`: installed/sync lookups, version constraints | `Pacman`, `isInstalled`, `installedVersion`, `findProvider`, `allForeignPackages` |
| `repo.zig` | Local pacman repository lifecycle: `repo-add`, artifact scanning, clean, sync DB refresh | `Repository`, `addBuiltPackages`, `listPackages`, `clean`, `refreshAurpkgsSyncDb` |
| `alpm.zig` | Thin, zero-heap-alloc C FFI over libalpm | `Handle`, `Database`, `AlpmPackage`, `vercmp` |
| `aur.zig` | HTTP client for AUR RPC v5: search, info, multiInfo; JSON deserialization | `Client`, `Package`, `SearchField` |
| `git.zig` | Stateless, idempotent git ops on the AUR clone cache; cache-root resolution | `clone`, `update`, `cloneOrUpdate`, `CacheRoot`, `resolveCacheRoot`, `freeCacheRoot` |
| `auth.zig` | Privilege escalation: PACMAN_AUTH env → sudo → su fallback; keepalive loop | `Auth`, `shellJoin` |
| `devel.zig` | VCS package freshness: run `makepkg --nobuild --printsrcinfo`; parse SRCINFO | `isVcsPackage`, `checkVersion`, `parseSrcinfoVersion` |
| `utils.zig` | Subprocess execution; `promptYesNo`; `promptProviderChoice` | `runCommand`, `runCommandIn`, `runInteractive`, `promptProviderChoice` |
| `provider.zig` | Shared provider selection types (Layer 0) | `ProviderCandidate`, `ProviderChooserFn`, `ProviderSelection` |
| `color.zig` | Terminal ANSI colour; `Style` enum | `Style` |

---

## Issues resolved since status5

### ✓ Issue G — `display.zig` imported `solver.zig` (depth driver)

`display.zig` used `solver_mod.BuildPlan` and `solver_mod.BuildEntry` as parameter
types, pulling in the full solver machinery. The four plan types (`BuildPlan`,
`BuildEntry`, `DependencyEntry`, `Conflict`) were extracted to a new `src/plan.zig`
at depth 3 (imports only `source.zig` + `provider.zig`). `solver.zig` re-exports
them unchanged. `display.zig`, `build_cmd/build.zig`, `build_cmd/review.zig`, and
`solver/conflicts.zig` now import `plan.zig` directly.

`display.zig` dropped from depth 9 to 8; `analysis.zig` from 10 to 9. Also
reduced: import edges −3, propagation cost 2674 → 2540.

### ✓ Issue G′ — `build_cmd/build.zig` imported `install.zig` (new depth floor)

After Issue G, the critical depth-12 path shifted to
`context(7) → b_install(8) → b_build(9) → build_cmd(10) → commands(11) → main(12)`.
`b_build` imported `install.zig` for a single function: `refreshAurpkgsSyncDb`.

`refreshAurpkgsSyncDb` was moved to `repo.zig` using `anytype` for the auth
parameter — no new import needed in `repo.zig`. `build_cmd/build.zig` now calls
`repo_mod.refreshAurpkgsSyncDb` directly (repo.zig was already imported); the
`install.zig` import is gone. `build_cmd.zig` and `install.zig` call sites updated
accordingly. `install.zig` also drops its `auth_mod` import (no longer needed).

`b_build` dropped from depth 9 to 8; `build_cmd` from 10 to 9; `commands` from
11 to 10; `main` from 12 to **11**. Propagation cost 2540 → 2487.

---

## Remaining architectural issues

### Issue H — The "God Module" Hub (`root.zig`)

**File:** `src/root.zig` (18 lines)

`root.zig` re-exports **12 modules**:

```zig
pub const utils = @import("utils.zig");
pub const aur = @import("aur.zig");
pub const commands = @import("commands.zig");
pub const git = @import("git.zig");
pub const repo = @import("repo.zig");
pub const alpm = @import("alpm.zig");
pub const pacman = @import("pacman.zig");
pub const registry = @import("registry.zig");
pub const solver = @import("solver.zig");
pub const devel = @import("devel.zig");
pub const color = @import("color.zig");
pub const auth = @import("auth.zig");
```

`main.zig` imports **one** module (`aurodle`) and accesses all subsystems through it:

```zig
const aurodle = @import("aurodle");
const aur = aurodle.aur;
const commands = aurodle.commands;
const git = aurodle.git;
// ... etc
```

**Impact:**
- Any change to any module's public API surface affects the universal hub.
- The hub becomes a hidden dependency vector: modules that never directly import each other are still connected through `main.zig`'s usage pattern.
- `root.zig` itself does nothing — it's pure coupling surface area.

**Recommended fix:**
- Remove the re-export hub. Have `main.zig` import only the modules it actually needs.
- `root.zig` should only expose what's needed by external consumers (spec tests).
- Target state: `main.zig` has 4–6 direct imports, not 12 indirect ones.

---

### Issue I — The "God Context" Struct (`commands/context.zig`)

**File:** `src/commands/context.zig` (312 lines)

The `Commands` struct holds **9 subsystem references**:

```zig
pub const Commands = struct {
    allocator: Allocator,
    io: std.Io,
    aur_client: *aur.Client,
    pacman: ?*pacman_mod.Pacman,
    registry: ?*registry_mod.PackageRegistry,
    repository: ?*repo_mod.Repository,
    auth: ?*auth_mod.Auth,
    cache_root: ?[]const u8,
    flags: Flags,
    // Plus IO writers, color styles, etc.
};
```

Every command function takes `*Commands`:
- `info` (needs only AUR client) receives the full stack
- `search` (needs only AUR client) receives the full stack
- `show` (needs only git + AUR) receives the full stack

**Impact:**
- Unit testing any command requires constructing a `Commands` with all its dependencies, even if most are unused.
- Commands are implicitly coupled to every subsystem, not just the ones they use.
- The struct acts as a **service locator**, hiding actual dependencies.

**Recommended fix:**
Replace the monolithic `Commands` struct with **per-domain context structs**:

```zig
// commands/query_context.zig
pub const QueryContext = struct {
    allocator: Allocator,
    io: std.Io,
    aur_client: *aur.Client,
    flags: Flags,
};

// commands/build_context.zig
pub const BuildContext = struct {
    allocator: Allocator,
    io: std.Io,
    aur_client: *aur.Client,
    pacman: *pacman_mod.Pacman,
    registry: *registry_mod.PackageRegistry,
    repository: *repo_mod.Repository,
    auth: *auth_mod.Auth,
    cache_root: []const u8,
    flags: Flags,
};
```

Each command receives only what it needs. This makes dependencies explicit and testable.

---

### Issue J — Mega-Files

**File size distribution (lines):**

| Lines | Files |
|---|---|
| < 50 | `source.zig` (12), `provider.zig` (18), `root.zig` (18) |
| 50–300 | `plan.zig`, `color.zig`, `solver/topo.zig`, `solver/graph.zig`, etc. |
| 300–600 | `commands/build_cmd.zig`, `git.zig`, `alpm.zig`, `auth.zig` |
| 600–1000 | `pacman.zig` (977) |
| 1000–1700 | `registry.zig` (1111), `repo.zig` (1344), `solver.zig` (1623) |

The three largest files contain **~4 100 lines** — **40% of all source code** in just 3 files.

#### `solver.zig` (1 623 lines)
Contains: `SolverImpl`, discovery (BFS), prefetch, redirect resolution, plan assembly, and inline tests.

#### `repo.zig` (1 344 lines)
Contains: `Repository` struct, `MakepkgConfig`, `RepoPackage`, `CleanResult`, `parseMakepkgConf`, `deriveRepoNameFromPacmanConf`, `parsePackageFilename`, `refreshAurpkgsSyncDb`, and inline tests.

#### `registry.zig` (1 111 lines)
Contains: `RegistryImpl`, `Resolution`, `DepSpec`, `parseDep`, provider selection, cascade resolution, and inline tests.

#### `pacman.zig` (977 lines)
Contains: `Pacman` struct, `VersionConstraint`, `checkVersion`, `ProviderMatch`, `PacmanConf`, `registerSyncDbs`, and inline tests.

**Impact:**
- Large files are harder to navigate, review, and test.
- Changes to unrelated concepts (e.g. version parsing vs. libalpm handle management) touch the same file.
- Merge conflicts are more likely.

**Recommended fix:**
Extract cohesive sub-concepts into standalone files:

| From | Extract To | Content |
|---|---|---|
| `pacman.zig` | `version.zig` | `VersionConstraint`, `checkVersion`, `CmpOp` |
| `pacman.zig` | `pacman_conf.zig` | `PacmanConf`, `registerSyncDbs`, `addServersFromMirrorlist` |
| `repo.zig` | `makepkg.zig` | `MakepkgConfig`, `parseMakepkgConf`, `parseAssignment` |
| `repo.zig` | `repo_conf.zig` | `deriveRepoNameFromPacmanConf`, `isConfiguredFromPath` |
| `registry.zig` | `dep_spec.zig` | `DepSpec`, `parseDep` |
| `solver.zig` | `solver/discovery.zig` | BFS discovery, `prefetchAurTargets`, `resolveWithRedirects` |
| `solver.zig` | `solver/plan_builder.zig` | `assemblePlan`, build entry classification |

Target: No file > 600 lines.

---

### Issue K — Over-Nested Directory Structure

Current `commands/` layout:

```
commands/
├── analysis.zig
├── build_cmd/
│   ├── build.zig
│   ├── install.zig
│   └── review.zig
├── build_cmd.zig
├── context.zig
├── display.zig
├── outdated.zig
├── query.zig
├── status.zig
└── ...
```

`commands/build_cmd/build.zig` is **3 levels deep** for a single source file. The `build_cmd/` directory exists only because `build.zig` would collide with `build_cmd.zig` at the parent level — this is a naming problem, not an organization problem.

**Impact:**
- `../..` imports everywhere (`@import("../../auth.zig")`).
- Cognitive overhead: you must remember which level you're at.
- The directory structure doesn't reflect a true module boundary.

**Recommended fix:**
Rename to avoid collisions and flatten:

```
commands/
├── analysis.zig
├── build.zig          (was build_cmd.zig)
├── build_execute.zig  (was build_cmd/build.zig)
├── build_install.zig  (was build_cmd/install.zig)
├── build_review.zig   (was build_cmd/review.zig)
├── context.zig
├── display.zig
├── outdated.zig
├── query.zig
├── status.zig
└── ...
```

All files at the same level with consistent naming.

---

### Issue L — Zero Registered Test Coverage

Sentrux reports **0 / 68 source files** as tested, despite:
- 307 inline `test "..."` blocks in `src/`
- 31 test files (mocks, spec tests)
- 426 test blocks in `docs/specifications/`

**Root cause:** The specification tests in `docs/specifications/` import through `root.zig` (`const aurodle = @import("aurodle")`), not directly. Sentrux likely doesn't recognize this as coverage. Additionally, mock files (`solver/mocks.zig`, `registry/mocks.zig`) are test *helpers*, not tests that exercise production code.

**Impact:**
- No automated signal for which source files lack tests.
- Mock files are large (`solver/mocks.zig`: 548 lines, `registry/mocks.zig`: 239 lines) but not attached to actual test suites.
- The `RegistryImpl(PacmanT, AurClientT)` and `SolverImpl(RegistryT)` generics are excellent for testability, but there are no dedicated unit tests using them with the mock types.

**Recommended fix:**
1. Add `solver_test.zig` that uses `SolverImpl(MockRegistry)` with `solver/mocks.zig`.
2. Add `registry_test.zig` that uses `RegistryImpl(MockPacman, MockAurClient)` with `registry/mocks.zig`.
3. Ensure spec tests import source files directly (not just through `root.zig`) so coverage tools can trace the link.

---

### Issue M — Thin Re-Export Layers

`commands.zig` (32 lines) does nothing but re-export:

```zig
const ctx = @import("commands/context.zig");
const display = @import("commands/display.zig");

pub const ExitCode = ctx.ExitCode;
pub const Flags = ctx.Flags;
// ... 15 more re-exports

pub const query = @import("commands/query.zig");
pub const build_cmd = @import("commands/build_cmd.zig");
// ... etc
```

This adds a layer of indirection without adding value. Callers could import `commands/context.zig` directly.

**Impact:**
- Extra hop when tracing where a type is defined.
- `commands.zig` becomes a hidden dependency magnet.

**Recommended fix:**
- Remove the hub. Have `main.zig` and other callers import submodules directly.
- Or, if a hub is desired for API stability, limit it to 3–5 core types, not 15+.

---

## Refactoring roadmap

### Phase 1: Break the Hubs (Highest Impact on Modularity)
1. Remove `root.zig` re-exports; have `main.zig` import directly.
2. Split `Commands` into `QueryContext` / `BuildContext` / `AnalysisContext`.
3. Slim down `commands.zig` to a minimal router, not a re-export hub.

**Expected modularity improvement:** Cross-module edges should drop from 80% to ~50%.

### Phase 2: Split Mega-Files
1. Extract `version.zig`, `pacman_conf.zig` from `pacman.zig`.
2. Extract `makepkg.zig`, `repo_conf.zig` from `repo.zig`.
3. Extract `dep_spec.zig` from `registry.zig`.
4. Extract `solver/discovery.zig`, `solver/plan_builder.zig` from `solver.zig`.

**Expected equality improvement:** File size distribution becomes more even.

### Phase 3: Flatten and Rename
1. Flatten `commands/build_cmd/*` → `commands/build_*.zig`.
2. Standardize import paths (eliminate `../..` where possible).

### Phase 4: Connect Mocks to Tests
1. Write `solver_test.zig` using `SolverImpl(MockRegistry)`.
2. Write `registry_test.zig` using `RegistryImpl(MockPacman, MockAurClient)`.
3. Verify sentrux recognizes the coverage links.

---

## Remaining issues summary

| Issue | Location | Type | Expected gain |
|---|---|---|---|
| H | `root.zig` — 12 public re-exports | God module hub | Decouples main.zig from universal import surface |
| I | `commands/context.zig` — 9-field `Commands` struct | Service locator | Per-domain contexts make deps explicit and testable |
| J | `solver.zig` (1623), `repo.zig` (1344), `registry.zig` (1111) | Mega-files | Easier navigation, review, and mergeability |
| K | `commands/build_cmd/` — 3-level nesting | False hierarchy | Eliminates `../..` imports |
| L | 0 / 68 source files recognized as tested | Coverage gap | Automated test-signal for untested files |
| M | `commands.zig` — 15+ re-exports | Thin indirection layer | Faster type-location tracing |

---

## What is stable and well-structured

- **Layers 0–2** are cleanly focused with no cycles.
- **`plan.zig`** is a genuinely thin types module at depth 3: four structs, no logic, no solver dependency. Both Layer 3 (solver/conflicts) and Layer 4 (display, build phases) share it without transitive coupling.
- **`solver/`** remains a textbook deep-module family, fully isolated from concrete backends via the comptime-generic `SolverImpl(RegistryT)`.
- **`display.zig`** isolates all plan rendering behind a narrow two-function surface.
- **`outdated.zig`** decouples outdated-detection logic from both `query` and `build_cmd`.
- **Zero dependency cycles** — acyclicity score 10000/10000.
- **DSM clean**: all 121 import edges are below-diagonal; zero above-diagonal inversions; zero same-level edges.

---

## Appendix: Sentrux raw data

```
Files:              99
Import edges:       121
Lines:              30,307
Quality signal:     0.5725

Root causes:
  Modularity:       0.105  ← BOTTLENECK
  Acyclicity:       1.000  ✓
  Depth:            11
  Equality:         0.229
  Redundancy:       0.061  ✓

DSM:
  Above diagonal:   0      (no cycles)
  Below diagonal:   119
  Same level:       2
  Clusters:         1 (2 files at level 10)
  Propagation cost: 27.23%
```
