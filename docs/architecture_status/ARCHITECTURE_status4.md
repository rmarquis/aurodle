# Aurodle — Current Architecture

> Reflects the actual codebase as of 2026-05 — architecture unchanged from status3.
> This status adds a sentrux baseline scan (2026-05-03) and documents the four
> remaining structural issues it surfaced.
> Supersedes `ARCHITECTURE_status3.md`.

**Module dependency graph:** [`docs/architecture_status/module-graph_status4.md`](module-graph_status4.md)

---

## Sentrux health metrics (2026-05-03 baseline)

89 files · 106 import edges · 29 k lines · 31 DSM nodes · propagation cost 2914

| Dimension  | Score  | Raw              |          |
|---|---|---|---|
| Overall    | 6368   | —                |          |
| Acyclicity | 10000  | 0 cycles         | ✅ Perfect |
| Redundancy | 9409   | 5.9% duplication | ✅ Good    |
| Equality   | 7761   | 0.224            | 🟡 Decent  |
| Modularity | 3943   | 0.091            | ❌ Poor    |
| **Depth**  | **3636** | **14 levels**  | **❌ Bottleneck** |

DSM interpretation: all 106 edges flow below-diagonal — clean layering, no inversions.

---

## Source layout

```
src/
├── main.zig                 746 lines   CLI parsing, command dispatch
├── commands.zig              29 lines   Thin hub: re-exports context + sub-commands
├── commands/
│   ├── context.zig          740 lines   Commands struct, shared types, display helpers
│   ├── query.zig            612 lines   info, search, outdated, VCS check
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
├── alpm.zig                 543 lines   Thin C FFI wrapper for libalpm
├── aur.zig                  601 lines   AUR RPC HTTP client + JSON types
├── git.zig                  567 lines   Git clone / update operations
├── auth.zig                 454 lines   Privilege escalation (sudo/su + keepalive)
├── devel.zig                194 lines   VCS package version check via makepkg
├── utils.zig                315 lines   Process execution, interactive prompts
├── provider.zig              18 lines   Shared provider selection types (Layer 0)
├── color.zig                 86 lines   Terminal ANSI colour styling
└── root.zig                  18 lines   Test-discovery entry point (refAllDecls)
                          ──────────
                          ~12 600 lines total
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
│                          provider.zig                            │
└─────────────────────────────────────────────────────────────────┘
```

---

## Depth chain analysis

Sentrux reports 14 file-level dependency levels against 6 logical layers.
The longest chain (bottom → top, `color.zig` included as it is imported everywhere):

```
color(1) → provider(2) → utils(3) → git(4) → devel(5) → registry(6)
         → s_graph(7) → s_conflicts(8) → solver(9) → context(10)
         → b_build(11) → build_cmd(12) → commands(13) → main(14)
```

The gap between 6 logical layers and 14 file-level depths has two structural causes:

**Issue C — `context.zig` imports `solver.zig`.**
Solver sits at depth 9; because every command sub-module imports context, all of
Layer 4 inherits that depth. Removing solver from context would drop context to
depth 7 (deepest remaining import: `registry` at 6), saving 3 depth levels from
everything above.

**Issue D — `solver/graph.zig` imports `registry.zig`.**
s_graph's job is alias resolution in a directed graph. If it only uses `aur.Package`
types (no registry lookups), the registry import is unnecessary and pushes s_graph
from depth 3 to depth 7. Removing it would drop the solver chain by 1 level.

---

## Module responsibilities

| Module | Responsibility | Notable public surface |
|---|---|---|
| `main.zig` | Arg parsing; builds the full stack (`Commands`, `Pacman`, `Repository`, `Auth`); dispatches to commands | `main()`, `runWithFullStack()` |
| `commands.zig` | **Thin hub**: re-exports everything from `context.zig` and the four sub-command modules; enables test discovery via `refAllDecls` | (re-exports only; 29 lines) |
| `commands/context.zig` | Shared context, types, and display helpers | `Commands`, `Flags`, `ExitCode`, `BuildResult`, `OutdatedEntry`, `displayPlan`, `handleResolveError` |
| `commands/query.zig` | Read-only AUR queries; outdated detection (AUR + VCS) | `info`, `search`, `outdated`, `collectOutdated`, `checkDevelPackages` |
| `commands/build_cmd.zig` | Build pipeline orchestration: sequences clone → review → build → install | `show`, `clonePackages`, `sync`, `build`, `runBuildPipeline`, `upgrade` |
| `commands/build_cmd/build.zig` | makepkg / makechrootpkg mechanics; failure propagation | `runBuild`, `BuildError` |
| `commands/build_cmd/install.zig` | pacman install invocations; auth escalation; provider selection UI; cache purge | `installPackages`, `purgeCache` |
| `commands/build_cmd/review.zig` | PKGBUILD review: diff viewing, interactive accept/edit/abort; conflict presentation | `reviewPkgbuild`, `resolveConflicts` |
| `commands/analysis.zig` | Dependency tree display and machine-readable build order | `resolve`, `buildorder` |
| `commands/status.zig` | Fetch and display Arch Linux service monitor data | `run()` |
| `solver.zig` | Orchestrates: BFS discovery → conflict detection → topo sort → plan assembly; owns `BuildPlan`, `BuildEntry`, `DependencyEntry`, re-exports `Conflict` | `Solver`, `SolverImpl`, `BuildPlan`, `BuildEntry`, `DependencyEntry`, `Conflict` |
| `solver/graph.zig` | Directed dependency graph with alias (virtual-name → real-name) resolution | `DepGraph`, `NodeMeta` |
| `solver/topo.zig` | Kahn's algorithm topological sort over AUR nodes | `topoSort(allocator, *DepGraph) ![][]const u8` |
| `solver/conflicts.zig` | AUR↔AUR, AUR↔installed, repo↔installed conflict and replaces detection; provides-aware | `detectConflicts(PacmanT, allocator, *DepGraph, *PacmanT) ![]Conflict`, `Conflict` |
| `registry.zig` | Four-tier lookup: installed → official sync → AUR → provider; caching; batch `multiInfo`; exposes `vercmp` and `isVcsPackage`; re-exports provider types | `PackageRegistry`, `resolve`, `resolveMany`, `Source`, `Resolution`, `vercmp`, `isVcsPackage`, `ProviderCandidate`, `ProviderChooserFn`, `ProviderSelection` |
| `pacman.zig` | Domain queries on top of `alpm.zig`: installed/sync lookups, version constraint checks, pacman.conf + mirrorlist parsing | `Pacman`, `isInstalled`, `installedVersion`, `isInSyncDb`, `satisfies`, `findProvider`, `allForeignPackages` |
| `repo.zig` | Local pacman repository lifecycle: `repo-add`, artifact scanning, clean; makepkg.conf + PKGDEST parsing; dynamic repo name derivation | `Repository`, `addBuiltPackages`, `listPackages`, `clean`, `MakepkgConfig` |
| `alpm.zig` | Thin, zero-heap-alloc C FFI over libalpm; generic `AlpmListIterator`; `vercmp`, `findSatisfier` | `Handle`, `Database`, `AlpmPackage`, `Dependency`, `vercmp` |
| `aur.zig` | HTTP client for AUR RPC v5: search, info, multiInfo; JSON deserialization | `Client`, `Package`, `SearchField` |
| `git.zig` | Stateless, idempotent git operations on the AUR clone cache | `clone`, `update`, `cloneOrUpdate`, `listFiles`, `readFile`, `diffSinceLastPull` |
| `auth.zig` | Privilege escalation: PACMAN_AUTH env → sudo → su fallback; keepalive loop; shell quoting | `Auth`, `shellJoin` |
| `devel.zig` | VCS package freshness: run `makepkg --nobuild --printsrcinfo`; parse SRCINFO epoch:pkgver-pkgrel | `isVcsPackage`, `checkVersion`, `parseSrcinfoVersion` |
| `utils.zig` | Subprocess execution (capture / interactive / in-dir); `promptYesNo`; `promptProviderChoice` | `runCommand`, `runCommandIn`, `runInteractive`, `promptProviderChoice` |
| `provider.zig` | Shared provider selection types used by both `registry.zig` and `utils.zig` | `ProviderCandidate`, `ProviderChooserFn`, `ProviderSelection` |
| `color.zig` | Terminal ANSI colour; `Style` enum (color / no-color / auto) | `Style` |

---

## Issues resolved since status3

None. The codebase is unchanged; this status captures the sentrux baseline and the
issues it surfaced for future resolution.

---

## Remaining architectural issues

Identified via sentrux analysis on 2026-05-03 (quality signal 6368/10000).
Issues A and B from status2→3 are resolved; these are new findings.

### Issue C — `context.zig` imports `solver.zig` (depth driver, modularity)

`commands/context.zig` is the shared-types hub imported by every command sub-module.
Its import of `solver.zig` (depth 9) pushes context to depth 10, cascading through
all build_cmd phases and into `commands.zig`/`main.zig`.

**Fix:** Remove solver from context's imports. Sub-commands that need solver types
(`BuildPlan`, `BuildEntry`, `DependencyEntry`) should import `solver.zig` directly.
The key question is whether `displayPlan` and `handleResolveError` in context take
solver types in their signatures — if so, those helpers may belong in a thin wrapper
imported by the sub-commands rather than in shared context.

**Expected gain:** depth 14 → ~11, modularity ↑.

### Issue D — `solver/graph.zig` imports `registry.zig` (depth driver)

`solver/graph.zig` provides "directed dependency graph with alias resolution" and
imports both `registry` and `aur`. If alias resolution only dereferences `aur.Package`
name fields and performs no registry lookups at runtime, the registry import is a
type-convenience that adds 4 file-level depths to the entire solver sub-chain.

**Fix:** Audit `solver/graph.zig` for actual `registry.*` call sites. If only
`aur.Package` is used, change `s_graph → registry & aur` to `s_graph → aur` only.

**Expected gain:** depth −1 (solver chain 9 → 8).

### Issue E — `build_cmd.zig` imports `query.zig` (peer coupling)

`build_cmd.zig` (build pipeline orchestrator) imports `query.zig` (read-only query
command), creating a Layer 4 sibling dependency. Both commands already share
`context.zig` as the appropriate shared surface. The specific symbol imported from
query is likely `collectOutdated` — if so, that function belongs at Layer 3 (registry
or a small shared module) rather than inside a peer command.

**Fix:** Identify what `build_cmd` uses from `query` and relocate it to a layer that
both commands can import independently, without one knowing about the other.

**Expected gain:** modularity ↑, Layer 4 peer-independence restored.

### Issue F — `context.zig` wide import fan-out (modularity)

`context.zig` imports 9 modules across layers 0–3: `aur`, `registry`, `solver`,
`repo`, `pacman`, `devel`, `git`, `utils`, `auth`. This single file is the primary
driver of the 0.091 modularity score (83% of all edges cross module boundaries).
`devel` and `git` are infrastructure-level imports that do not obviously belong in a
shared-types hub.

**Fix:** Audit whether `devel` and `git` appear in context's public type signatures
or only in internal display helper implementations. If the latter, consider passing
pre-computed values rather than importing the modules, or splitting context into a
thin `commands/types.zig` (minimal deps) and a `commands/display.zig` (heavier).

**Expected gain:** modularity ↑, context import fan-out −2 minimum.

---

## What is stable and well-structured

- **Layers 0–2** (`alpm`, `aur`, `color`, `provider`, `utils`, `git`, `auth`,
  `repo`, `pacman`, `devel`) are cleanly focused with no cycles.
- **`solver/`** remains a textbook deep-module family: one narrow entry point backed
  by three single-responsibility sub-modules, fully isolated from concrete backends
  via the comptime-generic `SolverImpl(RegistryT)`.
- **`registry.zig`** is the sole gateway for version comparison (`vercmp`), VCS
  detection (`isVcsPackage`), and provider type definitions — no module below Layer 4
  bypasses it to reach `alpm` or `devel` directly.
- **`commands/context.zig`** is the clean shared-types hub for sub-command wiring;
  sub-commands depend on it without depending on each other (except Issue E).
- **`provider.zig`** is a minimal zero-logic type module at Layer 0, eliminating
  the only remaining cross-layer type dependency (resolved in status3).
- **`auth.zig`** remains a self-contained, well-tested module with no surprising
  dependencies.
- **Zero dependency cycles** — acyclicity score 10000/10000.
