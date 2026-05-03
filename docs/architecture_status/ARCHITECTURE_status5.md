# Aurodle — Current Architecture

> Reflects the actual codebase as of 2026-05 after the Issues C–F refactors.
> Supersedes `ARCHITECTURE_status4.md`.

**Module dependency graph:** [`docs/architecture_status/module-graph_status5.md`](module-graph_status5.md)

---

## Sentrux health metrics

### Before / after comparison (Issues C–F)

| Dimension  | Status4 (baseline) | Status5 (current) | Δ      |
|---|---|---|---|
| Overall    | 6368               | 6527              | +159   |
| Acyclicity | 10000              | 10000             | —      |
| Redundancy | 9409               | 9409              | —      |
| Equality   | 7761               | 7761              | —      |
| Modularity | 3943 · raw 0.091   | 4056 · raw 0.108  | +113   |
| **Depth**  | **3636 · 14 lvls** | **4000 · 12 lvls**| **+364** |

94 files · 117 import edges · ~13 k lines · DSM: propagation cost not re-measured

Bottleneck: **depth** (4000) and **modularity** (4056) are now within 56 points of each other — the project is balanced across the two dimensions rather than dominated by one.

---

## Source layout

```
src/
├── main.zig                 746 lines   CLI parsing, command dispatch
├── commands.zig              29 lines   Thin hub: re-exports context, display + sub-commands
├── commands/
│   ├── context.zig          280 lines   Commands struct, shared types, I/O helpers
│   ├── display.zig          290 lines   Plan display helpers (displayPlan, displayInstallList)
│   ├── outdated.zig         140 lines   collectOutdated, checkDevelPackages
│   ├── query.zig            440 lines   info, search, outdated, VCS check
│   ├── build_cmd.zig        560 lines   Build pipeline orchestration
│   ├── build_cmd/
│   │   ├── build.zig        314 lines   makepkg/makechrootpkg mechanics, failure propagation
│   │   ├── install.zig      189 lines   pacman invocations, auth, provider selection, cache purge
│   │   └── review.zig       122 lines   PKGBUILD review, diff viewing, conflict prompts
│   ├── analysis.zig         105 lines   resolve, buildorder (dep-tree display)
│   └── status.zig           160 lines   Arch Linux service status page
├── solver.zig             1 648 lines   Orchestrator: types + BFS discovery + plan assembly + tests
├── solver/
│   ├── graph.zig             83 lines   DepGraph data structure, alias resolution
│   ├── topo.zig              80 lines   Kahn's algorithm topological sort
│   ├── conflicts.zig        182 lines   Conflict detection; owns Conflict type
│   └── mocks.zig            548 lines   Test doubles (MockRegistry, MockInstalledSet)
├── registry.zig           1 117 lines   Multi-source package lookup cascade
├── registry/
│   └── mocks.zig            239 lines   Test doubles (MockPacman, MockAurClient)
├── pacman.zig               985 lines   libalpm domain layer (installed/sync queries)
├── repo.zig               1 339 lines   Local pacman repository management
├── source.zig                13 lines   Source enum (Layer 0; shared by registry + solver/graph)
├── alpm.zig                 543 lines   Thin C FFI wrapper for libalpm
├── aur.zig                  601 lines   AUR RPC HTTP client + JSON types
├── git.zig                  585 lines   Git clone / update ops + CacheRoot helpers
├── auth.zig                 454 lines   Privilege escalation (sudo/su + keepalive)
├── devel.zig                194 lines   VCS package version check via makepkg
├── utils.zig                315 lines   Process execution, interactive prompts
├── provider.zig              18 lines   Shared provider selection types (Layer 0)
├── color.zig                 86 lines   Terminal ANSI colour styling
└── root.zig                  18 lines   Test-discovery entry point (refAllDecls)
```

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
├─────────────────────────────────────────────────────────────────┤
│  Layer 0 · Wrappers      alpm.zig  aur.zig  color.zig           │
│                          provider.zig  source.zig                │
└─────────────────────────────────────────────────────────────────┘
```

---

## Depth chain (12 levels)

```
color(1) → provider(2) → utils(3) → git(4) → devel(5) → registry(6)
         → s_conflicts(7) → solver(8) → display(9) → analysis(10)
         → commands(11) → main(12)
```

Two levels were saved since status4:
- `s_graph` dropped from 7 → 3 by importing `source.zig` instead of `registry.zig` (Issue D).
- `context.zig` dropped from 10 → 7 by offloading display functions — which carry the `solver` import — to `display.zig` (Issue C).

The remaining 12-level depth is structural: `display.zig` must import `solver.zig` because `displayPlan` takes `solver_mod.BuildPlan` as a parameter. Reducing further would require extracting `BuildPlan`/`BuildEntry` from `solver.zig` into a thinner types module at a lower layer.

---

## Module responsibilities

| Module | Responsibility | Notable public surface |
|---|---|---|
| `main.zig` | Arg parsing; builds the full stack; dispatches to commands | `main()`, `runWithFullStack()` |
| `commands.zig` | **Thin hub**: re-exports context types, display helpers, and sub-commands | (re-exports only; 29 lines) |
| `commands/context.zig` | Shared context and types; I/O helpers | `Commands`, `Flags`, `ExitCode`, `BuildResult`, `OutdatedEntry`, `OutdatedList`, `handleResolveError`, `getStdout` |
| `commands/display.zig` | Plan display: verbose/compact package tables, size formatting | `displayPlan`, `displayInstallList` |
| `commands/outdated.zig` | Outdated package detection: AUR RPC diff + VCS --devel probe | `collectOutdated`, `checkDevelPackages` |
| `commands/query.zig` | Read-only AUR queries; outdated detection (re-exports from outdated.zig) | `info`, `search`, `outdated` |
| `commands/build_cmd.zig` | Build pipeline orchestration: resolve → clone → review → build → install | `show`, `clonePackages`, `sync`, `build`, `runBuildPipeline`, `upgrade` |
| `commands/build_cmd/build.zig` | makepkg / makechrootpkg mechanics; failure propagation | `runBuild`, `BuildError` |
| `commands/build_cmd/install.zig` | pacman install invocations; auth escalation; provider selection UI; cache purge | `installPackages`, `purgeCache` |
| `commands/build_cmd/review.zig` | PKGBUILD review: diff viewing, interactive accept/edit/abort; conflict presentation | `reviewPkgbuild`, `resolveConflicts` |
| `commands/analysis.zig` | Dependency tree display and machine-readable build order | `resolve`, `buildorder` |
| `commands/status.zig` | Fetch and display Arch Linux service monitor data | `run()` |
| `solver.zig` | Orchestrates: BFS discovery → conflict detection → topo sort → plan assembly | `Solver`, `SolverImpl`, `BuildPlan`, `BuildEntry`, `DependencyEntry`, `Conflict` |
| `solver/graph.zig` | Directed dependency graph with alias resolution | `DepGraph`, `NodeMeta` |
| `solver/topo.zig` | Kahn's algorithm topological sort over AUR nodes | `topoSort` |
| `solver/conflicts.zig` | AUR↔AUR, AUR↔installed conflict and replaces detection | `detectConflicts`, `Conflict` |
| `registry.zig` | Four-tier lookup; caching; `vercmp`; `isVcsPackage`; re-exports provider + Source types | `PackageRegistry`, `resolve`, `resolveMany`, `Source`, `vercmp`, `isVcsPackage` |
| `source.zig` | **Layer 0 type:** `Source` enum shared by `registry.zig` and `solver/graph.zig` | `Source` |
| `pacman.zig` | Domain queries on `alpm.zig`: installed/sync lookups, version constraints | `Pacman`, `isInstalled`, `installedVersion`, `findProvider`, `allForeignPackages` |
| `repo.zig` | Local pacman repository lifecycle: `repo-add`, artifact scanning, clean | `Repository`, `addBuiltPackages`, `listPackages`, `clean` |
| `alpm.zig` | Thin, zero-heap-alloc C FFI over libalpm | `Handle`, `Database`, `AlpmPackage`, `vercmp` |
| `aur.zig` | HTTP client for AUR RPC v5: search, info, multiInfo; JSON deserialization | `Client`, `Package`, `SearchField` |
| `git.zig` | Stateless, idempotent git ops on the AUR clone cache; cache-root resolution | `clone`, `update`, `cloneOrUpdate`, `CacheRoot`, `resolveCacheRoot`, `freeCacheRoot` |
| `auth.zig` | Privilege escalation: PACMAN_AUTH env → sudo → su fallback; keepalive loop | `Auth`, `shellJoin` |
| `devel.zig` | VCS package freshness: run `makepkg --nobuild --printsrcinfo`; parse SRCINFO | `isVcsPackage`, `checkVersion`, `parseSrcinfoVersion` |
| `utils.zig` | Subprocess execution; `promptYesNo`; `promptProviderChoice` | `runCommand`, `runCommandIn`, `runInteractive`, `promptProviderChoice` |
| `provider.zig` | Shared provider selection types (Layer 0) | `ProviderCandidate`, `ProviderChooserFn`, `ProviderSelection` |
| `color.zig` | Terminal ANSI colour; `Style` enum | `Style` |

---

## Issues resolved since status4

### ✓ Issue D — `solver/graph.zig` imported `registry.zig` (depth driver)

`NodeMeta.source` used `registry_mod.Source`. `Source` was extracted to a new
`source.zig` at Layer 0. `registry.zig` re-exports it unchanged. `solver/graph.zig`
now imports `source.zig` directly, dropping `s_graph` from depth 7 to 3.

### ✓ Issue C — `context.zig` imported `solver.zig` and `devel.zig` (depth driver)

The plan display functions (`displayPlan`, `displayInstallList`, and all their
helpers) were the only consumers of those imports. They were extracted to a new
`commands/display.zig`. `context.zig` drops from depth 10 to 7. `commands.zig`
re-exports the display helpers for callers that use the hub.

### ✓ Issue F — `context.zig` imported `git.zig` (fan-out)

`resolveCacheRoot` and its companions were the only users of the `git` import.
They were moved to `git.zig` itself as free functions (`resolveCacheRoot`,
`freeCacheRoot`, `CacheRoot`). `context.zig` now imports only registry and
domain-layer modules.

### ✓ Issue E — `build_cmd.zig` imported `query.zig` (peer coupling)

`collectOutdated` and `checkDevelPackages` were extracted to a new
`commands/outdated.zig`. `build_cmd.zig` imports `outdated.zig` directly;
`query.zig` re-exports the functions via pub aliases so its `outdated` command
and any external callers continue to work unchanged.

---

## Remaining architectural issues

### Issue G — Depth still at 12; display.zig→solver.zig is the new floor

The remaining 12-level chain passes through `display.zig` (9) → `solver.zig` (8).
`display.zig` must import `solver.zig` because `displayPlan` takes
`solver_mod.BuildPlan` and `solver_mod.BuildEntry` as parameters. Getting to 11
would require extracting those types to a thin module at or below Layer 3 that
`display.zig` could import without pulling in the full solver machinery.

**Potential fix:** create `src/plan.zig` (Layer 3 or lower) containing just
`BuildPlan`, `BuildEntry`, `DependencyEntry`, and `Conflict`. `solver.zig` re-exports
them; `display.zig` imports `plan.zig` instead of `solver.zig`. `display.zig` would
then be at depth max(context=7, plan=?, pacman=5, devel=5) + 1, potentially 8.

**Expected gain:** depth 12 → 11; `analysis.zig` and `build_cmd.zig` drop one level each.

### Issue H — Modularity plateau at 0.108

Cross-module edges stand at 93/117 (79%). The main contributors are the same
structural hubs as before, now slightly reduced:

- `context.zig` still imports 7 modules (aur, registry, repo, pacman, utils, auth,
  color) — necessary for the `Commands` struct fields and methods.
- `build_cmd.zig` imports 10+ modules — inherent to its orchestration role.
- `main.zig` imports ~8 modules directly for stack construction.

There is no obvious low-cost win here comparable to Issues C–F. The remaining
cross-module density reflects the actual coupling in the problem domain rather than
incidental structural accidents.

---

## What is stable and well-structured

- **Layers 0–2** are cleanly focused with no cycles.
- **`solver/`** remains a textbook deep-module family, fully isolated from concrete
  backends via the comptime-generic `SolverImpl(RegistryT)`.
- **`source.zig`** cleanly breaks the only remaining cross-layer type dependency
  without disturbing any existing public API.
- **`display.zig`** isolates all plan rendering behind a narrow two-function surface;
  private formatting helpers are fully encapsulated.
- **`outdated.zig`** decouples the outdated-detection logic from both the `query` and
  `build_cmd` commands; each imports it directly as a shared service.
- **`context.zig`** is now a genuine shared-types hub: Commands struct, plain data
  types, and I/O helpers — no logic, no deep infrastructure imports.
- **Zero dependency cycles** — acyclicity score 10000/10000.
