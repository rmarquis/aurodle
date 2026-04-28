# Aurodle — Module Dependency Graph

> Reflects the codebase as of 2026-04 after the Issue A–B refactors.
> `color.zig` is omitted as an edge target (every module uses it; drawing those
> edges would obscure the real structure). `root.zig` is omitted (test-discovery
> only). Test-only files (`solver/mocks.zig`, `registry/mocks.zig`) are shown with
> dashed borders and not drawn as edge targets.

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
    s_graph  --> registry & aur
    s_topo   --> s_graph
    s_conflicts --> s_graph & registry

    %% ── Layer 4 — commands hub (re-exports only, no back-link) ───────────
    commands --> context
    commands --> query & build_cmd & analysis & status

    %% ── context: everything the commands layer needs ─────────────────────
    context --> aur & registry & solver & repo & pacman & devel & git & utils & auth

    %% ── submodules import context (not commands — cycle is gone) ─────────
    query     --> context & registry & aur & git & devel & pacman
    analysis  --> context & registry & solver
    build_cmd --> context & query & aur & git & devel & solver & repo & pacman & utils
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

    class C_libalpm,AUR_API,AUR_status external
    class color,alpm,aur,provider prim
    class utils,git,auth,repo infra
    class pacman,devel domain
    class registry,solver,s_graph,s_topo,s_conflicts resolv
    class commands,context,query,build_cmd,b_build,b_install,b_review,analysis,status cmd
    class main entry
```

## What changed since status2

**Cycle — eliminated**

- `utils.zig` no longer imports `registry.zig`. `ProviderCandidate`,
  `ProviderChooserFn`, and `ProviderSelection` were moved to `provider.zig`
  (Layer 0). Both `utils` and `registry` now depend on `provider`; the
  `utils → registry → pacman → repo → utils` compile cycle is gone.
- The dashed warning edge `utils -. "⚠ upward: ProviderCandidate type" .-> registry`
  is replaced by two clean downward edges: `utils --> provider` and
  `registry --> provider`.

**`query → alpm` bypass — eliminated**

- `query.zig` no longer imports `alpm.zig`. The `query → alpm` edge is gone.
- `query → registry` is new: `vercmp` is now called as
  `PackageRegistry.vercmp()` (same pattern as `solver`).
- `query → pacman` was already present (for `InstalledPackage`); it now also
  provides installed-version lookups via `self.pacman.installedVersion()`,
  replacing the ad-hoc second `alpm.Handle` that `info` and `search` were
  constructing independently.

## Remaining issues

None. The graph has no upward edges and no abstraction-bypass imports.
Every module accesses only its own layer and the layers directly below it
through the designated gateway (`registry` for version comparison and VCS
detection; `pacman` for installed-package queries).
