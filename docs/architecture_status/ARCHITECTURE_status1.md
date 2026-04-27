# Aurodle — Current Architecture

> Reflects the actual codebase as of 2026-04. Supersedes the aspirational description
> in `ARCHITECTURE.md`, which describes an earlier design that was never fully realised.

**Module dependency graph:** [`docs/architecture_status/module-graph_status1.md`](module-graph_status1.md)

---

## Source layout

```
src/
├── main.zig                 743 lines   CLI parsing, command dispatch
├── commands.zig             803 lines   Hub: shared types + display helpers + re-exports
├── commands/
│   ├── query.zig            621 lines   info, search, outdated, VCS check
│   ├── build_cmd.zig      1 243 lines   show, clone, sync, build, build-loop, review, install
│   ├── analysis.zig         105 lines   resolve, buildorder (dep-tree display)
│   └── status.zig           160 lines   Arch Linux service status page
├── solver.zig             2 506 lines   BFS discovery, topo sort, conflict detection
├── registry.zig           1 355 lines   Multi-source package lookup cascade
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
                          12 638 lines total
```

---

## Layers

The codebase has an implicit five-layer structure. Dependencies flow downward; upward
arrows indicate the architectural issues noted in the next section.

```
┌─────────────────────────────────────────────────────────┐
│  Layer 5 · Entry         main.zig                        │
├─────────────────────────────────────────────────────────┤
│  Layer 4 · Commands      commands.zig (hub)              │
│                          commands/{query,build_cmd,      │
│                                    analysis,status}      │
├─────────────────────────────────────────────────────────┤
│  Layer 3 · Resolution    solver.zig  registry.zig        │
├─────────────────────────────────────────────────────────┤
│  Layer 2 · Domain        pacman.zig  devel.zig           │
├─────────────────────────────────────────────────────────┤
│  Layer 1 · Infrastructure  git.zig  repo.zig             │
│                            auth.zig  utils.zig           │
├─────────────────────────────────────────────────────────┤
│  Layer 0 · Wrappers      alpm.zig  aur.zig  color.zig   │
└─────────────────────────────────────────────────────────┘
```

---

## Module responsibilities

| Module | Responsibility | Notable public surface |
|---|---|---|
| `main.zig` | Arg parsing; builds the full stack (`Commands`, `Pacman`, `Repository`, `Auth`); dispatches to commands | `main()`, `runWithFullStack()` |
| `commands.zig` | **Hub**: holds `Commands` struct (the shared context passed everywhere), shared types, display helpers for dep plans; re-exports sub-command modules | `Commands`, `Flags`, `ExitCode`, `BuildResult`, `OutdatedEntry`, `displayPlan`, `handleResolveError` |
| `commands/query.zig` | Read-only AUR queries; outdated detection (AUR + VCS) | `info`, `search`, `outdated`, `collectOutdated`, `checkDevelPackages` |
| `commands/build_cmd.zig` | Full build pipeline: PKGBUILD review, makepkg loop, pacman install; chroot support | `show`, `clonePackages`, `sync`, `build`, `runBuildPipeline`, `upgrade` |
| `commands/analysis.zig` | Dependency tree display and machine-readable build order | `resolve`, `buildorder` |
| `commands/status.zig` | Fetch and display Arch Linux service monitor data | `run()` |
| `solver.zig` | BFS dependency discovery (batched AUR calls per level); Kahn topo sort; conflict detection (AUR↔AUR, AUR↔installed) | `Solver`, `BuildPlan`, `BuildEntry`, `Conflict` |
| `registry.zig` | Four-tier lookup: installed → official sync → AUR → provider; caching; batch `multiInfo` | `PackageRegistry`, `resolve`, `resolveMany`, `Source`, `Resolution` |
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

## Architectural issues

These are the spots most likely to reward refactoring effort.

### 1. Bidirectional dependency between `commands.zig` and its submodules

`commands.zig` re-exports `query`, `build_cmd`, `analysis`, and `status` (so `root.zig` can
discover their tests). Each of those submodules in turn imports `commands.zig` to get the
`Commands` struct and other shared types. The cycle compiles in Zig (single compilation
unit), but neither side can be reasoned about independently.

**Root cause:** shared types (`Commands`, `ExitCode`, `Flags`, `BuildResult`, …) live in
`commands.zig` alongside the re-export list and display helpers — three unrelated concerns.

**Refactor direction:** extract shared types into a `commands/types.zig` (or `context.zig`)
that submodules import; `commands.zig` can still re-export everything without importing
back.

### 2. `solver.zig` owns too many concerns (2 506 lines)

Currently in one file: graph data structures (`DepGraph`, `NodeMeta`), BFS discovery,
Kahn toposort, conflict detection logic, and all test mocks (`MockRegistry`,
`MockInstalledSet`). Each is independently testable and conceptually distinct.

**Refactor direction:** split into `solver/graph.zig`, `solver/topo.zig`,
`solver/conflicts.zig`, keeping `solver.zig` as a thin orchestrator (similar to how
`commands/` is structured).

### 3. `solver.zig` bypasses the `registry` abstraction for alpm access

`solver.zig` imports `alpm` and `pacman` directly (for conflict checking via
`findProvider`), even though it also uses `registry`. The comptime-generic
`SolverImpl(RegistryT)` only abstracts the registry interface — the alpm dependency leaks
through.

### 4. Test mocks are embedded in production modules

`registry.zig` contains `MockPacman` and `MockAurClient`. `solver.zig` contains
`MockRegistry` and `MockInstalledSet`. This inflates file sizes and mixes test
infrastructure with production code.

**Refactor direction:** move mocks into `test/` or alongside their modules as
`registry_test.zig` (Zig supports `@import("module_test.zig")` patterns).

### 5. `commands/build_cmd.zig` is the second-largest file (1 243 lines) and does everything

It handles: PKGBUILD display (`show`), git clone orchestration, makepkg loop, chroot
builds, interactive PKGBUILD review, pacman installation, and provider selection UI. These
are distinct phases that happen to share the same `Commands` context.

---

## What is stable and well-structured

- **Layers 0–2** (`alpm`, `aur`, `color`, `utils`, `git`, `auth`, `repo`, `pacman`,
  `devel`) are cleanly layered with no cycles and focused responsibilities.
- The **comptime-generic injection** pattern (`SolverImpl(RegistryT)`,
  `RegistryImpl(PacmanT, AurClientT)`) works well and keeps unit tests fast.
- **`registry.zig`** cleanly encapsulates the multi-source lookup cascade and is the right
  abstraction boundary between the domain and the resolver.
- **`auth.zig`** is a self-contained, well-tested module with no surprising dependencies.
