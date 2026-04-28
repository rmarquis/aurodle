# Aurodle — Current Architecture

> Reflects the actual codebase as of 2026-04 after the Issue A–B refactors.
> Supersedes `ARCHITECTURE_status2.md`.

**Module dependency graph:** [`docs/architecture_status/module-graph_status3.md`](module-graph_status3.md)

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

Dependencies flow downward. No remaining upward or cross-layer violations.

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

## Issues resolved since status2

### ✓ Issue A — `utils.zig` → `registry.zig` upward dependency (compile cycle)

`promptProviderChoice` in `utils.zig` previously imported `ProviderCandidate` from
`registry.zig`, creating the compile cycle `utils → registry → pacman → repo → utils`.

**Fix:** `ProviderCandidate`, `ProviderChooserFn`, and `ProviderSelection` were
extracted to a new `provider.zig` (Layer 0, 18 lines, depends only on `color.zig`).
`registry.zig` re-exports the three types unchanged; all existing callers
(`solver.zig`, `build_cmd/install.zig`) continue to reference them via
`registry_mod.ProviderCandidate` with no changes. `utils.zig` now imports
`provider.zig` directly and no longer touches `registry.zig`.

### ✓ Issue B — `commands/query.zig` imports `alpm` directly

`query.zig` previously instantiated its own `alpm.Handle` in `info` and `search`
(bypassing the `Pacman` instance already on the `Commands` stack) and called
`alpm.vercmp()` directly in `collectOutdated` and `checkDevelPackages`.

**Fix (Handle):** `info` and `search` now use `self.pacman.installedVersion(name)`
from the stack-constructed `Pacman`, eliminating a second concurrent libalpm handle.

**Fix (vercmp):** Both `alpm.vercmp()` calls replaced with
`registry_mod.PackageRegistry.vercmp()`, matching the same pattern applied to
`solver.zig` in the earlier Issue #3 refactor.

`query.zig` now has zero `alpm` imports.

---

## Remaining architectural issues

None known. The layer diagram is clean with no upward edges or abstraction-bypass
imports.

---

## What is stable and well-structured

- **Layers 0–2** (`alpm`, `aur`, `color`, `provider`, `utils`, `git`, `auth`,
  `repo`, `pacman`, `devel`) are cleanly focused with no cycles.
- **`solver/`** remains a textbook deep-module family: one narrow entry point
  backed by three single-responsibility sub-modules, fully isolated from concrete
  backends via the comptime-generic `SolverImpl(RegistryT)`.
- **`registry.zig`** is the sole gateway for version comparison (`vercmp`), VCS
  detection (`isVcsPackage`), and provider type definitions — no module below Layer
  4 bypasses it to reach `alpm` or `devel` directly.
- **`commands/context.zig`** is the clean shared-types hub; sub-commands depend on
  it without depending on each other.
- **`provider.zig`** is a minimal zero-logic type module at Layer 0, eliminating
  the only remaining cross-layer type dependency.
- **`auth.zig`** remains a self-contained, well-tested module with no surprising
  dependencies.
