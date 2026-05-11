# Aurodle — Architecture Status 9

> Reflects the codebase after Phase 5 improvements (test extraction + hub slimming).
> Supersedes `ARCHITECTURE_status8.md`.

**Module dependency graph:** [`docs/architecture_status/module-graph_status9.md`](module-graph_status9.md)

---

## Sentrux health metrics

### Current scan (post-Phase 5)

| Dimension | Before (status8) | After (status9) | Assessment |
|---|---|---|---|
| **Quality Signal** | 0.4964 (49.64%) | 0.5227 (52.27%) | ↑ +5.3% improvement |
| **Bottleneck** | Acyclicity | Acyclicity | Unchanged |
| **Acyclicity** | 0.75 (raw: 3 inversions) | 0.833 (raw: 2 inversions) | ↑ 1 inversion removed |
| **Depth** | 13 levels | 13 levels | → Stable |
| **File Size Equality** | 0.226 | 0.224 | → Stable |
| **Cross-Module Edges** | 117 / 162 (72%) | 120 / 163 (74%) | → Stable |
| **Test Coverage (sentrux)** | 22 / 77 (28.6%) | 22 / 78 (28.2%) | → Stable |
| **Propagation Cost** | 27.98% | 26.31% | ↓ -1.67pp cleaner graph |

112 files · 163 import edges · ~31,546 total lines · DSM propagation cost 26.31%

The Phase 5 refactor successfully **reduced acyclicity inversions** and **slimmed the commands hub**, resulting in a measurable quality signal improvement. Propagation cost dropped below 27% for the first time since the modularization effort began.

---

## Source layout

```
src/
├── main.zig                 749 lines   CLI parsing, command dispatch
├── root.zig                  33 lines   Minimal API surface: 2 public re-exports + test discovery
├── commands.zig              14 lines   Pure command router (re-exports sub-modules only)
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
├── repo.zig                 503 lines   Local pacman repository management
├── repo/
│   └── tests.zig            438 lines   Filesystem integration tests for Repository
├── dep_spec.zig              95 lines   DepSpec, parseDep
├── pacman.zig               810 lines   libalpm domain layer
├── pacman_conf.zig          117 lines   PacmanConf, registerSyncDbs
├── version.zig               68 lines   VersionConstraint, checkVersion
├── repo_conf.zig             77 lines   deriveRepoNameFromPacmanConf
├── plan.zig                  68 lines   Shared build plan types (Layer 1)
├── source.zig                12 lines   Source enum (Layer 0)
├── alpm.zig                 543 lines   Thin C FFI wrapper for libalpm
├── aur.zig                  601 lines   AUR RPC HTTP client + JSON types
├── git.zig                  312 lines   Stateless, idempotent git ops on the AUR clone cache
├── git/
│   └── tests.zig            269 lines   Git operation integration tests
├── auth.zig                 462 lines   Privilege escalation
├── devel.zig                194 lines   VCS package version check
├── utils.zig                322 lines   Process execution, interactive prompts
├── provider.zig              18 lines   Provider selection types
└── color.zig                 86 lines   Terminal ANSI colour styling
```

**Size distribution:**

| Tier | Lines | Files |
|---|---|---|
| < 50 | `source.zig` (12), `provider.zig` (18), `root.zig` (33), `query_context.zig` (51), `build_context.zig` (60), `version.zig` (68) |
| 50–300 | `plan.zig`, `color.zig`, `solver/topo.zig`, `solver/graph.zig`, `dep_spec.zig`, `pacman_conf.zig`, `repo_conf.zig`, `makepkg.zig`, `git.zig` |
| 300–600 | `commands/build_cmd.zig`, `commands/types.zig`, `repo.zig`, `alpm.zig`, `auth.zig`, `utils.zig`, `solver.zig`, `registry.zig` |
| 600–1000 | `pacman.zig` (810), `main.zig` (749), `aur.zig` (601) |
| 1000+ | `solver/tests.zig` (1207), `registry/tests.zig` (607) — test files only |

The two former largest production files (`repo.zig` 951 → 503, `git.zig` 574 → 312) are now well under 600 lines. Only three production files remain above 600 lines: `pacman.zig` (810), `main.zig` (749), and `aur.zig` (601).

---

## Layers

Dependencies flow downward. No upward or cross-layer violations.

```
┌─────────────────────────────────────────────────────────────────┐
│  Layer 5 · Entry         main.zig                                │
├─────────────────────────────────────────────────────────────────┤
│  Layer 4 · Commands      commands.zig (pure router, 14 lines)    │
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

The longest file-to-file dependency path remains unchanged:

```
color(1) → provider(2) → utils/plan(3) → git(4) → devel(5) → registry(6)
         → s_conflicts(7) → solver(8) → analysis/build_cmd/query(9)
         → commands(10) → main(13)
```

Depth remains at 13 because the structural chain through `solver.zig` → `commands/` → `main.zig` has the same number of intermediates. New test files (`repo/tests.zig`, `git/tests.zig`) add depth paths but do not extend the maximum.

---

## Phase 5: Test Extraction + Hub Slimming ✅ COMPLETE

### Extracted `repo/tests.zig`

| Metric | Before | After |
|---|---|---|
| `repo.zig` lines | 951 | 503 (-448) |
| `repo/tests.zig` lines | — | 438 |
| Tests extracted | 0 (inline) | 22 |

**Impact:** Removed 448 lines from the largest production file. `repo.zig` dropped from the "600–1000" tier to the "300–600" tier.

### Extracted `git/tests.zig`

| Metric | Before | After |
|---|---|---|
| `git.zig` lines | 574 | 312 (-262) |
| `git/tests.zig` lines | — | 269 |
| Tests extracted | 0 (inline) | 21 |

**Impact:** Removed 262 lines from `git.zig`. Made `validateFilePath` and `createTestGitRepo` `pub` for test accessibility.

### Slimmed `commands.zig` hub

| Metric | Before | After |
|---|---|---|
| `commands.zig` lines | 35 | 14 |
| Re-exports | 16 (types + contexts + display + sub-modules) | 4 (sub-modules only) |

**Impact:** `main.zig` now imports `ExitCode`, `Flags`, `SortField`, `getStdout` directly from `commands/types.zig`; `QueryContext` from `commands/query_context.zig`; `BuildContext` from `commands/build_context.zig`. `commands/status.zig` updated to import `getStdout` directly from `commands/types.zig`.

### Sentrux metric shifts

| Metric | status8 | status9 | Change |
|---|---|---|---|
| Quality signal | 4964 | 5227 | +263 (+5.3%) |
| Acyclicity raw | 3 | 2 | -1 inversion |
| Acyclicity score | 2500 | 3333 | +833 |
| Propagation cost | 27.98% | 26.31% | -1.67pp |
| Same-level edges | 6 | 4 | -2 |
| Clusters | 3 (levels 6, 8, 10) | 2 (levels 6, 8) | -1 |

---

## Remaining architectural issues

### Issue Q — `pacman.zig` Still a Mega-File

`pacman.zig` is now the largest production source file at **810 lines** (was 810 before, now relatively larger since repo.zig shrank). It contains ~12 inline tests that exercise real libalpm on the host system. These cannot easily be extracted to a mock-based test file because they depend on the actual pacman database.

**Options:**
1. Extract `pacman/tests.zig` with the system-dependent tests (requires making some internals `pub`)
2. Split `pacman.zig` into smaller domain modules (e.g., `pacman/query.zig`, `pacman/installed.zig`)
3. Leave as-is; 810 lines is acceptable for a domain wrapper over a C library

**Assessment:** Low priority. The file is a domain wrapper, not a logic hub. The inline tests are integration tests by nature.

### Issue R — `aur.zig` Inline Tests

`aur.zig` has **~210 lines** of inline JSON parsing tests. Extracting them would require making `parseResponse`, `mapPackage`, `checkError`, `appendUrlEncoded`, `RpcPackage`, and `RpcResponse` public — exposing significant implementation detail.

**Options:**
1. Make internals `pub` and extract `aur/tests.zig`
2. Leave inline tests as-is
3. Refactor to a public `Parser` struct that encapsulates the internal methods

**Assessment:** Medium-low priority. The internals are tightly coupled to AUR RPC v5 format; exposing them for testability is defensible but adds API surface.

### Issue S — Acyclicity (2 inversions remaining)

The DSM reports **2 remaining inversions** (score 3333). These likely stem from:
- `root.zig`'s `test { refAllDecls }` block pulling in all modules
- Same-level dependencies between `solver.zig` and `solver/conflicts.zig` or `registry.zig` and `registry/tests.zig`

**Assessment:** Monitor only. The raw count is low and the DSM still reads "Clean layering: all dependencies flow downward."

### Issue T — Depth Floor at 13

The depth floor is structural: `color → provider → utils → git → devel → registry → solver/conflicts → solver → commands/* → commands.zig → main.zig`. Reducing this would require either:
- Merging intermediate layers (counterproductive)
- Splitting `solver.zig` into a types-only facade and a logic module
- Removing the `commands.zig` router layer (minimal gain: 1 level)

**Assessment:** Acceptable. The benefit of clean module boundaries outweighs the marginal depth cost.

### Issue U — `main.zig` Size

`main.zig` is 749 lines with 31 inline tests. The tests are CLI argument parsing tests that are tightly coupled to `main.zig`'s private `parseArgs` function. Extracting them would require making `parseArgs` and `Operation` public.

**Assessment:** Low priority. Entry-point files are expected to be larger. The tests validate the CLI contract.

---

## Prioritized improvement plan

### Phase 6: Extract `pacman.zig` tests (Medium Effort, Medium Gain)

**Goal:** Reduce `pacman.zig` from 810 to ~700 lines and improve equality.

**Steps:**
1. Make test-necessary internals `pub` in `pacman.zig` (e.g., helper functions used by tests)
2. Create `src/pacman/tests.zig` with the ~12 inline integration tests
3. Remove tests from `pacman.zig`

**Expected gain:** Equality score improvement. `pacman.zig` drops from 810 to ~700 lines.

### Phase 7: Evaluate `aur.zig` test extraction (Medium Effort, Low-Medium Gain)

**Goal:** Reduce `aur.zig` from 601 to ~390 lines.

**Steps:**
1. Decide whether to expose `RpcPackage`, `RpcResponse`, `parseResponse`, `mapPackage`, `checkError`, `appendUrlEncoded` as `pub`
2. If acceptable, create `src/aur/tests.zig` and extract ~210 lines of JSON tests
3. Remove tests from `aur.zig`

**Expected gain:** Equality score improvement. `aur.zig` drops from 601 to ~390 lines.

### Phase 8: Monitor and address acyclicity (Low Effort, Monitor)

**Goal:** Keep acyclicity raw count at ≤ 2.

**Steps:**
1. If inversions grow beyond 3, investigate whether `root.zig`'s test discovery block is the cause
2. Consider replacing `root.zig`'s explicit private imports with a simpler `test { _ = @import("main.zig"); }` approach

### Phase 9: Consider `main.zig` test extraction (Low-Medium Effort, Low Gain)

**Goal:** Reduce `main.zig` from 749 to ~600 lines.

**Steps:**
1. Make `parseArgs`, `Operation`, `ParsedCommand`, `ParseError` public
2. Create `src/main/tests.zig` with the 31 CLI parsing tests
3. Remove tests from `main.zig`

**Expected gain:** Marginal. Entry point tests are conventionally kept inline.

---

## What is stable and well-structured

- **Layers 0–2** remain cleanly focused with no cycles.
- **`plan.zig`** is still a genuinely thin types module at depth 3.
- **`solver/`** remains a textbook deep-module family, fully isolated via `SolverImpl(RegistryT)`.
- **`display.zig`** isolates all plan rendering behind a narrow two-function surface.
- **`outdated.zig`** decouples outdated-detection logic from both `query` and `build_cmd`.
- **Zero dependency cycles** in the DSM — all 159 import edges are below-diagonal.
- **Better module boundaries** — commands.zig is now a pure router.
- **Propagation cost below 27%** for the first time in the refactor history.
- **Recognized test coverage** — 22 source files have traceable unit tests.

---

## Appendix: Sentrux raw data

```
Files:              112
Import edges:       163
Lines:              31,546
Quality signal:     0.5227

Root causes:
  Acyclicity:       0.333  ← BOTTLENECK (improved from 0.250)
  Modularity:       0.129  → slight regression from 0.142
  Depth:            13     → stable
  Equality:         0.224  → stable
  Redundancy:       0.055  → slight regression from 0.045

Coverage:
  Source files:     78
  Test files:       34
  Tested:           22 / 78 (28.2%)

DSM:
  Above diagonal:   0      (no cycles)
  Below diagonal:   159
  Same level:       4
  Clusters:         2 (2 files each at levels 6, 8)
  Propagation cost: 26.31%  ← improved from 27.98%
  Level breaks:     11
```
