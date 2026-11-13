# Aurodle — Architecture Status 12

> Reflects the codebase at `66c8547` (2026-11-13): 8 commits after status11,
> covering Phases 11–15 and one display bug fix.
> Supersedes `ARCHITECTURE_status11.md`.

**Module dependency graph:** [`docs/architecture_status/module-graph_status12.md`](module-graph_status12.md)

---

## Sentrux health metrics

### Current scan (post-Phase 15)

| Dimension | status10 | status11 | status12 | Assessment |
|---|---|---|---|---|
| **Quality Signal** | 0.6747 | 0.6591 | 0.6767 | ↑ +2.7% since status11; highest yet |
| **Bottleneck** | Modularity | Depth | Modularity | Depth fixed; modularity is back as the weakest score |
| **Acyclicity** | 1.000 (0 inversions) | 1.000 | 1.000 | → Still perfect |
| **Depth** | 10 levels | 12 levels | 10 levels | ↓ Back to status10 |
| **Modularity** | 0.136 | 0.131 | 0.139 | ↑ Highest yet (`src/pacman/` became a real module) |
| **File Size Equality** | 0.224 (7760) | 0.230 (7705) | 0.220 (7803) | ↑ `pacman.zig` split evened out file sizes |
| **Redundancy** | 0.045 | 0.040 | 0.040 | → Stable |
| **Cross-Module Edges** | 131 / 176 (74%) | 158 / 206 (77%) | 160 / 211 (76%) | → Stable |
| **Test Coverage (sentrux)** | 22 / 78 (28.2%) | 24 / 89 (27.0%) | 26 / 93 (28.0%) | → Still misleading, see [Test coverage](#test-coverage) |
| **Propagation Cost** | 21.43% | 20.94% | 19.52% | ↓ −1.42pp |

130 files · 211 import edges · ~36,055 total lines · DSM propagation cost 19.52%

**Summary:**
- **Depth is back to 10.** The solver is now configured through `SolverOptions` (Phase 13), so `commands/build_context.zig` no longer imports `solver.zig`. That removed the two levels status11 traced to that one import.
- **The quality signal (6767) is now above status10 (6747)** for the first time since that round.
- **Modularity is the bottleneck again.** As in status10, this reflects the flat `src/` layout more than tangled code. The one place where structure actually helped is the `pacman.zig` split (Phase 15), which made `src/pacman/` a real module and raised modularity to its best value yet.

### How the scans were taken

Every number above comes from a fresh `scan` of a clean checkout (`git worktree`, no build cache) with sentrux 0.3.12. The status11 baseline reproduces exactly that way.

Two measurement notes from this round:
- **Use `scan`, not `rescan`.** After Phase 15, the incremental `rescan` missed the two new files: it reported 207 edges and a quality signal of 0.6727. A fresh scan gives 211 edges and 0.6762.
- **Sentrux counts Markdown files.** The status11 docs alone moved the file count from 126 to 128 without any code change. File counts are not a code-size measure.

---

## Phase-by-phase metrics

| Commit | Phase | QS | Depth | Modularity | Propagation | Edges |
|---|---|---:|---:|---:|---:|---:|
| `f3e3bd7` | status11 baseline | 6591 | 12 | 0.131 | 20.94% | 206 |
| `da8abee` | 11–12: `outdated` tests, `pacman → repo_conf` | 6591 | 12 | 0.129 | 20.13% | 207 |
| `05d054a` | 13: `SolverOptions` | 6734 | 10 | 0.130 | 19.33% | 206 |
| `1101989` | 14: display helpers + tests | 6738 | 10 | 0.128 | 19.33% | 207 |
| `07b7570` | 15: `pacman.zig` split | 6762 | 10 | 0.139 | 19.52% | 211 |
| `66c8547` | `fmtSize` unit fix | 6767 | 10 | 0.139 | 19.52% | 211 |

What moved the numbers:
- **Phase 13 is the depth change**, and with it most of the quality-signal gain.
- **Phase 15 is the modularity change**, plus a better file-size equality score.
- **Phases 11–12 and 14 were about correctness and tests**, and were close to neutral on the metrics.

---

## Source layout (changed files)

The rest of the tree is as in `ARCHITECTURE_status11.md`.

```
src/
├── plan.zig                 103 lines   + SolverOptions (rebuild, needed, ignore)
├── pacman.zig               671 lines   Façade: init, installed/sync queries, satisfaction, foreign pkgs
├── pacman/
│   ├── provides.zig         134 lines   NEW  ProvidesIndex + per-database provider scans
│   ├── repo_deps.zig        167 lines   NEW  Transitive repo-dep walks, SyncProviderChoice
│   ├── mocks.zig            110 lines   Test doubles for the repo-dep walks
│   └── tests.zig            245 lines   Pacman integration tests + mock-based walk tests
├── commands/
│   ├── types.zig            307 lines   + Flags.solverOptions()
│   ├── build_context.zig     63 lines   − newSolver(), − solver import
│   ├── outdated.zig         494 lines   + filterByName, compareWithAur, vcsPkgbases, mergeDevelVersion
│   └── display.zig          592 lines   + gap, aurRowCount; printSize reuses fmtSize
└── root.zig                  48 lines   + test discovery for commands/outdated.zig, commands/display.zig
```

### Production size

Status11 sorted files into size tiers by total lines, which counts inline tests as size. The table below counts only production code, meaning the lines before a file's first test. It lists every production file above 400 lines:

| File | Production | Total | Note |
|---|---:|---:|---|
| `repo.zig` | 671 | 671 | **Only production file above the 600-line trigger** |
| `solver.zig` | 587 | 587 | Tests in `solver/tests.zig` |
| `commands/build_cmd.zig` | 551 | 629 | |
| `pacman.zig` | 543 | 671 | Was 941 total before Phase 15 |
| `registry.zig` | 526 | 526 | Tests in `registry/tests.zig` |
| `main.zig` | 520 | 819 | CLI parsing tests inline |
| `commands/build_execute.zig` | 490 | 556 | |
| `commands/display.zig` | 480 | 592 | |
| `chroot.zig` | 419 | 581 | |
| `aur.zig` | 418 | 418 | Tests in `aur/tests.zig` |

---

## Layers

Same as status11, with the two new files in Layer 2 under `pacman.zig`, in the same façade + sub-modules shape as `solver/`.

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
│  Layer 2 · Domain        pacman.zig (façade)                     │
│                          pacman/{provides, repo_deps}            │
│                          devel.zig  dep_spec.zig                 │
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

**Core vs frontend.** Unchanged from status11: Layers 0–3 import neither `color.zig` nor `term.zig`.

---

## Depth chain (10 levels)

Two chains now tie for the longest path:

```
utils            level  0   (Layer 0 — leaf)
alpm             level  1   (Layer 1)
version          level  2   (Layer 1)
dep_spec         level  3   (Layer 2)
pacman           level  4   (Layer 2)
registry         level  5   (Layer 3)
solver/conflicts level  6   (Layer 3)       build_context  level 6   (Layer 4)
solver           level  7   (Layer 3)       outdated       level 7   (Layer 4)
analysis         level  8   (Layer 4)       query          level 8   (Layer 4)
commands         level  9   (Layer 4 hub)
main             level 10   (Layer 5)
```

- **Left chain:** the resolver path, `registry → solver/conflicts → solver → analysis`. `commands/build_cmd.zig` is also at level 8, since it imports `solver` directly.
- **Right chain:** the command contexts, `registry → build_context → outdated → query`. `build_context` dropped from level 8 to level 6 once it stopped importing `solver`.

Any import that puts a command context above the solver again would bring back the status11 depth. Examples: `build_context` importing `solver`, or `types` importing anything at Layer 3.

---

## Phase 11: Test `commands/outdated.zig` ✅ COMPLETE

**Commits:** `e9a3574`, `40f6f1a`

`collectOutdated` decides what `upgrade` rebuilds, but it read the live pacman database and the AUR directly through `BuildContext`, so it couldn't be tested. Its decisions are now four functions that take plain data:

| Function | Decides |
|---|---|
| `filterByName` | which foreign packages the command-line targets select |
| `compareWithAur` | which packages are outdated, ignored, or unknown to the AUR |
| `vcsPkgbases` | which pkgbases need a VCS check (split packages share one) |
| `mergeDevelVersion` | whether a `--devel` version refines an existing entry or adds a new one |

`collectOutdated` and `checkDevelPackages` keep the fetching and the printing.

There are 11 tests covering:
- `pkgrel` bumps and epochs;
- packages the AUR doesn't know, and ignored packages;
- split VCS packages;
- both `--devel` merge paths.

A deliberately broken comparison (`< 0` → `<= 0`) fails two of them.

---

## Phase 12: `pacman.zig` imports `repo_conf.zig`, not `repo.zig` ✅ COMPLETE

**Commit:** `da8abee`

`pacman.zig` and `pacman/tests.zig` imported all of `repo.zig`, and through it `makepkg` and `report`, only for `DEFAULT_REPO_NAME`, which `repo_conf.zig` defines. Both files now import `repo_conf.zig`.

---

## Phase 13: Configure the solver at `init` ✅ COMPLETE

**Commit:** `05d054a`

| Before | After |
|---|---|
| `BuildContext.newSolver()` called `Solver.init(allocator, registry)`, then set `rebuild`, `needed`, `ignore` | `Solver.init(allocator, registry, options)` |
| Solver settings were three loose fields | `plan.SolverOptions`, held as one `options` field |
| Flags → settings mapping lived in `BuildContext` | `Flags.solverOptions()` in `commands/types.zig` |
| `build_context.zig → solver.zig` | Edge removed |

- **One mapping point is kept.** Every command that shows or builds a plan still gets its solver settings from the same function, as `f145574` intended.
- **No import edges were added.** `SolverOptions` lives in `plan.zig`, which both `solver.zig` and `commands/types.zig` already imported.
- **Callers and tests:** `clone --recurse` passes `.{}`, as before. The 66 test constructions in `solver/tests.zig` pass their options to `init`.

**Effect:** depth 12 → 10 and quality signal 6591 → 6734. This phase was the largest single metric gain of the round.

---

## Phase 14: Test the plan display helpers ✅ COMPLETE

**Commits:** `b42a242`, `1101989`, `66c8547`

Three small preparatory changes, plus tests:
- `pad` and `rightAlign` share the new pure `gap()` function.
- `printSize` formats through `fmtSize` instead of duplicating it.
- Both plan views count AUR rows with `aurRowCount`.

Before committing, I compared real `resolve` output from the old and new binaries in five cases (sizes, `Old Version` column, VCS packages, totals). It was byte-for-byte identical.

There are 14 tests covering:
- size formatting;
- digit counting;
- the two-space column gutter;
- version selection (`--devel` hint, `latest` for VCS packages, plan version);
- AUR row counting for split packages;
- column widths.

**A bug the tests surfaced** (`66c8547`): `fmtSize` picked the unit before rounding, so 1023.995 KiB and up printed as `1024.00 KiB` instead of `1.00 MiB`. It also overflowed on the most negative `i64`. Both are fixed, and both new tests fail against the old code.

---

## Phase 15: Split `pacman.zig` ✅ COMPLETE

**Commit:** `07b7570`

| File | Lines | Contents | Imports |
|---|---:|---|---|
| `pacman.zig` | 941 → 671 | Façade: init, installed/sync queries, satisfaction, conflicts, foreign packages | |
| `pacman/provides.zig` | 134 | `ProvidesIndex` and the per-database provider scans | `alpm`, `provider` |
| `pacman/repo_deps.zig` | 167 | `transitiveRepoDeps`, `findTransitiveProviderChoices`, `SyncProviderChoice` | `provider` |

- **No cycle.** Neither new file imports `pacman.zig`. The repo-dep walks were already generic over the pacman they query (`pm: anytype`, mocked in `pacman/mocks.zig`), so they moved without changes.
- **Interface kept.** `Pacman` exposes the walks as method aliases, so callers are unchanged. The three lookups the walks use (`findInOfficialDbs`, `findSyncPkgForDep`, `findAllOfficialProviders`) became `pub`.
- **Effect:** modularity 0.128 → 0.139, file-size equality score 7773 → 7803, quality signal 6738 → 6762.

**Not verified end to end.** `sync`/`build` were not run against the old binary, because that run needs permission to invoke commands that can install packages. The walks are covered by their 4 mock-based tests.

---

## Test coverage

`zig build test`: **486 / 488** pass, up from 460 / 462 at status11. The single failing test, counted once per test binary, is still `pacman.test.installed-package fast path agrees with alpm_find_satisfier`. It depends on the host's live pacman database.

| Status | Files |
|---|---|
| **Well tested** | `solver` (+ sub-modules), `registry`, `repo`, `aur`, `git`, `pacman` (+ repo-dep walks via mocks), `makepkg`, `chroot`, `devel`, `auth`, `utils`, `alpm`, `dep_spec`, `version`, `report`, `term`, `main` (argument parsing), **`commands/outdated`** (decision logic), **`commands/display`** (pure helpers) |
| **Partially tested** | `commands/build_cmd`, `build_execute`, `build_install`, `query`, `types` |
| **No tests** | `commands/status` (161), `commands/analysis` (112), `commands/build_review` (144). All three are mostly I/O and prompts. |
| **No tests needed** | `provider`, `source`, `plan` (type definitions), `pacman/provides` (exercised through `pacman.zig`'s index-vs-scan test) |

Sentrux's 28% still reflects how the tool detects tests, not real coverage: the 25 new tests are inline `test` blocks, which it does not count.

---

## What is stable and well-structured

- **Zero dependency cycles.** All 211 import edges are below the diagonal and there are no same-level edges.
- **Perfect acyclicity score** (10000), held since status10.
- **Depth 10**, matching status10.
- **Propagation cost 19.52%**, below 20% for the first time.
- **Core/frontend boundary:** Layers 0–3 import neither `color` nor `term`.
- **Façade + sub-module families:** `solver/` and now `pacman/`, both free of cycles.
- **Solver setup:** solvers are configured at construction, with one mapping point from flags.
- **Testable decisions:** outdated detection and plan display have their decision logic separated from I/O and tested.

---

## Minor structural observations

Still open from status11:
- **`devel.zig → git/test_repo.zig`** is a file-level import used only by `devel.zig`'s tests. Sentrux counts it as a production edge.
- **`commands/types.zig → term.zig`.** `filterIgnored` prompts the user, so the shared types file depends on the prompt module.

New:
- **Visible `pub` lookups.** `Pacman.findInOfficialDbs`, `findSyncPkgForDep` and `findAllOfficialProviders` are `pub` now so `pacman/repo_deps.zig` can call them. They are honest queries, but they widen `Pacman`'s visible interface.

---

## Recommended next steps

### Immediate (Low Effort)

1. **Nothing urgent.** Every status11 recommendation is done or deliberately deferred.

### Medium Term

2. **Look at `repo.zig` when next touching it.** At 671 production lines, it is the only file above the split trigger. It mixes repository setup, repo-add, package listing and clean planning. Split it when a feature lands there, not as a standalone refactor.
3. **Move `filterIgnored` out of `commands/types.zig`.** It prompts the user. Its callers are `analysis` (resolve, buildorder) and `build_cmd` (sync, build), so it would go in a small `commands/targets.zig` that both import. That would drop `types → term`.

### Long Term / Monitor

4. **Keep the command contexts below the solver.** `build_context`, `query_context` and `types` should not import Layer 3 orchestration (`solver`). New plan settings go into `SolverOptions` and `Flags.solverOptions()`.
5. **Keep acyclicity at 0.** New test files are imported from `root.zig`. New sub-modules (like `pacman/*`) must not import their façade.
6. **Keep Layers 0–3 free of `color` and `term`.**
7. **Don't chase modularity.** It is the bottleneck again, but mostly because of the flat `src/` layout. Group files into directories only when a real façade + sub-module family appears, as `pacman/` did.
8. **Measure with a fresh `scan` of a clean checkout**, as in this round, so the numbers stay comparable.
9. **Second frontend.** If a pacman+AUR frontend is started in this repository, extract the build pipeline into a step API driven by both callers at that point. Phases 11 and 14 already moved decision logic into plain functions, in the direction that API would need.

---

## Appendix: Sentrux raw data

```
Scanned:            2026-11-13, sentrux 0.3.12, clean checkout of 66c8547
Files:              130
Import edges:       211
Lines:              36,055
Quality signal:     0.6767

Root causes:
  Acyclicity:       1.000  (raw 0)
  Modularity:       0.139  (score 4261)  → BOTTLENECK
  Depth:            10     (score 4444)
  Equality:         0.220  (score 7803)
  Redundancy:       0.040  (score 9604)

Coverage:
  Source files:     93
  Test files:       37
  Tested:           26 / 93 (28.0%)

DSM:
  Size:             57
  Above diagonal:   0      (no cycles)
  Below diagonal:   211
  Same level:       0
  Clusters:         0
  Density:          6.61%
  Propagation cost: 19.52%
  Level breaks:     10

Git (90 days):
  Commits analysed:   82
  Files with churn:   66
  Hotspots:           30
  Coupling pairs:     34
  Single-author ratio: 1.0

Phase scans (same method):
  f3e3bd7  QS 0.6591  depth 12  mod 0.131  prop 20.94%  126 files  206 edges
  da8abee  QS 0.6591  depth 12  mod 0.129  prop 20.13%  128 files  207 edges
  05d054a  QS 0.6734  depth 10  mod 0.130  prop 19.33%  128 files  206 edges
  1101989  QS 0.6738  depth 10  mod 0.128  prop 19.33%  128 files  207 edges
  07b7570  QS 0.6762  depth 10  mod 0.139  prop 19.52%  130 files  211 edges
  66c8547  QS 0.6767  depth 10  mod 0.139  prop 19.52%  130 files  211 edges
```
