# Aurodle — Architecture Status 13

> Reflects `main` at `deafaaf` (2026-11-15): 30 commits after status12, 18 of them touching `src/` or `build.zig`.
> They cover build-order and solver fixes, `outdated`/`upgrade --all`, the split into `core`/`ui`/`commands` modules, and the second frontend, `pacsaur`.
> Supersedes `ARCHITECTURE_status12.md`.

**Module dependency graph:** [`docs/architecture_status/module-graph_status13.md`](module-graph_status13.md)

---

## Measurement: sentrux does not see named-module imports

This round needs a caveat before any number. **Sentrux's raw scan of `main` reports a quality signal of 8171, up 21% from 6767, and most of that jump is a measurement artifact.**

`3c5e0e1` moved the sources into Zig modules that are declared in `build.zig` and imported by name: `@import("core")`, `@import("ui")` and `@import("commands")`. Sentrux resolves only path imports (`@import("x.zig")`), so every cross-module dependency became invisible to it. That one commit, with no change in what depends on what, gives this before/after:

| `3c5e0e1` | Edges | Depth | Modularity | Propagation | QS |
|---|---:|---:|---:|---:|---:|
| Parent (`d2a5895`) | 213 | 10 | 0.141 | 19.64% | 6765 |
| Raw sentrux scan | 143 | 5 | 0.355 | 8.59% | 7648 |
| Resolved graph | 230 | 10 | 0.169 | 18.73% | 6823 |

**How the resolved numbers were taken.** A script resolves both import styles to the file they reach: `@import("core").pacman`, and `core.pacman` through `const core = @import("core")`. Each module's `root.zig` lists the files it re-exports. The script then writes a copy of the tree where those imports are replaced by relative-path imports, and sentrux scans that copy. Every other file and line is unchanged.

Checks on the method:
- **The tool is not the cause.** Sentrux 0.5.7 reproduces status12 exactly on a clean checkout of `66c8547`: 6767, 211 edges, depth 10.
- **The resolved scan of `3c5e0e1` matches its parent** on depth (10), level breaks (10), acyclicity and equality. The 17 extra edges are the module roots' re-export lines.
- **Modularity still rises somewhat** with the split (0.141 → 0.169) because sentrux treats directories as modules. That part is real: the `core`/`ui` boundaries now hold more of the edges.

All status13 numbers below are from the resolved graph unless marked *raw*. The raw scan is kept in the appendix only for reference.

The script was a one-off and is not kept. The status rounds track trends, not exact values, so from status14 on they compare raw scans with this round's raw numbers. See [Recommended next steps](#recommended-next-steps).

---

## Sentrux health metrics

| Dimension | status11 | status12 | status13 | status13 *raw* | Assessment |
|---|---|---|---|---|---|
| **Quality Signal** | 0.6591 | 0.6767 | **0.6912** | 0.8171 | ↑ +2.1% since status12; highest yet |
| **Bottleneck** | Depth | Modularity | Modularity | Modularity | → |
| **Acyclicity** | 1.000 | 1.000 | 1.000 (0 inversions) | 1.000 | → Still perfect |
| **Depth** | 12 levels | 10 levels | **9 levels** | 2 | ↓ Router level removed |
| **Modularity** | 0.131 | 0.139 | **0.186** | 0.431 | ↑ Directories now match the `core`/`ui`/`commands` modules |
| **File Size Equality** | 0.230 (7705) | 0.220 (7803) | 0.237 (7628) | 0.237 | ↓ `pacsaur/args`, `route` and four 600-line files |
| **Redundancy** | 0.040 | 0.040 | 0.039 | 0.039 | → Stable |
| **Cross-Module Edges** | 158 / 206 (77%) | 160 / 211 (76%) | 150 / 260 (58%) | 38 / 148 | ↓ More edges stay inside one directory |
| **Test Coverage (sentrux)** | 24 / 89 (27.0%) | 26 / 93 (28.0%) | 26 / 104 (25.0%) | 26 / 106 (24.5%) | Still misleading, see [Test coverage](#test-coverage) |
| **Propagation Cost** | 20.94% | 19.52% | **18.48%** | 7.40% | ↓ −1.04pp |

Resolved graph: 141 files · 260 import edges · DSM size 64 · propagation cost 18.48%

**Summary:**
- **The real quality signal is 6912**, the highest yet but a modest gain (+145). The structure improved, but nowhere near what the raw 8171 suggests.
- **Depth is 9.** Both frontends import the command files directly, so the 14-line `commands.zig` router level is gone. Adding `pacsaur` added no depth.
- **Modularity is still the bottleneck**, now at its best value (0.186). The source tree finally has directories that are real modules, enforced by the compiler.
- **Equality dipped** (7803 → 7628). Four production files now sit at or above the 600-line trigger. See [Production size](#production-size).

---

## Commit-by-commit metrics (resolved graph)

| Commit | Change | QS | Depth | Modularity | Propagation | Edges |
|---|---|---:|---:|---:|---:|---:|
| `66c8547` | status12 baseline | 6767 | 10 | 0.139 | 19.52% | 211 |
| `d2a5895` | Solver, build-order and `outdated --all` work | 6765 | 10 | 0.141 | 19.64% | 213 |
| `3c5e0e1` | Split into `core`, `ui`, `aurodle` modules | 6823 | 10 | 0.169 | 18.73% | 230 |
| `a5ac398` | Remove pacman-style aliases | 6824 | 10 | 0.169 | 18.73% | 230 |
| `0f247e4` | Shared `commands` module + `Stack` | 6931 | 9 | 0.183 | 18.87% | 239 |
| `6e935bf` | Add `pacsaur` | 6919 | 9 | 0.186 | 18.48% | 260 |
| `deafaaf` | `-Su` routing fix, docs | 6912 | 9 | 0.186 | 18.48% | 260 |

What moved the numbers:
- **The 20 commits up to `d2a5895` were neutral** (6767 → 6765), despite real behaviour changes: stale-dependency warnings, local-repo depends, pkgbase build units, and `--all`.
- **`3c5e0e1` is the modularity change.** It moved files into directories that match the modules.
- **`0f247e4` is the depth change.** The commands moved into a module that both frontends import, and `main` lost its router.
- **`pacsaur` added 21 edges and 4 files** with a near-neutral signal (−12, from file-size equality), at the same depth.

---

## Source layout

```
src/
├── core/                    no terminal I/O; reports through report.Reporter
│   ├── root.zig              36   re-exports 20 files + test discovery
│   ├── alpm.zig             556   + Database.hasGroup
│   ├── auth.zig             504   + cachesCredentials
│   ├── pacman.zig           741   + isOfficialGroup, aurRepoDepends, uninstalledAurRepoPackages
│   ├── plan.zig             118   − DependencyEntry.depth, + stale_repo_deps
│   ├── solver.zig           602   local-repo depends, stale-dep check, no depth tracking
│   ├── solver/topo.zig      169   + postOrder over build units, checkBuildCycles
│   └── …                          otherwise unchanged, moved from src/
├── ui/                      imports core only
│   ├── root.zig              13
│   ├── color.zig             86   moved from src/
│   ├── term.zig             123   moved from src/
│   ├── display.zig          605   moved from src/commands/; no commands import
│   └── output.zig            78   NEW  StdWriter, ErrWriter, stderrReporter
├── commands/                imports core + ui; the AUR commands for both frontends
│   ├── root.zig              19   re-exports 8 files + test discovery
│   ├── stack.zig            161   NEW  Stack: repo, libalpm, registry, auth
│   ├── types.zig            246   − writers (moved to ui/output)
│   ├── analysis.zig         204   + writeBuildOrder, buildorder --quiet
│   ├── build_cmd.zig        676   + systemUpgrade, no-install targets
│   ├── outdated.zig         521   + --all: uninstalled local-repo packages
│   └── …                          query, query_context, build_context, build_{execute,install,review}, status
├── aurodle/
│   └── main.zig             668   CLI parsing + help; repository setup moved to commands/stack
└── pacsaur/                 NEW executable
    ├── main.zig             267   runs steps: pacman (child process), then AUR commands (in-process)
    ├── args.zig             554   pacman-style argv → Invocation (no imports besides std)
    ├── route.zig            546   Invocation → Plan; the only routing policy
    └── classify.zig          65   official vs AUR target, from the sync databases
```

`build.zig` wires `core` (with `alpm_c`), `ui` (with `core`), `commands` (with `core`, `ui`) and the two executables (with all three). It builds one test binary per module and per executable.

### Production size

Production lines are the lines before a file's first `test` block, as in status12. This table lists every production file above 350 lines:

| File | Production | Total | status12 production | Note |
|---|---:|---:|---:|---|
| `core/repo.zig` | 671 | 671 | 671 | Unchanged; above the 600-line trigger |
| `core/pacman.zig` | 619 | 741 | 543 | **Crossed 600:** `isOfficialGroup`, `aurRepoDepends`, `uninstalledAurRepoPackages` |
| `commands/build_cmd.zig` | 602 | 676 | 551 | **Crossed 600:** `systemUpgrade`, no-install targets |
| `core/solver.zig` | 602 | 602 | 587 | **At 600:** local-repo depends, stale-dep check |
| `core/registry.zig` | 539 | 539 | 526 | |
| `ui/display.zig` | 506 | 605 | 480 | |
| `commands/build_execute.zig` | 502 | 557 | 490 | |
| `aurodle/main.zig` | 424 | 668 | 520 | Lost repository setup to `stack` |
| `core/chroot.zig` | 423 | 581 | 419 | |
| `core/aur.zig` | 418 | 418 | 418 | |
| `pacsaur/args.zig` | 401 | 554 | — | New |
| `pacsaur/route.zig` | 360 | 546 | — | New |
| `commands/query.zig` | 357 | 440 | — | |

---

## Layers

The layers are now backed by modules. A file can import a module only if `build.zig` gives it that import, so a wrong-way import is a **compile error**, not just a convention.

```
┌──────────────────────────────────────────────────────────────────────┐
│  Frontends          aurodle/main.zig        pacsaur/{main, route,     │
│  (executables)                              args, classify}          │
├──────────────────────────────────────────────────────────────────────┤
│  commands module    stack · types · query_context · build_context    │
│  (AUR commands,     query · outdated · analysis · status             │
│   shared)           build_cmd · build_{execute, install, review}     │
├──────────────────────────────────────────────────────────────────────┤
│  ui module          color · output · term · display                  │
├──────────────────────────────────────────────────────────────────────┤
│  core module                                                         │
│   Layer 3 · Resolution   solver (+ graph, topo, conflicts) · registry│
│   Layer 2 · Domain       pacman (+ provides, repo_deps) · devel      │
│                          dep_spec                                    │
│   Layer 1 · Infra        alpm · aur · git · auth · chroot · repo     │
│                          makepkg · repo_conf · pacman_conf           │
│                          version · plan                              │
│   Layer 0 · Primitives   utils · provider · source · report          │
└──────────────────────────────────────────────────────────────────────┘
```

Edges between modules on the resolved graph, production files only:

| From \ To | core | ui | commands | pacsaur |
|---|---:|---:|---:|---:|
| **core** | 53 | — | — | — |
| **ui** | 7 | 4 | — | — |
| **commands** | 50 | 28 | 24 | — |
| **aurodle** | 3 | 1 | 7 | — |
| **pacsaur** | 9 | 1 | 6 | 5 |

Every edge points down or sideways within a module. `core` imports nothing outside itself, `ui` imports only `core`, and neither frontend is imported by anything.

**Core vs frontend.** The status12 rule, "Layers 0–3 import neither `color` nor `term`", is now enforced by the compiler: `core` has no `ui` import. One leftover: `core/utils.zig` still owns the process-wide buffered stdout, which only `ui/output` and `ui/term` write to. It stays in `core` because `runCommandIn`, `runInteractive` and `parallelFor` flush it before spawning children or worker threads.

---

## Depth chain (9 levels)

```
utils            level 0   (core L0)
alpm             level 1   (core L1)
version          level 2   (core L1)
dep_spec         level 3   (core L2)
pacman           level 4   (core L2)
registry         level 5   (core L3)
solver/conflicts level 6   (core L3)      build_context  level 6   (commands)
solver           level 7   (core L3)      outdated, build_{execute,install,review}, stack  level 7
analysis         level 8   (commands)     build_cmd, query  level 8
aurodle/main     level 9   (frontend)     pacsaur/main  level 9
```

The `core` part of the chain (levels 0–7) is unchanged from status12. The frontends now import commands directly instead of through `commands.zig`, which removed one level. Both rules from status12 still hold:
- `build_context` and `query_context` sit below `solver`.
- `types` imports nothing from Layer 3.

---

## What changed

### Solver and build order

**Commits:** `3380513`, `2f23549`, `155980f`, `1807416`, `82f97b7`, `071feba`, `b898f0b`, `ec9a4e3`

| Change | Effect on structure |
|---|---|
| `all_deps` is a depth-first post-order walk (`topo.postOrder`), and `buildorder` prints it as is | `solver/topo` grew from 80 to 169 lines; depth tracking was removed from the solver and `plan` |
| Ordering works on build units (one pkgbase for built packages), so a split pkgbase builds after the deps of all its packages | Kahn's algorithm now only checks pkgbase-level cycles (`checkBuildCycles`) |
| Deps follow how a package is obtained: a built package walks its AUR deps, a local-repo package its repository depends, an installed one nothing | `pacman` gained `aurRepoDepends` |
| Dependencies taken from the local repo that are older than the AUR are recorded in `BuildPlan.stale_repo_deps` and warned about | One batched AUR request; the plan itself is unchanged |
| `writeBuildOrder` takes any writer and any pkgbase lookup; `--quiet` keeps only the packages that get built | Made `buildorder` output testable; added `analysis → source` |

None of these changed the import graph beyond `analysis → source`. The quality signal stayed at 6765–6767 throughout.

### `outdated`/`upgrade --all`

**Commit:** `a43482e`

With `--all`, local-repo packages that are not installed are checked by their repository version. `upgrade` rebuilds them into the repository without installing them. The build pipeline now takes a set of targets it must not install.

### Split into modules

**Commits:** `3c5e0e1`, `0f247e4`

| Before | After |
|---|---|
| Flat `src/`, `src/commands/`, one `src/root.zig` | `core`, `ui`, `commands` modules + `aurodle`, `pacsaur` executables |
| `commands/display.zig` imported `commands/types` | `ui/display.zig`, which doesn't need `commands` |
| Writers in `commands/types.zig` | `ui/output.zig` (+ `stderrReporter` for core messages) |
| `main.zig` opened the repo, libalpm, registry and auth | `commands/stack.zig` (`Stack`), opened only for commands that need it, after any pacman step |
| `commands.zig` routed to the command files | Removed; frontends dispatch directly |
| Shared tests ran in several binaries | One test binary per module, so each test runs once |

This is the step status12 recommended for a second frontend ("Long Term" #9): the build and query pipeline became a module that both frontends drive.

### Command aliases removed

**Commit:** `a5ac398`

`aurodle` no longer accepts `-S`, `-Si`, `-Su` and the others. Pacman's syntax now belongs to `pacsaur` alone. This was neutral on the metrics.

### `pacsaur`

**Commits:** `6e935bf`, `e52708b`

| File | Role | Imports |
|---|---|---|
| `pacsaur/args.zig` | Records what the user said: pacman-style argv → `Invocation` | `std` only |
| `pacsaur/classify.zig` | Official vs AUR target, from the local sync databases | `core/pacman`, `makepkg`, `repo_conf` |
| `pacsaur/route.zig` | The only routing policy: `Invocation` → `Plan` of pacman and AUR steps | `args`, `classify`, `commands/types`, `core/aur` |
| `pacsaur/main.zig` | Runs the steps: pacman as a child process, then the AUR commands in-process | the above + `commands/*`, `core/*`, `ui/output` |

- **Parsing, policy and execution are separate files.** `args` imports nothing, and `route` decides without running anything. Both are tested directly (19 and 20 tests).
- **The `core` additions are small:** `Database.hasGroup`, `Pacman.isOfficialGroup` and `Auth.cachesCredentials`.
- **`e52708b`** added `build_cmd.systemUpgrade`, so `-Su` installs the AUR targets in the same plan as the upgrade, and `-Suw` builds without installing.

---

## Test coverage

`zig build test`: **476 / 476** pass, in five binaries:

| Binary | Tests |
|---|---:|
| `core` | 340 |
| `ui` | 22 |
| `commands` | 41 |
| `aurodle` | 33 |
| `pacsaur` | 40 |

This can't be compared with status12's 486 / 488: those totals counted shared tests once per binary that included them, and every test now runs once. `pacman.test.installed-package fast path agrees with alpm_find_satisfier` passed on this host. It still depends on the host's live pacman database.

| Status | Files |
|---|---|
| **Well tested** | `core/solver` (+ sub-modules), `registry`, `repo`, `aur`, `git`, `pacman`, `makepkg`, `chroot`, `devel`, `auth`, `utils`, `alpm`, `dep_spec`, `version`, `report`, `ui/term`, `ui/display`, `commands/outdated`, `aurodle/main` (argument parsing), **`pacsaur/args`**, **`pacsaur/route`**, **`commands/analysis`** (`writeBuildOrder`) |
| **Partially tested** | `commands/build_cmd`, `build_execute`, `build_install`, `query`, `types`, `stack` (`mergeIgnore` only) |
| **No tests** | `commands/status` (161), `commands/build_review` (144), **`pacsaur/classify`** (65). The first two are mostly I/O and prompts. `classify` reads the sync databases. |
| **No tests needed** | `provider`, `source`, `plan` (type definitions), `ui/output` (writers), `pacman/provides` |

Sentrux's 25% reflects how the tool detects tests, not real coverage. Inline `test` blocks are not counted.

---

## What is stable and well-structured

- **Zero dependency cycles.** All 260 resolved edges are below the diagonal, with no same-level edges.
- **Perfect acyclicity score** (10000), held since status10.
- **Depth 9**, the lowest since tracking began, with two frontends.
- **Propagation cost 18.48%**, the lowest yet.
- **Compiler-enforced boundaries:** `core` → nothing, `ui` → `core`, `commands` → `core` + `ui`.
- **Façade + sub-module families:** `solver/` and `pacman/`, both still free of cycles.
- **One pipeline, two frontends:** `pacsaur` runs the AUR commands in-process through `commands`, with no duplicated build logic.
- **`pacsaur` separates parsing, routing and execution**, and the first two are pure and tested.

---

## Minor structural observations

Closed:
- **Visible `pub` lookups on `Pacman`** (`findInOfficialDbs`, `findSyncPkgForDep`). `pacsaur/classify` now calls them too, so they are public API.
- **`commands/types.zig → ui/term.zig`** (`filterIgnored` prompts the user). This is within the rules: the `commands` module is allowed to prompt.

By design:
- **`core/devel.zig → core/git/test_repo.zig`** is imported only by `devel.zig`'s tests, so Zig compiles it into test builds only. Sentrux counts every `@import` in a file, wherever it sits, so it sees a production edge.
- **Buffered stdout lives in `core/utils`**, although only `ui` writes to it. `core` must flush it before spawning children or worker threads. See [Layers](#layers).

New:
- **Four files at or above 600 production lines:** `repo`, `pacman`, `build_cmd`, `solver`.
- **Sentrux is blind to named modules.** Raw scans miss every cross-module edge, so their depth, modularity and propagation are only comparable with other raw scans. See [Measurement](#measurement-sentrux-does-not-see-named-module-imports).

---

## Recommended next steps

### Immediate (Low Effort)

1. **Test `pacsaur/classify`.** It decides which side each target goes to, and the order of its checks matters: official name, local repo, group, provider. Make `source` take the pacman lookups as `anytype`, as `pacman/repo_deps` does, and test it with a small mock of those four methods.

### Medium Term

2. **Split the 600-line files when next touching them.** Natural seams:
   - `repo.zig`: the clean logic (`clean`, `cleanAll`, `cleanExecute`, `freeCleanResult`, about 220 lines) into `repo/clean.zig`.
   - `build_cmd.zig`: `clean`, which does not use the build pipeline. The upgrade paths go through `runBuildPipeline` and stay.
   - `pacman.zig`: the local-repo queries (`aurRepoPkgbase`, `aurRepoDepends`, `uninstalledAurpkgs`, `uninstalledAurRepoPackages`), as free functions over `anytype` like `repo_deps`.
   - `solver.zig`: none for now. The stale-dependency check is about 30 lines.

### Long Term / Monitor

3. **Keep `build_context`, `query_context`, `stack` and `types` below `solver`.** New plan settings go into `SolverOptions` and `Flags.solverOptions()`.
4. **Keep frontends thin.** New pacman-style behaviour belongs in `pacsaur/route` (policy) or `commands` (execution), not in `pacsaur/main`.
5. **Keep acyclicity at 0.** New sub-modules must not import their façade.
6. **Don't chase modularity.** It rose because directories now match real modules. Add directories only when a real module or façade family appears.
7. **Measure trends with a raw scan** of a clean checkout, compared with this round's raw numbers (QS 8171, 148 edges, depth 2, propagation 7.40%). Don't compare raw numbers with status12 or earlier. Since cross-module edges are invisible, check cycles, file sizes and new cross-module imports by eye. Check whether newer sentrux versions resolve `build.zig` modules.

---

## Appendix: Sentrux raw data

```
Scanned:            2026-11-17, sentrux 0.5.7 (MCP plugin 0.3.12), main at deafaaf

Resolved graph (named-module imports rewritten to path imports):
  Files:              141
  Import edges:       260
  Quality signal:     0.6912
  Root causes:
    Acyclicity:       1.000  (raw 0)
    Modularity:       0.186  (score 4573)  → BOTTLENECK
    Depth:            9      (score 4706)
    Equality:         0.237  (score 7628)
    Redundancy:       0.039  (score 9609)
  Cross-module edges: 150
  Coverage:           26 / 104 source files (25.0%), 37 test files
  DSM:
    Size:             64
    Above diagonal:   0      (no cycles)
    Below diagonal:   260
    Same level:       0
    Clusters:         0
    Density:          6.45%
    Propagation cost: 18.48%
    Level breaks:     9

Raw scan (named-module edges invisible; reference only):
  Files:              143
  Import edges:       148
  Lines:              39,335
  Quality signal:     0.8171
  Root causes:
    Acyclicity:       1.000
    Modularity:       0.431  (score 6210)
    Depth:            2      (score 8000)
    Equality:         0.237  (score 7628)
    Redundancy:       0.039  (score 9609)
  Cross-module edges: 38
  Coverage:           26 / 106 (24.5%)
  DSM:                size 63, 0 above diagonal, density 3.79%, propagation 7.40%, 9 level breaks

Resolved edge breakdown (script):
  263 file-level edges = 198 production + 26 test-only + 39 module-root
                         (re-exports and test discovery)

Git (90 days):
  Commits analysed:    111
  Files with churn:    51
  Hotspots:            30
  Coupling pairs:      34
  Single-author ratio: 1.0

Commit scans (resolved graph, same method):
  66c8547  QS 0.6767  depth 10  mod 0.139  prop 19.52%  130 files  211 edges
  d2a5895  QS 0.6765  depth 10  mod 0.141  prop 19.64%  132 files  213 edges
  3c5e0e1  QS 0.6823  depth 10  mod 0.169  prop 18.73%  132 files  230 edges
           (raw: QS 0.7648  depth 5  mod 0.355  prop 8.59%  143 edges)
  a5ac398  QS 0.6824  depth 10  mod 0.169  prop 18.73%  132 files  230 edges
  0f247e4  QS 0.6931  depth 9   mod 0.183  prop 18.87%  133 files  239 edges
  6e935bf  QS 0.6919  depth 9   mod 0.186  prop 18.48%  137 files  260 edges
  deafaaf  QS 0.6912  depth 9   mod 0.186  prop 18.48%  141 files  260 edges
```
