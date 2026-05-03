# Aurodle — Module Dependency Graph

> Reflects the codebase as of 2026-05 (unchanged from status3).
> Annotated with the four structural issues surfaced by the sentrux scan
> (2026-05-03, quality signal 6368/10000).
>
> `color.zig` is omitted as an edge target (every module uses it; drawing those
> edges would obscure the real structure). `root.zig` is omitted (test-discovery
> only). Test-only files (`solver/mocks.zig`, `registry/mocks.zig`) are shown with
> dashed borders and not drawn as edge targets.
>
> ⚠ edges are flagged with the issue label that applies (C/D/E/F — see
> ARCHITECTURE_status4.md for full descriptions).

```mermaid
flowchart TD
    %% ── External systems ──────────────────────────────────────────────────
    C_libalpm(["libalpm\n(C library)"])
    AUR_API(["AUR RPC\n(HTTPS)"])
    AUR_status(["status.archlinux.org\n(HTTPS)"])

    %% ── Layer 0 — Thin wrappers / primitives ─────────────────────────────
    subgraph L0["Layer 0 · Wrappers"]
        color["color\nANSI styling"]
        alpm["alpm\nlibalpm FFI"]
        aur["aur\nAUR HTTP client"]
        provider["provider\nProviderCandidate\nProviderChooserFn\nProviderSelection"]
    end

    %% ── Layer 1 — Infrastructure ──────────────────────────────────────────
    subgraph L1["Layer 1 · Infrastructure"]
        utils["utils\nprocess execution\ninteractive prompts"]
        git["git\nclone / update"]
        auth["auth\nsudo / su wrapper"]
        repo["repo\nlocal pacman repo\nmakepkg.conf"]
    end

    %% ── Layer 2 — Domain ─────────────────────────────────────────────────
    subgraph L2["Layer 2 · Domain"]
        pacman["pacman\nlibalpm domain layer\ninstalled / sync queries"]
        devel["devel\nVCS version check\nmakepkg --printsrcinfo"]
    end

    %% ── Layer 3 — Resolution ─────────────────────────────────────────────
    subgraph L3["Layer 3 · Resolution"]
        registry["registry\nmulti-source lookup\ninstalled→sync→AUR→provider\n+ vercmp · isVcsPackage\n+ re-exports provider types"]

        subgraph solver_grp["solver (façade + sub-modules)"]
            solver["solver.zig\norchestrator\ntypes · BFS · plan assembly"]
            s_graph["solver/graph\nDepGraph · alias resolution"]
            s_topo["solver/topo\nKahn topo sort"]
            s_conflicts["solver/conflicts\nconflict detection\nConflict type"]
        end
    end

    %% ── Layer 4 — Commands ───────────────────────────────────────────────
    subgraph L4["Layer 4 · Commands"]
        context["commands/context\nCommands struct\nshared types · display helpers"]
        commands["commands.zig\nthin hub\nre-exports only"]

        query["commands/query\ninfo · search\noutdated · VCS check"]
        analysis["commands/analysis\nresolve · buildorder"]
        status["commands/status\nArch status page"]

        subgraph build_grp["build_cmd (orchestrator + phases)"]
            build_cmd["build_cmd.zig\norchestrator\nclone · sync · upgrade"]
            b_build["build_cmd/build\nmakepkg · makechrootpkg\nfailure propagation"]
            b_install["build_cmd/install\npacman invocations\nauth · cache purge"]
            b_review["build_cmd/review\nPKGBUILD review\ndiff · conflict prompts"]
        end
    end

    %% ── Layer 5 — Entry point ────────────────────────────────────────────
    main["main\nCLI parse · dispatch"]

    %% ── External links ───────────────────────────────────────────────────
    alpm --> C_libalpm
    aur  --> AUR_API
    status --> AUR_status

    %% ── Layer 1 edges ────────────────────────────────────────────────────
    git   --> utils
    auth  --> utils
    repo  --> utils
    utils --> provider

    %% ── Layer 2 edges ────────────────────────────────────────────────────
    pacman --> alpm & repo
    devel  --> aur & git & utils

    %% ── Layer 3 edges ────────────────────────────────────────────────────
    registry --> aur & alpm & devel & pacman & provider
    solver   --> registry
    s_graph  -- "⚠ D: depth driver\n(only aur.Package needed?)" --> registry
    s_graph  --> aur
    s_topo   --> s_graph
    s_conflicts --> s_graph & registry

    %% ── Layer 4 — commands hub (re-exports only, no back-link) ───────────
    commands --> context
    commands --> query & build_cmd & analysis & status

    %% ── context: shared types + display helpers ──────────────────────────
    %% ISSUE F: devel and git are infrastructure imports in a types hub
    context -- "⚠ C: depth driver\n(pushes all L4 to depth 10)" --> solver
    context --> aur & registry & repo & pacman & utils & auth
    context -- "⚠ F: infra import in types hub" --> devel
    context -- "⚠ F: infra import in types hub" --> git

    %% ── submodules import context (not commands — cycle is gone) ─────────
    query     --> context & registry & aur & git & devel & pacman
    analysis  --> context & registry & solver
    build_cmd -- "⚠ E: peer coupling\n(L4 sibling dep)" --> query
    build_cmd --> context & aur & git & devel & solver & repo & pacman & utils
    b_build   --> context & git & devel & solver & repo & utils & auth
    b_install --> context & registry & repo & pacman & auth & utils
    b_review  --> context & git & solver & utils

    %% ── entry point ──────────────────────────────────────────────────────
    main --> commands & aur & pacman & registry & repo & auth & utils & git

    %% ── styling ──────────────────────────────────────────────────────────
    classDef external  fill:#1a1a2e,stroke:#4a4a8a,color:#aaaaff
    classDef prim      fill:#1e3a2f,stroke:#3a7a5a,color:#aaffcc
    classDef infra     fill:#2a2a1e,stroke:#7a7a3a,color:#ffffaa
    classDef domain    fill:#2a1e2a,stroke:#7a3a7a,color:#ffaaff
    classDef resolv    fill:#2a1e1e,stroke:#8a3a3a,color:#ffaaaa
    classDef cmd       fill:#1e2a3a,stroke:#3a6a9a,color:#aaccff
    classDef entry     fill:#3a2a1e,stroke:#9a6a3a,color:#ffccaa
    classDef issue     fill:#3a1e1e,stroke:#cc4444,color:#ffcccc

    class C_libalpm,AUR_API,AUR_status external
    class color,alpm,aur,provider prim
    class utils,git,auth,repo infra
    class pacman,devel domain
    class registry,solver,s_graph,s_topo,s_conflicts resolv
    class commands,context,query,build_cmd,b_build,b_install,b_review,analysis,status cmd
    class main entry
    class context,s_graph,build_cmd issue
```

## Depth chain (14 levels)

The longest file-to-file dependency path, annotated with the issue that extends each
segment beyond what the logical layer model would predict:

```
color       level  1   (Layer 0 — leaf)
provider    level  2   (Layer 0)
utils       level  3   (Layer 1)
git         level  4   (Layer 1)
devel       level  5   (Layer 2)
registry    level  6   (Layer 3)
s_graph     level  7   (Layer 3) ← Issue D: registry import adds 4 levels here
s_conflicts level  8   (Layer 3)
solver      level  9   (Layer 3)
context     level 10   (Layer 4) ← Issue C: solver import pushes all of L4 up
b_build     level 11   (Layer 4)
build_cmd   level 12   (Layer 4)
commands    level 13   (Layer 4 hub)
main        level 14   (Layer 5)
```

Fixing Issues C and D together would compress this to approximately 11 levels.

## What changed since status3

**No code changes.** This graph is identical to status3. The annotations and issue
markers are new, added after the sentrux scan (2026-05-03, quality signal 6368).

## Remaining issues

| Issue | Edge | Type | Expected gain |
|---|---|---|---|
| C | `context → solver` | Depth driver | Depth 14 → ~11, modularity ↑ |
| D | `s_graph → registry` | Depth driver | Depth −1, solver chain 9 → 8 |
| E | `build_cmd → query` | Peer coupling | Layer 4 peer-independence |
| F | `context → devel`, `context → git` | Modularity | Fan-out −2 minimum |
