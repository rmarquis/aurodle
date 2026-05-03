# Aurodle — Current Architecture

> Reflects the actual codebase as of 2026-05 after the Issues G and G′ refactors.
> Supersedes `ARCHITECTURE_status5.md`.

**Module dependency graph:** [`docs/architecture_status/module-graph_status6.md`](module-graph_status6.md)

---

## Sentrux health metrics

### Before / after comparison (Issues G + G′)

| Dimension  | Status5 (baseline) | Status6 (current) | Δ      |
|---|---|---|---|
| Overall    | 6527               | 6581              | +54    |
| Acyclicity | 10000              | 10000             | —      |
| Redundancy | 9409               | 9409              | —      |
| Equality   | 7761               | 7761              | —      |
| Modularity | 4056 · raw 0.108   | 4015 · raw 0.102  | −41    |
| **Depth**  | **4000 · 12 lvls** | **4211 · 11 lvls**| **+211** |

97 files · 119 import edges · ~13 k lines · DSM propagation cost 2487 (was 2540)

Bottleneck: **modularity** (4015) — depth is no longer the dominant drag. The two dimensions are now within 196 points of each other (4015 vs 4211), the tightest the gap has been across all status snapshots.

---

## Source layout

```
src/
├── main.zig                 746 lines   CLI parsing, command dispatch
├── commands.zig              32 lines   Thin hub: re-exports context, display + sub-commands
├── commands/
│   ├── context.zig          278 lines   Commands struct, shared types, I/O helpers
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
├── solver.zig             1 607 lines   Orchestrator: BFS discovery + plan assembly + tests; re-exports plan types
├── solver/
│   ├── graph.zig             83 lines   DepGraph data structure, alias resolution
│   ├── topo.zig              80 lines   Kahn's algorithm topological sort
│   ├── conflicts.zig        166 lines   Conflict detection; imports Conflict from plan.zig
│   └── mocks.zig            548 lines   Test doubles (MockRegistry, MockInstalledSet)
├── registry.zig           1 111 lines   Multi-source package lookup cascade
├── registry/
│   └── mocks.zig            239 lines   Test doubles (MockPacman, MockAurClient)
├── pacman.zig               985 lines   libalpm domain layer (installed/sync queries)
├── repo.zig               1 350 lines   Local pacman repository management; refreshAurpkgsSyncDb
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

### Issue H — Modularity plateau (now the bottleneck)

Modularity is now the leading drag at 4015 (raw 0.102), with 96/119 cross-module
edges (81%). The main contributors are the structural hubs:

- `context.zig` imports 7 modules (aur, registry, repo, pacman, utils, auth, color) — necessary for the `Commands` struct fields and methods.
- `build_cmd.zig` imports 10+ modules — inherent to its orchestration role.
- `main.zig` imports ~8 modules directly for stack construction.

There is no obvious low-cost win here. The remaining cross-module density reflects
actual coupling in the problem domain rather than incidental structural accidents.

### Depth floor at 11

The remaining chain passes through `solver.zig` (depth 8), which is imported by
`analysis.zig`, `build_cmd.zig`, and `query.zig` for the `Solver` type and its
`resolve` method — not just plan types. Reducing further would require splitting
`solver.zig` into a thin interface/types layer and a logic layer.

---

## What is stable and well-structured

- **Layers 0–2** are cleanly focused with no cycles.
- **`plan.zig`** is a genuinely thin types module at depth 3: four structs, no logic, no
  solver dependency. Both Layer 3 (solver/conflicts) and Layer 4 (display, build phases)
  share it without transitive coupling.
- **`repo.zig`** cleanly owns `refreshAurpkgsSyncDb` via `anytype` injection — no new
  import edges, repository management responsibility well-placed.
- **`solver/`** remains a textbook deep-module family, fully isolated from concrete
  backends via the comptime-generic `SolverImpl(RegistryT)`.
- **`display.zig`** isolates all plan rendering behind a narrow two-function surface.
- **`outdated.zig`** decouples outdated-detection logic from both `query` and `build_cmd`.
- **`context.zig`** is a genuine shared-types hub: Commands struct, plain data types, and
  I/O helpers — no deep infrastructure imports.
- **Zero dependency cycles** — acyclicity score 10000/10000.
- **DSM clean**: all 119 import edges are below-diagonal; zero above-diagonal inversions;
  zero same-level edges. Propagation cost 2487 (35 nodes).
