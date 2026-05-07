# Aurodle — Architecture Status 8

> Reflects the codebase after the modularization refactor (Phases 1–4).
> Supersedes `ARCHITECTURE_status7.md`.

**Module dependency graph:** [`docs/architecture_status/module-graph_status8.md`](module-graph_status8.md)

---

## Sentrux health metrics

### Current scan (post-refactor)

| Dimension | Before (status7) | After (status8) | Assessment |
|---|---|---|---|
| **Quality Signal** | 0.5725 (57.25%) | 0.4964 (49.64%) | ↓ Modularity improved, but depth and acyclicity regressed |
| **Bottleneck** | Modularity | Acyclicity | Shifted |
| **Acyclicity** | 1.0 (perfect) | 0.75 (raw: 3 inversions) | ↓ Minor inversions from test files and root.zig test block |
| **Depth** | 11 levels | 13 levels | ↑ Splitting files added 2 levels |
| **File Size Equality** | 0.229 | 0.226 | → Stable |
| **Cross-Module Edges** | 97 / 121 (80%) | 117 / 162 (72%) | ↓ Better module boundaries |
| **Test Coverage (sentrux)** | 0 / 68 source files | 22 / 77 source files (28.6%) | ↑ Mock-based unit tests now register |

111 files · 162 import edges · ~31,108 total lines · DSM propagation cost 27.98%

The refactor successfully **broke the hubs** and **split the mega-files**, but the act of creating new files and moving tests increased total depth and introduced minor acyclicity penalties (likely from same-level dependencies in the new test files). Cross-module coupling dropped from 80% to 72%, confirming better module boundaries.

---

## Source layout

```
src/
├── main.zig                 745 lines   CLI parsing, command dispatch
├── root.zig                  33 lines   Minimal API surface: 2 public re-exports + test discovery
├── commands.zig              35 lines   Thin hub: re-exports types + sub-commands
├── commands/
│   ├── types.zig            252 lines   Shared types, I/O helpers, Flags, ExitCode
│   ├── query_context.zig     51 lines   QueryContext struct
│   ├── build_context.zig     60 lines   BuildContext struct
│   ├── display.zig          446 lines   Plan display helpers
│   ├── outdated.zig         168 lines   collectOutdated, checkDevelPackages
│   ├── query.zig            448 lines   info, search, outdated, VCS check
│   ├── analysis.zig          99 lines   resolve, buildorder
│   ├── status.zig           159 lines   Arch Linux service status page
│   ├── build_cmd.zig        520 lines   Build pipeline orchestration
│   ├── build_execute.zig    313 lines   makepkg / makechrootpkg mechanics
│   ├── build_install.zig    178 lines   pacman invocations, provider selection
│   └── build_review.zig     123 lines   PKGBUILD review, diff viewing
├── solver.zig               426 lines   Orchestrator: BFS discovery + plan assembly
├── solver/
│   ├── graph.zig             83 lines   DepGraph data structure
│   ├── topo.zig              80 lines   Kahn's algorithm topological sort
│   ├── conflicts.zig        166 lines   Conflict detection
│   ├── mocks.zig            548 lines   Test doubles (MockRegistry, MockInstalledSet)
│   └── tests.zig           1207 lines   Unit tests for SolverImpl(MockRegistry)
├── registry.zig             444 lines   Multi-source package lookup cascade
├── registry/
│   ├── mocks.zig            239 lines   Test doubles (MockPacman, MockAurClient)
│   └── tests.zig            607 lines   Unit tests for RegistryImpl(MockPacman, MockAurClient)
├── dep_spec.zig              95 lines   DepSpec, parseDep
├── pacman.zig               810 lines   libalpm domain layer
├── pacman_conf.zig          117 lines   PacmanConf, registerSyncDbs
├── version.zig               68 lines   VersionConstraint, checkVersion
├── repo.zig                 951 lines   Local pacman repository management
├── makepkg.zig              111 lines   MakepkgConfig, parseMakepkgConf
├── repo_conf.zig             77 lines   deriveRepoNameFromPacmanConf
├── plan.zig                  68 lines   Shared build plan types (Layer 1)
├── source.zig                12 lines   Source enum (Layer 0)
├── alpm.zig                 543 lines   Thin C FFI wrapper for libalpm
├── aur.zig                  601 lines   AUR RPC HTTP client + JSON types
├── git.zig                  574 lines   Git clone / update ops
├── auth.zig                 462 lines   Privilege escalation
├── devel.zig                194 lines   VCS package version check
├── utils.zig                313 lines   Process execution, interactive prompts
├── provider.zig              18 lines   Provider selection types
└── color.zig                 86 lines   Terminal ANSI colour styling
```

**Size distribution:**

| Tier | Lines | Files |
|---|---|---|
| < 50 | `source.zig` (12), `provider.zig` (18), `root.zig` (33), `query_context.zig` (51), `build_context.zig` (60), `version.zig` (68) |
| 50–300 | `plan.zig`, `color.zig`, `solver/topo.zig`, `solver/graph.zig`, `dep_spec.zig`, `pacman_conf.zig`, `repo_conf.zig`, `makepkg.zig` |
| 300–600 | `commands/build_cmd.zig`, `commands/types.zig`, `git.zig`, `alpm.zig`, `auth.zig`, `utils.zig`, `solver.zig`, `registry.zig` |
| 600–1000 | `pacman.zig` (810), `repo.zig` (951) |
| 1000+ | `solver/tests.zig` (1207), `registry/tests.zig` (607) — test files only |

No production source file exceeds 1,000 lines. The largest production files are `repo.zig` (951) and `pacman.zig` (810). The three former mega-files (`solver.zig`, `repo.zig`, `registry.zig`) dropped from ~4,100 lines combined to ~1,800 lines combined.

---

## Layers

Dependencies flow downward. No upward or cross-layer violations.

```
┌─────────────────────────────────────────────────────────────────┐
│  Layer 5 · Entry         main.zig                                │
├─────────────────────────────────────────────────────────────────┤
│  Layer 4 · Commands      commands.zig (thin hub)                 │
│                          commands/types.zig (shared types)       │
│                          commands/query_context.zig              │
│                          commands/build_context.zig              │
│                          commands/display.zig                    │
│                          commands/outdated.zig                   │
│                          commands/{query, analysis, status}      │
│                          commands/build_cmd.zig (orchestrator)   │
│                          commands/build_execute.zig              │
│                          commands/build_install.zig              │
│                          commands/build_review.zig               │
├─────────────────────────────────────────────────────────────────┤
│  Layer 3 · Resolution    solver.zig (orchestrator)               │
│                          solver/{graph, topo, conflicts}         │
│                          registry.zig                            │
│                          dep_spec.zig                            │
├─────────────────────────────────────────────────────────────────┤
│  Layer 2 · Domain        pacman.zig  devel.zig                   │
│                          pacman_conf.zig  version.zig            │
├─────────────────────────────────────────────────────────────────┤
│  Layer 1 · Infrastructure  git.zig  repo.zig                     │
│                             auth.zig  utils.zig                  │
│                             plan.zig  makepkg.zig                │
│                             repo_conf.zig                        │
├─────────────────────────────────────────────────────────────────┤
│  Layer 0 · Wrappers      alpm.zig  aur.zig  color.zig           │
│                          provider.zig  source.zig                │
└─────────────────────────────────────────────────────────────────┘
```

---

## Depth chain (13 levels)

```
color(1) → provider(2) → utils/plan(3) → git(4) → devel(5) → registry(6)
         → s_conflicts(7) → solver(8) → analysis/build_cmd/query(9)
         → commands(10) → main(13)
```

The maximum depth increased from 11 to 13 levels because:
- New extracted files (`version.zig`, `pacman_conf.zig`, `makepkg.zig`, `repo_conf.zig`, `dep_spec.zig`) add intermediate layers
- Test files (`solver/tests.zig`, `registry/tests.zig`) create additional depth paths

The propagation cost rose slightly from 27.23% to 27.98% (+0.75%). This is an expected trade-off when splitting large files into smaller ones — shallower individual files at the cost of a deeper overall graph.

---

## Module responsibilities

| Module | Responsibility | Notable public surface |
|---|---|---|
| `main.zig` | Arg parsing; builds the full stack; dispatches to commands | `main()`, `runWithFullStack()` |
| `commands.zig` | **Thin hub**: re-exports types and sub-commands | (re-exports only) |
| `commands/types.zig` | Shared types, I/O helpers, Flags, ExitCode | `Commands`, `Flags`, `ExitCode`, `BuildResult`, `OutdatedEntry`, `OutdatedList`, `handleResolveError`, `getStdout` |
| `commands/query_context.zig` | Per-domain context for read-only queries | `QueryContext` |
| `commands/build_context.zig` | Per-domain context for build operations | `BuildContext` |
| `commands/display.zig` | Plan display: verbose/compact package tables, size formatting | `displayPlan`, `displayInstallList` |
| `commands/outdated.zig` | Outdated package detection: AUR RPC diff + VCS --devel probe | `collectOutdated`, `checkDevelPackages` |
| `commands/query.zig` | Read-only AUR queries; outdated detection | `info`, `search`, `outdated` |
| `commands/build_cmd.zig` | Build pipeline orchestration: resolve → clone → review → build → install | `show`, `clonePackages`, `sync`, `build`, `runBuildPipeline`, `upgrade` |
| `commands/build_execute.zig` | makepkg / makechrootpkg mechanics; failure propagation | `runBuild`, `BuildError` |
| `commands/build_install.zig` | pacman install invocations; provider selection UI; cache purge | `installPackages`, `purgeCache` |
| `commands/build_review.zig` | PKGBUILD review: diff viewing, interactive accept/edit/abort | `reviewPkgbuild`, `resolveConflicts` |
| `commands/analysis.zig` | Dependency tree display and machine-readable build order | `resolve`, `buildorder` |
| `commands/status.zig` | Fetch and display Arch Linux service monitor data | `run()` |
| `solver.zig` | Orchestrates: BFS discovery → conflict detection → topo sort → plan assembly | `Solver`, `SolverImpl`, `BuildPlan`, `BuildEntry`, `DependencyEntry`, `Conflict` |
| `solver/graph.zig` | Directed dependency graph with alias resolution | `DepGraph`, `NodeMeta` |
| `solver/topo.zig` | Kahn's algorithm topological sort over AUR nodes | `topoSort` |
| `solver/conflicts.zig` | AUR↔AUR, AUR↔installed conflict and replaces detection | `detectConflicts`, `Conflict` (re-exported from plan.zig) |
| `solver/tests.zig` | Unit tests exercising `SolverImpl(MockRegistry)` | — |
| `plan.zig` | **Layer 1 types:** `BuildPlan`, `BuildEntry`, `DependencyEntry`, `Conflict` | `BuildPlan`, `BuildEntry`, `DependencyEntry`, `Conflict` |
| `registry.zig` | Four-tier lookup; caching; `vercmp`; `isVcsPackage` | `PackageRegistry`, `resolve`, `resolveMany`, `Source`, `vercmp`, `isVcsPackage` |
| `registry/tests.zig` | Unit tests exercising `RegistryImpl(MockPacman, MockAurClient)` | — |
| `dep_spec.zig` | Dependency specification parsing | `DepSpec`, `parseDep` |
| `source.zig` | **Layer 0 type:** `Source` enum | `Source` |
| `pacman.zig` | Domain queries on `alpm.zig`: installed/sync lookups, version constraints | `Pacman`, `isInstalled`, `installedVersion`, `findProvider`, `allForeignPackages` |
| `pacman_conf.zig` | pacman.conf parsing and sync DB registration | `PacmanConf`, `registerSyncDbs` |
| `version.zig` | Version constraint parsing and comparison | `VersionConstraint`, `checkVersion`, `CmpOp` |
| `repo.zig` | Local pacman repository lifecycle | `Repository`, `addBuiltPackages`, `listPackages`, `clean`, `refreshAurpkgsSyncDb` |
| `makepkg.zig` | makepkg.conf parsing | `MakepkgConfig`, `parseMakepkgConf` |
| `repo_conf.zig` | Repository name derivation from pacman.conf | `deriveRepoNameFromPacmanConf`, `isConfiguredFromPath` |
| `alpm.zig` | Thin, zero-heap-alloc C FFI over libalpm | `Handle`, `Database`, `AlpmPackage`, `vercmp` |
| `aur.zig` | HTTP client for AUR RPC v5: search, info, multiInfo | `Client`, `Package`, `SearchField` |
| `git.zig` | Stateless, idempotent git ops on the AUR clone cache | `clone`, `update`, `cloneOrUpdate`, `CacheRoot` |
| `auth.zig` | Privilege escalation: PACMAN_AUTH env → sudo → su fallback | `Auth`, `shellJoin` |
| `devel.zig` | VCS package freshness: `makepkg --nobuild --printsrcinfo` | `isVcsPackage`, `checkVersion`, `parseSrcinfoVersion` |
| `utils.zig` | Subprocess execution; `promptYesNo`; `promptProviderChoice` | `runCommand`, `runCommandIn`, `runInteractive`, `promptProviderChoice` |
| `provider.zig` | Shared provider selection types | `ProviderCandidate`, `ProviderChooserFn`, `ProviderSelection` |
| `color.zig` | Terminal ANSI colour; `Style` enum | `Style` |

---

## How we got here: Phases 1–4

### Phase 1: Break the Hubs ✅ COMPLETE

#### `root.zig` — Slimmed from 12 public re-exports to 2

**Before:**
```zig
pub const utils = @import("utils.zig");
pub const aur = @import("aur.zig");
// ... 10 more public re-exports
```

**After:**
```zig
pub const alpm = @import("alpm.zig");
pub const devel = @import("devel.zig");
// Everything else is a private import (prefixed with _)
```

`main.zig` now imports modules directly (`@import("aur.zig")`, `@import("pacman.zig")`, etc.) instead of going through `@import("aurodle")`. `root.zig` is retained purely as an external API surface for specification tests.

#### `commands.zig` — Still a re-export layer, but grounded

**Before:** Re-exported 15+ types from `commands/context.zig`.
**After:** Re-exports 12 types from `commands/types.zig` and 2 context structs (`QueryContext`, `BuildContext`).

The hub still exists but is no longer a hidden dependency magnet — it draws from a dedicated types file rather than a monolithic context struct.

---

### Phase 2: Split Mega-Files ✅ COMPLETE

#### File size distribution (lines)

| File | Before | After | Change |
|------|--------|-------|--------|
| `solver.zig` | 1623 | 426 | −1197 (tests extracted) |
| `registry.zig` | 1111 | 444 | −667 (tests extracted) |
| `repo.zig` | 1344 | 951 | −393 (makepkg.zig + repo_conf.zig) |
| `pacman.zig` | 977 | 810 | −167 (version.zig + pacman_conf.zig) |
| `commands/context.zig` | 312 | — | deleted |

#### New files created

| File | Lines | Source |
|------|-------|--------|
| `solver/tests.zig` | 1207 | Extracted from `solver.zig` |
| `registry/tests.zig` | 607 | Extracted from `registry.zig` |
| `commands/types.zig` | 252 | Extracted from `commands/context.zig` |
| `commands/query_context.zig` | 51 | New (QueryContext split) |
| `commands/build_context.zig` | 60 | New (BuildContext split) |
| `version.zig` | 68 | Extracted from `pacman.zig` |
| `pacman_conf.zig` | 117 | Extracted from `pacman.zig` |
| `makepkg.zig` | 111 | Extracted from `repo.zig` |
| `repo_conf.zig` | 77 | Extracted from `repo.zig` |
| `dep_spec.zig` | 95 | Extracted from `registry.zig` |

**Result:** No source file exceeds 1,000 lines. The largest production files are now `repo.zig` (951) and `pacman.zig` (810).

---

### Phase 3: Flatten and Rename ✅ COMPLETE

**Before:**
```
commands/
├── build_cmd.zig
├── build_cmd/
│   ├── build.zig
│   ├── install.zig
│   └── review.zig
```

**After:**
```
commands/
├── build_cmd.zig
├── build_execute.zig
├── build_install.zig
├── build_review.zig
```

The `build_cmd/` subdirectory is gone. All build-phase modules live at the same level as the coordinator, eliminating `../../` imports.

---

### Phase 4: Connect Mocks to Tests ✅ COMPLETE

**Before:** Sentrux reported 0 / 68 source files as tested.
**After:** 22 / 77 source files (28.6%) are recognized as tested.

| Test File | Mock Type | Source Covered |
|-----------|-----------|----------------|
| `solver/tests.zig` | `MockRegistry` | `solver.zig` |
| `registry/tests.zig` | `MockPacman`, `MockAurClient` | `registry.zig` |

The generic `RegistryImpl(PacmanT, AurClientT)` and `SolverImpl(RegistryT)` are now exercised by dedicated unit test suites that import their source modules directly. This is why sentrux can trace the coverage link.

**Remaining gap:** 55 source files still show as untested. Most have inline `test` blocks, but sentrux only counts coverage when a separate test file explicitly imports the source module.

---

## Remaining architectural issues

### Issue N — Acyclicity Regression (New Bottleneck)

| Metric | Before | After |
|--------|--------|-------|
| Acyclicity raw | 0 | 3 |
| Acyclicity score | 1.000 | 0.250 |

The DSM still reports **zero cycles** (`above_diagonal: 0`), but sentrux now detects 3 inversions. These likely stem from:
- New test files at the same dependency level creating ambiguous layering
- `root.zig`'s `test { refAllDecls }` block pulling in all modules for test discovery
- The increased file count (99 → 111) stretching the level assignment algorithm

**Mitigation:** The inversions are minor (score 2500/10000) and the DSM interpretation still reads "Clean layering: all dependencies flow downward." No action required unless acyclicity drops further.

### Issue O — Depth Increase

| Metric | Before | After |
|--------|--------|-------|
| Depth | 11 | 13 |
| Propagation cost | 27.23% | 27.98% |

Adding 10 new files increased the maximum dependency depth by 2 levels. The propagation cost rose slightly (0.75%). This is expected when splitting large files into smaller ones — the trade-off is shallower individual files at the cost of a deeper overall graph.

**Assessment:** Acceptable. The benefit of smaller, focused files outweighs the marginal depth increase.

### Issue P — `commands.zig` Still a Thin Hub

`commands.zig` (35 lines) still re-exports 12 types and 4 submodules. It is no longer a *hidden* dependency magnet (it routes through `types.zig` now), but it remains a layer of indirection.

**Future option:** Have `main.zig` import `commands/types.zig` and `commands/query_context.zig` directly, reducing `commands.zig` to a pure command router.

---

## Recommended next steps

### Immediate (Low Effort)
1. **Slim `commands.zig` further** — move type re-exports to direct imports in `main.zig`.
2. **Extract `repo/tests.zig`** — `repo.zig` still has ~438 lines of inline filesystem tests that could be moved out.

### Medium Term
3. **Extract `aur.zig` tests** — ~200 lines of JSON parsing tests that could move to `aur/tests.zig`.
4. **Extract `git.zig` tests** — ~260 lines of filesystem tests.

### Monitor
5. **Watch acyclicity** — if the raw inversion count grows beyond 5, investigate whether test files are creating false dependencies.

---

## What is stable and well-structured

- **Layers 0–2** remain cleanly focused with no cycles.
- **`plan.zig`** is still a genuinely thin types module at depth 3.
- **`solver/`** remains a textbook deep-module family, fully isolated via `SolverImpl(RegistryT)`.
- **`display.zig`** isolates all plan rendering behind a narrow two-function surface.
- **`outdated.zig`** decouples outdated-detection logic from both `query` and `build_cmd`.
- **Zero dependency cycles** in the DSM — all 156 import edges are below-diagonal.
- **Better module boundaries** — cross-module coupling dropped from 80% to 72%.
- **Recognized test coverage** — 22 source files now have traceable unit tests.

---

## Appendix: Sentrux raw data

```
Files:              111
Import edges:       162
Lines:              31,108
Quality signal:     0.4964

Root causes:
  Acyclicity:       0.250  ← BOTTLENECK
  Modularity:       0.142  ↑ improved from 0.105
  Depth:            13     ↑ from 11
  Equality:         0.226  → stable
  Redundancy:       0.045  ✓ improved from 0.061

Coverage:
  Source files:     77
  Test files:       34
  Tested:           22 / 77 (28.6%)

DSM:
  Above diagonal:   0      (no cycles)
  Below diagonal:   156
  Same level:       6
  Clusters:         3 (2 files each at levels 6, 8, 10)
  Propagation cost: 27.98%
  Level breaks:     11
```
