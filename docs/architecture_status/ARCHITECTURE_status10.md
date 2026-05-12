# Aurodle — Architecture Status 10

> Reflects the codebase after Phase 8 (acyclity fix: centralized test imports).
> Supersedes `ARCHITECTURE_status9.md`.

**Module dependency graph:** [`docs/architecture_status/module-graph_status10.md`](module-graph_status10.md)

---

## Sentrux health metrics

### Current scan (post-Phase 8)

| Dimension | Before (status9) | After (status10) | Assessment |
|---|---|---|---|
| **Quality Signal** | 0.5227 (52.27%) | 0.6747 (67.47%) | ↑ +29.1% improvement |
| **Bottleneck** | Acyclicity | Modularity | Shifted |
| **Acyclicity** | 0.833 (raw: 2 inversions) | 1.000 (raw: 0 inversions) | ↑ Perfect score |
| **Depth** | 13 levels | 10 levels | ↓ −3 levels |
| **File Size Equality** | 0.224 | 0.224 | → Stable |
| **Cross-Module Edges** | 120 / 163 (74%) | 131 / 176 (74%) | → Stable |
| **Test Coverage (sentrux)** | 22 / 78 (28.2%) | 22 / 78 (28.2%) | → Stable |
| **Propagation Cost** | 26.31% | 21.43% | ↓ −4.88pp |

118 files · 176 import edges · ~32,128 total lines · DSM propagation cost 21.43%

The Phase 8 refactor successfully **eliminated all acyclicity inversions**, **reduced depth by 3 levels**, and **dropped propagation cost below 22%** for the first time. The bottleneck has shifted from acyclicity to modularity.

---

## Source layout

```
src/
├── main.zig                 749 lines   CLI parsing, command dispatch
├── root.zig                  39 lines   Minimal API surface: 2 public re-exports + test discovery
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
├── solver.zig               421 lines   Orchestrator: BFS discovery + plan assembly
├── solver/
│   ├── graph.zig             83 lines   DepGraph data structure
│   ├── topo.zig              80 lines   Kahn's algorithm topological sort
│   ├── conflicts.zig        166 lines   Conflict detection
│   ├── mocks.zig            548 lines   Test doubles (MockRegistry, MockInstalledSet)
│   └── tests.zig           1207 lines   Unit tests for SolverImpl(MockRegistry)
├── registry.zig             438 lines   Multi-source package lookup cascade
├── registry/
│   ├── mocks.zig            239 lines   Test doubles (MockPacman, MockAurClient)
│   └── tests.zig            607 lines   Unit tests for RegistryImpl(MockPacman, MockAurClient)
├── repo.zig                 493 lines   Local pacman repository management
├── repo/
│   └── tests.zig            438 lines   Filesystem integration tests for Repository
├── dep_spec.zig              95 lines   DepSpec, parseDep
├── pacman.zig               643 lines   libalpm domain layer
├── pacman_conf.zig          117 lines   PacmanConf, registerSyncDbs
├── version.zig               68 lines   VersionConstraint, checkVersion
├── repo_conf.zig             77 lines   deriveRepoNameFromPacmanConf
├── plan.zig                  68 lines   Shared build plan types (Layer 1)
├── source.zig                12 lines   Source enum (Layer 0)
├── alpm.zig                 543 lines   Thin C FFI wrapper for libalpm
├── aur.zig                  388 lines   AUR RPC HTTP client + JSON types
├── aur/
│   └── tests.zig            220 lines   JSON parsing tests for AUR client
├── git.zig                  309 lines   Stateless, idempotent git ops on the AUR clone cache
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
| < 50 | `source.zig` (12), `provider.zig` (18), `root.zig` (39), `query_context.zig` (51), `build_context.zig` (60), `version.zig` (68) |
| 50–300 | `plan.zig`, `color.zig`, `solver/topo.zig`, `solver/graph.zig`, `dep_spec.zig`, `pacman_conf.zig`, `repo_conf.zig`, `makepkg.zig`, `git.zig` |
| 300–600 | `commands/build_cmd.zig`, `commands/types.zig`, `repo.zig`, `alpm.zig`, `auth.zig`, `utils.zig`, `solver.zig`, `registry.zig`, `aur.zig` |
| 600–1000 | `pacman.zig` (643), `main.zig` (749) |
| 1000+ | `solver/tests.zig` (1207), `registry/tests.zig` (607) — test files only |

`aur.zig` dropped from 601 to 388 lines after test extraction. Only two production files remain above 600 lines: `pacman.zig` (643) and `main.zig` (749).

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

## Depth chain (10 levels)

The longest file-to-file dependency path after Phase 8:

```
color       level  1   (Layer 0 — leaf)
provider    level  2   (Layer 0)
utils/plan  level  3   (Layer 1)
git         level  4   (Layer 1)
devel       level  5   (Layer 2)
registry    level  6   (Layer 3)
s_conflicts level  7   (Layer 3)
solver      level  8   (Layer 3)
analysis/   level  9   (Layer 4)  ← build_cmd and query also at depth 9
build_cmd/
query
commands    level 10   (Layer 4 hub)
main        level 10   (Layer 5)
```

Depth dropped from 13 to 10 because removing the `test { _ = @import("xxx/tests.zig"); }` blocks from parent modules eliminated the cycle-induced depth inflation. The structural chain `color → provider → utils → git → devel → registry → solver/conflicts → solver → commands/* → commands.zig → main.zig` is now 10 levels.

---

## Phase 6: Wire up extracted tests ✅ COMPLETE

**Commit:** `849ce81`

Fixed an oversight in the prior pacman test extraction: added `test { _ = @import("repo/tests.zig"); }` to `repo.zig`, `git.zig`, and `pacman.zig` so their extracted tests are discovered by `zig test`.

---

## Phase 7: Extract `aur.zig` inline tests ✅ COMPLETE

**Commit:** `35439d6`

| Metric | Before | After |
|---|---|---|
| `aur.zig` lines | 601 | 388 (−213) |
| `aur/tests.zig` lines | — | 220 |
| Tests extracted | 15 (inline) | 15 |
| Internals made `pub` | 0 | 6 (RpcResponse, RpcPackage, parseResponse, mapPackage, checkError, appendUrlEncoded) |

**Impact:** `aur.zig` dropped from the 600–1000 tier to the 300–600 tier.

---

## Phase 8: Centralize test imports — eliminate acyclicity inversions ✅ COMPLETE

**Commit:** `1ce97f1`

### Problem discovered

Wiring extracted test files into their parent modules created dependency cycles:
`repo.zig → repo/tests.zig → repo.zig`. Sentrux counted these as acyclicity inversions, degrading the quality signal from 5262 to 4396.

### Solution

Removed all `test { _ = @import("xxx/tests.zig"); }` blocks from:
- `repo.zig`, `git.zig`, `pacman.zig`, `aur.zig`, `solver.zig`, `registry.zig`

Centralized them in `root.zig`'s test block:
```zig
test {
    // ... existing refs ...
    _ = @import("aur/tests.zig");
    _ = @import("git/tests.zig");
    _ = @import("pacman/tests.zig");
    _ = @import("registry/tests.zig");
    _ = @import("repo/tests.zig");
    _ = @import("solver/tests.zig");
}
```

### Metric shifts

| Metric | status9 | status10 | Change |
|---|---|---|---|
| Quality signal | 5227 | 6747 | +1520 (+29.1%) |
| Acyclicity raw | 2 | 0 | −2 inversions |
| Acyclicity score | 3333 | 10000 | +6667 |
| Depth | 13 | 10 | −3 levels |
| Propagation cost | 26.31% | 21.43% | −4.88pp |
| Same-level edges | 4 | 0 | −4 |
| Clusters | 2 | 0 | −2 |

---

## Phase 9: Evaluate `main.zig` test extraction — SKIPPED

**Assessment:** After evaluation, extracting `main.zig`'s 31 CLI parsing tests would require either:
1. Adding a `main.zig → main/tests.zig → main.zig` cycle (reintroduces acyclicity inversions), or
2. Moving tests to module-tests only (exe tests drop to 0).

The status9 assessment holds: **low priority, marginal gain**. Entry-point argument parsing tests remain inline.

---

## What is stable and well-structured

- **Layers 0–2** remain cleanly focused with no cycles.
- **`plan.zig`** is still a genuinely thin types module at depth 3.
- **`solver/`** remains a textbook deep-module family, fully isolated via `SolverImpl(RegistryT)`.
- **`display.zig`** isolates all plan rendering behind a narrow two-function surface.
- **`outdated.zig`** decouples outdated-detection logic from both `query` and `build_cmd`.
- **Zero dependency cycles** in the DSM — all 176 import edges are below-diagonal.
- **Zero same-level edges** for the first time in the refactor history.
- **Propagation cost below 22%** (21.43%).
- **Perfect acyclicity score** (10000).
- **Better module boundaries** — commands.zig is now a pure router.

---

## Appendix: Sentrux raw data

```
Files:              118
Import edges:       176
Lines:              32,128
Quality signal:     0.6747

Root causes:
  Acyclicity:       1.000  ← FIXED (was bottleneck)
  Modularity:       0.136  → BOTTLENECK
  Depth:            10     ↓ improved from 13
  Equality:         0.224  → stable
  Redundancy:       0.045  → stable

Coverage:
  Source files:     78
  Test files:       34
  Tested:           22 / 78 (28.2%)

DSM:
  Above diagonal:   0      (no cycles)
  Below diagonal:   176
  Same level:       0
  Clusters:         0
  Propagation cost: 21.43%  ← improved from 26.31%
  Level breaks:     10
```
