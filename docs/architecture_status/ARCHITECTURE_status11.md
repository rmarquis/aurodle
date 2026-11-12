# Aurodle — Architecture Status 11

> Reflects the codebase at `f3e3bd7` (2026-11-13): 73 commits after status10,
> including the Phase 10 core decoupling cleanups.
> Supersedes `ARCHITECTURE_status10.md`.

**Module dependency graph:** [`docs/architecture_status/module-graph_status11.md`](module-graph_status11.md)

---

## Sentrux health metrics

### Current scan (post-Phase 10)

Three snapshots, all scanned with sentrux 0.3.12 on 2026-11-13:

- **status10** `a11536a`: rescanned to check that the tool version measures the same. It does: every score matches the status10 document.
- **pre-cleanup** `63e0350`: the last feature commit before Phase 10.
- **status11** `f3e3bd7`: current `main`.

| Dimension | status10 | pre-cleanup | status11 | Assessment |
|---|---|---|---|---|
| **Quality Signal** | 0.6747 | 0.6480 | 0.6591 | ↓ −2.3% since status10; Phase 10 recovered +1.7% |
| **Bottleneck** | Modularity | Depth | Depth | Shifted back to depth |
| **Acyclicity** | 1.000 (0 inversions) | 1.000 | 1.000 | → Still perfect |
| **Depth** | 10 levels | 14 levels | 12 levels | ↑ +2 since status10 (see below) |
| **Modularity** | 0.136 | 0.135 | 0.131 | → Stable |
| **File Size Equality** | 0.224 | 0.232 | 0.230 | → Stable |
| **Redundancy** | 0.045 | 0.033 | 0.040 | → Stable |
| **Cross-Module Edges** | 131 / 176 (74%) | 153 / 201 (76%) | 158 / 206 (77%) | → Slowly rising |
| **Test Coverage (sentrux)** | 22 / 78 (28.2%) | 25 / 87 (28.7%) | 24 / 89 (27.0%) | → Misleading, see [Test coverage](#test-coverage) |
| **Propagation Cost** | 21.43% | 23.26% | 20.94% | ↓ Lowest so far |

126 files · 206 import edges · ~34,998 total lines · DSM propagation cost 20.94%

**Summary:**
- **Feature work since status10 added 4 levels of depth.** Most of it came from clean chroot builds, parallel git and VCS checks, version constraints, and the Zig 0.17 port. It also pushed propagation cost to 23.26%.
- **Phase 10 recovered 2 levels** and brought propagation cost to its lowest value yet. Phase 10 was about separating the reusable core from the terminal frontend; the depth gain was a side effect.
- **One import accounts for the remaining +2 levels:** `commands/build_context.zig → solver.zig`.

> Status10's recorded raw counts were 118 files and 32,128 lines. The 0.3.12 rescan of the same commit counts 120 files and 32,660 lines, with identical scores. The deltas below use the rescan.

---

## Source layout

```
src/
├── main.zig                 819 lines   CLI parsing, command dispatch, module wiring
├── root.zig                  46 lines   2 public re-exports + test discovery
├── commands.zig              14 lines   Pure command router (re-exports sub-modules only)
├── commands/
│   ├── types.zig            287 lines   Flags, ExitCode, I/O writers, error printing, stderrReporter
│   ├── query_context.zig     49 lines   QueryContext struct
│   ├── build_context.zig     91 lines   BuildContext struct + newSolver
│   ├── display.zig          470 lines   Plan display helpers
│   ├── outdated.zig         232 lines   collectOutdated, checkDevelPackages
│   ├── query.zig            447 lines   info, search, outdated
│   ├── analysis.zig         112 lines   resolve, buildorder
│   ├── status.zig           161 lines   Arch Linux service status page
│   ├── build_cmd.zig        629 lines   Build pipeline orchestration, upgrade, clean
│   ├── build_execute.zig    556 lines   makepkg / makechrootpkg mechanics, VCS two-pass builds
│   ├── build_install.zig    247 lines   pacman invocations, provider selection
│   └── build_review.zig     144 lines   PKGBUILD review, diff viewing, conflict prompts
├── term.zig                 126 lines   NEW  Terminal prompts (frontend only)
├── color.zig                 86 lines   Terminal ANSI colour styling (frontend only)
├── solver.zig               587 lines   Orchestrator: BFS discovery + plan assembly
├── solver/
│   ├── graph.zig             83 lines   DepGraph data structure
│   ├── topo.zig              80 lines   Kahn's algorithm topological sort
│   ├── conflicts.zig        166 lines   Conflict detection
│   ├── mocks.zig            605 lines   Test doubles (MockRegistry, MockInstalledSet)
│   └── tests.zig           1355 lines   Unit tests for SolverImpl(MockRegistry)
├── registry.zig             526 lines   Multi-source package lookup cascade
├── registry/
│   ├── mocks.zig            242 lines   Test doubles (MockPacman, MockAurClient)
│   └── tests.zig            846 lines   Unit tests for RegistryImpl(MockPacman, MockAurClient)
├── repo.zig                 671 lines   Local pacman repository management
├── repo/
│   └── tests.zig            703 lines   Filesystem integration tests for Repository
├── chroot.zig               581 lines   NEW  Clean chroot builds: setup, pacman.conf, staging
├── dep_spec.zig              95 lines   DepSpec, parseDep
├── pacman.zig               941 lines   libalpm domain layer
├── pacman/
│   ├── mocks.zig            110 lines   NEW  Test doubles for pacman tests
│   └── tests.zig            244 lines   Pacman integration tests
├── pacman_conf.zig          154 lines   PacmanConf, registerSyncDbs
├── version.zig               68 lines   VersionConstraint, checkVersion
├── repo_conf.zig             73 lines   deriveRepoNameFromPacmanConf
├── makepkg.zig              490 lines   makepkg.conf parsing (system, drop-ins, user file)
├── plan.zig                  91 lines   Shared build plan types
├── source.zig                12 lines   Source enum
├── report.zig                75 lines   NEW  Reporter: levelled, uncoloured core → frontend messages
├── alpm.zig                 550 lines   Thin C FFI wrapper for libalpm
├── alpm_c.h                         NEW  translate-c input for libalpm
├── aur.zig                  418 lines   AUR RPC HTTP client + JSON types
├── aur/
│   └── tests.zig            248 lines   JSON parsing tests for AUR client
├── git.zig                  320 lines   Stateless, idempotent git ops on the AUR clone cache
├── git/
│   ├── test_repo.zig         34 lines   NEW  Test helper: throwaway git repositories
│   └── tests.zig            406 lines   Git operation integration tests
├── auth.zig                 498 lines   Privilege escalation, keepalive
├── devel.zig                290 lines   VCS package version check, prepared-source stamps
├── utils.zig                327 lines   Io, process execution, parallelFor, buffered stdout, paths
└── provider.zig              27 lines   ProviderCandidate, ProviderChooser, ProviderSelection
```

**Largest growth since status10:**

| File | status10 | status11 | Δ | Driver |
|---|---:|---:|---:|---|
| `makepkg.zig` | 111 | 490 | +379 | Full makepkg.conf read order (drop-ins, user file, PACMAN_AUTH) |
| `pacman.zig` | 643 | 941 | +298 | Name/provision indexes, version constraints, transitive repo deps |
| `commands/build_execute.zig` | 313 | 556 | +243 | Chroot builds, VCS two-pass builds, already-built checks |
| `repo.zig` | 493 | 671 | +178 | Package version listing, clean of unreferenced files |
| `solver.zig` | 421 | 587 | +166 | Version-constraint enforcement |
| `commands/build_cmd.zig` | 519 | 629 | +110 | Review against last accepted version, parallel clone |

**Size distribution (production files):**

| Tier | Files |
|---|---|
| < 100 | `source` (12), `commands` (14), `provider` (27), `root` (46), `query_context` (49), `version` (68), `repo_conf` (73), `report` (75), `solver/topo` (80), `solver/graph` (83), `color` (86), `plan` (91), `build_context` (91), `dep_spec` (95) |
| 100–300 | `analysis`, `term`, `build_review`, `pacman_conf`, `status`, `solver/conflicts`, `outdated`, `build_install`, `types`, `devel` |
| 300–600 | `git`, `utils`, `aur`, `query`, `display`, `makepkg`, `auth`, `registry`, `alpm`, `build_execute`, `chroot`, `solver` |
| 600–1000 | `build_cmd` (629), `repo` (671), `main` (819), `pacman` (941) |

Four production files are now above the 600-line split trigger, up from two in status10. `pacman.zig` was already flagged in status10 at 643 lines.

---

## Layers

Dependencies flow downward. No upward or cross-layer violations.

The layers changed in two places since status10:
- **`utils.zig` is now a leaf.** It no longer imports `color` or `provider`. Meanwhile `alpm.zig` now imports it for `currentIo()`, so `utils` moves down to Layer 0 and `alpm` up to Layer 1.
- **`color.zig` is frontend-only.** No core module imports it any more, so it moves next to `term.zig` in the command layer.

```
┌─────────────────────────────────────────────────────────────────┐
│  Layer 5 · Entry         main.zig                                │
├─────────────────────────────────────────────────────────────────┤
│  Layer 4 · Commands      commands.zig (pure router, 14 lines)    │
│  (frontend)              commands/types.zig (shared types)       │
│                          commands/query_context.zig              │
│                          commands/build_context.zig              │
│                          commands/display.zig                    │
│                          commands/outdated.zig                   │
│                          commands/{query, analysis, status}      │
│                          commands/build_cmd.zig (orchestrator)   │
│                          commands/build_execute.zig              │
│                          commands/build_install.zig              │
│                          commands/build_review.zig               │
│                          term.zig  color.zig                     │
├─────────────────────────────────────────────────────────────────┤
│  Layer 3 · Resolution    solver.zig (orchestrator)               │
│                          solver/{graph, topo, conflicts}         │
│                          registry.zig                            │
├─────────────────────────────────────────────────────────────────┤
│  Layer 2 · Domain        pacman.zig  devel.zig  dep_spec.zig     │
├─────────────────────────────────────────────────────────────────┤
│  Layer 1 · Infrastructure  alpm.zig  aur.zig  git.zig            │
│                             auth.zig  chroot.zig  repo.zig       │
│                             makepkg.zig  repo_conf.zig           │
│                             pacman_conf.zig  version.zig         │
│                             plan.zig                             │
├─────────────────────────────────────────────────────────────────┤
│  Layer 0 · Primitives    utils.zig  provider.zig  source.zig     │
│                          report.zig                              │
└─────────────────────────────────────────────────────────────────┘
```

**Core vs frontend.** Layers 0–3 import neither `color.zig` nor `term.zig`:
- **Decisions** reach the core as values or through callbacks (`provider.ProviderChooser`).
- **Messages** go out through `report.Reporter`.
- **Remaining terminal-facing code** in the core:
  - The process-wide buffered stdout in `utils.zig`. It is flushed before child processes and worker threads write, so it is about process ordering, not presentation.
  - Child processes (makepkg, pacman, editors) that inherit the terminal.

---

## Depth chain (12 levels)

The longest file-to-file dependency path, counted in import steps (the sentrux convention):

```
utils            level  0   (Layer 0 — leaf)
alpm             level  1   (Layer 1)
version          level  2   (Layer 1)
dep_spec         level  3   (Layer 2)
pacman           level  4   (Layer 2)
registry         level  5   (Layer 3)
solver/conflicts level  6   (Layer 3)
solver           level  7   (Layer 3)
build_context    level  8   (Layer 4)  ← imports solver for newSolver()
outdated         level  9   (Layer 4)  ← also analysis, build_execute, build_install, build_review
build_cmd        level 10   (Layer 4)  ← also query
commands         level 11   (Layer 4 hub)
main             level 12   (Layer 5)
```

### How depth moved from 10 to 12

These numbers come from computing the longest import chain at every commit since status10:

| Commit | Depth | Cause |
|---|---:|---|
| `a11536a` status10 | 10 | `color → provider → utils → git → devel → registry → build_context → outdated → query → commands → main` |
| `f145574` Build every plan from one solver setup | 12 | `BuildContext.newSolver()` makes `build_context` import `solver`. Every command that takes a `*BuildContext` now sits above the whole solver. |
| `a00f26e` Use the program's Io for all I/O | 14 | `alpm.zig` imports `utils.zig` for `currentIo()`. `utils` still imported `provider` and `color`, so both landed under the entire domain chain. |
| `4381a90` Phase 10a | 13 | `utils` stops importing `provider`. |
| `9c379ad` Phase 10c | 12 | `utils` stops importing `color` and becomes a leaf. |

Below `registry` the chain changed shape but not length: `registry` is at level 5 both in status10 (`color → provider → utils → git → devel → registry`) and now (`utils → alpm → version → dep_spec → pacman → registry`).

**The remaining +2 levels all come from `build_context → solver`.** Removing that single import gives depth 10, verified by recomputing on a copy with the import deleted.

---

## Phase 10: Decouple core modules from the terminal ✅ COMPLETE

**Commits:** `4381a90`, `0e46848`, `9c379ad`, `f3e3bd7`

**Goal:** stop core modules from depending on terminal styling or prompts.
- Groundwork for a possible second frontend: a pacman+AUR tool built from the same core, in the same repository.
- Worth doing for its own sake: the core becomes easier to test and its layering clearer.
- Deliberately not a full library or transaction API.

| Commit | Change |
|---|---|
| `4381a90` | `provider.ProviderChooser` is a context pointer + function, replacing a function pointer that took a `color.Style`. `registry.zig` no longer imports `color`. |
| `0e46848` | New `report.zig`: a `Reporter` takes a level (`info`, `warning`, `err`, `output`) and an uncoloured message. `chroot.prepare` reports through it instead of formatting `error:`/`::` prefixes and colours itself. `repo.zig` routes repo-add's stderr through it instead of calling `std.debug.print`. `commands/types.stderrReporter` reproduces the previous output exactly. |
| `9c379ad` | Confirmation and provider prompts move from `utils.zig` to the new `term.zig`. `utils.zig` no longer imports `color` or `provider`. |
| `f3e3bd7` | `zig fmt` for Zig 0.17 (`@intFromEnum` → `@backingInt`, `@enumFromInt` → `@fromBackingInt`). No behaviour change. |

### Metric shifts (pre-cleanup → status11)

| Metric | pre-cleanup | status11 | Change |
|---|---|---|---|
| Quality signal | 6480 | 6591 | +111 (+1.7%) |
| Depth | 14 | 12 | −2 levels |
| Depth score | 3636 | 4000 | +364 |
| Propagation cost | 23.26% | 20.94% | −2.32pp |
| Import edges | 201 | 206 | +5 (new `report`, `term`) |
| Redundancy | 0.033 | 0.040 | +0.007 (moved prompt code) |

---

## Test coverage

Sentrux reports 24 / 89 files tested (27%). It matches source files to separate test files, but most of aurodle's tests are inline `test` blocks or live in sibling `tests.zig` files, so the figure understates real coverage.

| Status | Files |
|---|---|
| **Well tested** | `solver` (+ `graph`, `topo`, `conflicts` via `solver/tests.zig`), `registry`, `repo`, `aur`, `git`, `pacman`, `makepkg`, `chroot`, `devel`, `auth`, `utils`, `alpm`, `dep_spec`, `version`, `report`, `term`, `main` (argument parsing) |
| **Partially tested** | `commands/build_cmd`, `build_execute`, `build_install`, `query`, `types`, `build_context` (pure helpers only) |
| **No tests** | `commands/outdated` (232), `commands/display` (470), `commands/status` (161), `commands/analysis` (112), `commands/build_review` (144) |
| **No tests needed** | `provider`, `source`, `plan` (type definitions only) |

`zig build test`: 460 / 462 pass. The single failing test, counted once per test binary, is `pacman.test.installed-package fast path agrees with alpm_find_satisfier`. It compares against the host's live pacman database and failed before Phase 10 as well.

---

## Git activity since status10

73 commits, single author (sentrux reports `single_author_ratio` 1.0, so bus-factor figures are not meaningful). Most-changed source files:

| File | Commits | Lines now |
|---|---:|---:|
| `commands/build_cmd.zig` | 16 | 629 |
| `commands/build_execute.zig` | 15 | 556 |
| `main.zig` | 13 | 819 |
| `pacman.zig` | 12 | 941 |
| `commands/build_install.zig` | 9 | 247 |
| `utils.zig` | 8 | 327 |
| `commands/types.zig` | 8 | 287 |

The hotspots are the build pipeline and `pacman.zig`. These files change the most, are among the largest, and (for the commands) are only partially tested.

---

## What is stable and well-structured

- **Zero dependency cycles.** All 206 import edges are below the diagonal and there are no same-level edges.
- **Perfect acyclicity score** (10000), held since status10.
- **Propagation cost at 20.94%**, the lowest so far.
- **Core/frontend boundary in place:** Layers 0–3 import neither `color` nor `term`.
- **`solver/`** remains a deep-module family, isolated via `SolverImpl(RegistryT)`.
- **`plan.zig`** remains a thin types module.
- **`commands.zig`** remains a pure router, as designed in `docs/architecture/class_commands.md`.
- **Test files stay wired through `root.zig`**, so tests add no cycles.

---

## Minor structural observations

- **`pacman.zig → repo.zig`** exists only for the `DEFAULT_REPO_NAME` constant. It puts `repo`, `makepkg`, `repo_conf` and `report` under `pacman`. It is not on the critical path today.
- **`devel.zig → git/test_repo.zig`** is a file-level import used only by `devel.zig`'s tests. Zig only compiles it for tests, but sentrux counts it as a production edge.
- **`commands/types.zig → term.zig`.** `filterIgnored` prompts the user, so the shared types file depends on the prompt module.

---

## Recommended next steps

### Immediate (Low Effort)

1. **Phase 11: Test `commands/outdated.zig`.** `collectOutdated` contains real decision logic: version comparison, the ignore flag, and devel version hints. It has no tests, it is shared by `outdated` and `upgrade`, and the mocks in `registry/mocks.zig` and `pacman/mocks.zig` already exist.
2. **Point `pacman.zig` at `repo_conf.zig` for `DEFAULT_REPO_NAME`.** Move the constant next to the repo-name derivation; `pacman.zig` then no longer depends on the whole of `repo.zig`.

### Medium Term

3. **Depth: decide where solver setup lives.** Moving `newSolver()` out of `BuildContext` restores depth 10. But `f145574` put it there on purpose, so that every plan-building command uses one solver setup. Options:
   - a `Solver.Options` struct in `solver.zig`, filled in at the three call sites (`analysis` ×2, `build_cmd`);
   - a small `commands/` helper file that both callers import.

   Either keeps one setup and drops `build_context → solver`.
4. **Test the pure logic in `commands/display.zig`.** Column widths, size formatting and version-hint selection are pure functions; the printing itself is not worth testing.
5. **Evaluate `pacman.zig` split** (941 lines). Status10's suggestion (`pacman/query.zig`, `pacman/installed.zig`) is more pressing now.

### Long Term / Monitor

6. **Keep acyclicity at 0.** New test files are imported from `root.zig`, never from their parent module.
7. **Keep Layers 0–3 free of `color` and `term`.** New core messages go through `report.Reporter`, new decisions through values or callbacks.
8. **Second frontend.** A pacman+AUR frontend in this repository could become a second executable sharing the core. If it does, extract the build pipeline into a step API driven by both callers, rather than designing it ahead of time.

---

## Appendix: Sentrux raw data

```
Scanned:            2026-11-13, sentrux 0.3.12, commit f3e3bd7
Files:              126
Import edges:       206
Lines:              34,998
Quality signal:     0.6591

Root causes:
  Acyclicity:       1.000  (raw 0)
  Modularity:       0.131  (score 4207)
  Depth:            12     (score 4000)  → BOTTLENECK
  Equality:         0.230  (score 7705)
  Redundancy:       0.040  (score 9595)

Coverage:
  Source files:     89
  Test files:       37
  Tested:           24 / 89 (27.0%)

DSM:
  Size:             55
  Above diagonal:   0      (no cycles)
  Below diagonal:   206
  Same level:       0
  Clusters:         0
  Density:          6.94%
  Propagation cost: 20.94%
  Level breaks:     12

Git (90 days):
  Commits analysed:   73
  Files with churn:   62
  Hotspots:           30
  Coupling pairs:     31
  Single-author ratio: 1.0

Reference scans (same tool version):
  status10  a11536a: QS 0.6747, depth 10, propagation 21.43%, 120 files, 176 edges, 32,660 lines
  pre-10    63e0350: QS 0.6480, depth 14, propagation 23.26%, 124 files, 201 edges, 34,882 lines
```
