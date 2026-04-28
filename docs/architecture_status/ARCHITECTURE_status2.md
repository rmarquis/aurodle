# Aurodle — Current Architecture

> Reflects the actual codebase as of 2026-04 after the Issue #1–#5 refactors.
> Supersedes `ARCHITECTURE_status1.md`.

**Module dependency graph:** [`docs/architecture_status/module-graph_status2.md`](module-graph_status2.md)

---

## Source layout

```
src/
├── main.zig                 746 lines   CLI parsing, command dispatch
├── commands.zig              29 lines   Thin hub: re-exports context + sub-commands
├── commands/
│   ├── context.zig          740 lines   Commands struct, shared types, display helpers
│   ├── query.zig            621 lines   info, search, outdated, VCS check
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
├── registry.zig           1 131 lines   Multi-source package lookup cascade
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
├── color.zig                 86 lines   Terminal ANSI colour styling
└── root.zig                  18 lines   Test-discovery entry point (refAllDecls)
                          ──────────
                          ~12 600 lines total
```

---

## Layers

Dependencies flow downward. The upward arrow on `utils` indicates the one
remaining cross-layer dependency noted in the issues section.

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
│     ↑ (utils → registry)   auth.zig  utils.zig                   │
├─────────────────────────────────────────────────────────────────┤
│  Layer 0 · Wrappers      alpm.zig  aur.zig  color.zig           │
└─────────────────────────────────────────────────────────────────┘
```

---

## Module responsibilities

| Module | Responsibility | Notable public surface |
|---|---|---|
| `main.zig` | Arg parsing; builds the full stack (`Commands`, `Pacman`, `Repository`, `Auth`); dispatches to commands | `main()`, `runWithFullStack()` |
| `commands.zig` | **Thin hub**: re-exports everything from `context.zig` and the four sub-command modules; enables test discovery via `refAllDecls` | (re-exports only; 29 lines) |
| `commands/context.zig` | Shared context, types, and display helpers previously split across `commands.zig` and its callers | `Commands`, `Flags`, `ExitCode`, `BuildResult`, `OutdatedEntry`, `displayPlan`, `handleResolveError` |
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
| `registry.zig` | Four-tier lookup: installed → official sync → AUR → provider; caching; batch `multiInfo`; exposes `vercmp` and `isVcsPackage` to isolate solver from lower layers | `PackageRegistry`, `resolve`, `resolveMany`, `Source`, `Resolution`, `vercmp`, `isVcsPackage` |
| `pacman.zig` | Domain queries on top of `alpm.zig`: installed/sync lookups, version constraint checks, pacman.conf + mirrorlist parsing | `Pacman`, `isInstalled`, `isInSyncDb`, `satisfies`, `findProvider`, `allForeignPackages` |
| `repo.zig` | Local pacman repository lifecycle: `repo-add`, artifact scanning, clean; makepkg.conf + PKGDEST parsing; dynamic repo name derivation | `Repository`, `addBuiltPackages`, `listPackages`, `clean`, `MakepkgConfig` |
| `alpm.zig` | Thin, zero-heap-alloc C FFI over libalpm; generic `AlpmListIterator`; `vercmp`, `findSatisfier` | `Handle`, `Database`, `AlpmPackage`, `Dependency`, `vercmp` |
| `aur.zig` | HTTP client for AUR RPC v5: search, info, multiInfo; JSON deserialization | `Client`, `Package`, `SearchField` |
| `git.zig` | Stateless, idempotent git operations on the AUR clone cache | `clone`, `update`, `cloneOrUpdate`, `listFiles`, `readFile`, `diffSinceLastPull` |
| `auth.zig` | Privilege escalation: PACMAN_AUTH env → sudo → su fallback; keepalive loop; shell quoting | `Auth`, `shellJoin` |
| `devel.zig` | VCS package freshness: run `makepkg --nobuild --printsrcinfo`; parse SRCINFO epoch:pkgver-pkgrel | `isVcsPackage`, `checkVersion`, `parseSrcinfoVersion` |
| `utils.zig` | Subprocess execution (capture / interactive / in-dir); `promptYesNo`; `promptProviderChoice` | `runCommand`, `runCommandIn`, `runInteractive`, `promptProviderChoice` |
| `color.zig` | Terminal ANSI colour; `Style` enum (color / no-color / auto) | `Style` |

---

## Issues resolved since status1

### ✓ Issue #1 — `commands.zig` bidirectional cycle

`commands.zig` is now 29 lines and only imports `context.zig` (for re-export) and
the four sub-command modules. Sub-commands import `context.zig` for shared types;
there are no back-links. The cycle is gone.

### ✓ Issue #2 — `solver.zig` too large (2 506 lines)

Split across five files. `solver.zig` is now an orchestrator (~450 lines of
production code, ~1 200 lines of integration tests):

| File | Lines | Responsibility |
|---|---|---|
| `solver.zig` | 1 648 | Orchestrator + all integration tests |
| `solver/graph.zig` | 83 | `DepGraph` data structure |
| `solver/topo.zig` | 80 | Kahn's algorithm, pure function |
| `solver/conflicts.zig` | 182 | Conflict detection, `Conflict` type |
| `solver/mocks.zig` | 548 | Test doubles |

### ✓ Issue #3 — `solver.zig` bypasses `registry` abstraction for alpm access

`solver.zig` no longer imports `alpm`, `devel`, or `pacman` directly.
`vercmp` and `isVcsPackage` are now namespace functions on `RegistryT`,
implemented in `RegistryImpl` (delegates to `alpm`/`devel`) and `MockRegistry`
(pure Zig, no libalpm in test builds). The comptime-generic `SolverImpl(RegistryT)`
is now fully isolated from lower layers.

### ✓ Issue #4 — Test mocks embedded in production modules

- `MockPacman` and `MockAurClient` extracted from `registry.zig` → `registry/mocks.zig`
- `MockRegistry` and `MockInstalledSet` extracted from `solver.zig` → `solver/mocks.zig`

### ✓ Issue #5 — `commands/build_cmd.zig` too large (1 243 lines)

Reduced to 560 lines (orchestration only). Three focused sub-modules:
- `build_cmd/build.zig` (314 lines) — makepkg mechanics
- `build_cmd/install.zig` (189 lines) — pacman and auth
- `build_cmd/review.zig` (122 lines) — interactive PKGBUILD review

---

## Remaining architectural issues

### 1. `utils.zig` → `registry.zig` upward dependency

`promptProviderChoice` in `utils.zig` takes `[]registry_mod.ProviderCandidate`,
pulling a Layer-3 type into a Layer-1 module. This creates a compile cycle:
`utils → registry → pacman → repo → utils`.

**Root cause:** `ProviderCandidate` and `ProviderChooserFn` are defined in
`registry.zig` but consumed by a utility function that has no other registry
dependency.

**Refactor direction:** move `ProviderCandidate` / `ProviderChooserFn` to a
small shared types module (`provider_types.zig` or inline into `utils.zig`) below
the registry layer.

### 2. `commands/query.zig` imports `alpm` directly

`query.zig` calls `alpm.Handle.init()` and `alpm.vercmp()` directly, bypassing
the `registry` abstraction. The `vercmp` case is the same pattern fixed in Issue
#3; `alpm.Handle.init()` is a more structural concern (query currently
instantiates its own alpm handle rather than receiving one from the stack).

---

## What is stable and well-structured

- **Layers 0–2** (`alpm`, `aur`, `color`, `utils`, `git`, `auth`, `repo`,
  `pacman`, `devel`) remain cleanly focused with no new cycles.
- **`solver/`** is now a textbook deep-module family: one narrow entry point
  (`solver.zig`) backed by three single-responsibility sub-modules, each with a
  minimal interface. The comptime-generic pattern fully isolates it from the
  concrete backend.
- **`registry.zig`** cleanly encapsulates the multi-source lookup cascade and is
  the single boundary between the domain and the resolver. It now also serves as
  the sole gateway for version comparison and VCS detection.
- **`commands/context.zig`** is the clean shared-types hub the layer 4 modules
  needed; sub-commands depend on it without depending on each other.
- **`auth.zig`** remains a self-contained, well-tested module with no surprising
  dependencies.
