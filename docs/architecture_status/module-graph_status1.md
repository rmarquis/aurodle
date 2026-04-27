# Aurodle — Module Dependency Graph

> Generated from actual `@import` statements. `color.zig` is omitted as an edge target
> (every module uses it for terminal styling; drawing those edges would obscure the real
> structure). `root.zig` is omitted (test-discovery only).

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
        registry["registry\nmulti-source lookup\ninstalled→sync→AUR→provider"]
        solver["solver\nBFS discovery\ntopo sort · conflict detect"]
    end

    %% ── Layer 4 — Commands ───────────────────────────────────────────────
    subgraph L4["Layer 4 · Commands"]
        commands["commands\nhub · shared types\ndisplay helpers"]
        query["commands/query\ninfo · search\noutdated · VCS check"]
        build_cmd["commands/build_cmd\nshow · clone · sync · build\nbuild-loop · review · install"]
        analysis["commands/analysis\nresolve · buildorder"]
        status["commands/status\nArch status page"]
    end

    %% ── Layer 5 — Entry point ────────────────────────────────────────────
    main["main\nCLI parse · dispatch"]

    %% ── External links ───────────────────────────────────────────────────
    alpm --> C_libalpm
    aur  --> AUR_API
    status --> AUR_status

    %% ── Layer 1 edges ────────────────────────────────────────────────────
    utils --> color
    git   --> utils
    auth  --> utils
    repo  --> utils

    %% ── Layer 2 edges ────────────────────────────────────────────────────
    pacman --> alpm & utils
    devel  --> aur & git & utils

    %% ── Layer 3 edges ────────────────────────────────────────────────────
    registry --> aur & pacman & alpm
    solver   --> registry & aur & alpm & devel & pacman

    %% ── commands hub ─────────────────────────────────────────────────────
    commands --> aur & registry & solver & repo & pacman & devel & git & utils & auth

    %% ── hub re-exports its submodules (forward links) ────────────────────
    commands --> query & build_cmd & analysis & status

    %% ── submodules import hub for shared types (back-links = cycle!) ─────
    query     -. shared types .-> commands
    build_cmd -. shared types .-> commands
    analysis  -. shared types .-> commands

    %% ── submodule extra deps ─────────────────────────────────────────────
    query     --> aur & alpm & git & devel & pacman
    build_cmd --> aur & git & devel & solver & repo & pacman & utils & auth & registry
    analysis  --> registry & solver
    status    --> color

    %% ── entry point ──────────────────────────────────────────────────────
    main --> commands & aur & color

    %% ── styling ──────────────────────────────────────────────────────────
    classDef external  fill:#1a1a2e,stroke:#4a4a8a,color:#aaaaff
    classDef prim      fill:#1e3a2f,stroke:#3a7a5a,color:#aaffcc
    classDef infra     fill:#2a2a1e,stroke:#7a7a3a,color:#ffffaa
    classDef domain    fill:#2a1e2a,stroke:#7a3a7a,color:#ffaaff
    classDef resolv    fill:#2a1e1e,stroke:#8a3a3a,color:#ffaaaa
    classDef cmd       fill:#1e2a3a,stroke:#3a6a9a,color:#aaccff
    classDef entry     fill:#3a2a1e,stroke:#9a6a3a,color:#ffccaa

    class C_libalpm,AUR_API,AUR_status external
    class color,alpm,aur prim
    class utils,git,auth,repo infra
    class pacman,devel domain
    class registry,solver resolv
    class commands,query,build_cmd,analysis,status cmd
    class main entry
```

## Cycle

`commands.zig` and its three submodules (`query`, `build_cmd`, `analysis`) form a **bidirectional dependency**:

- `commands.zig` imports the submodules to re-export them (enabling `root.zig` to discover their tests via `refAllDecls`).
- The submodules import `commands.zig` to access shared types (`Commands`, `ExitCode`, `Flags`, `BuildResult`, etc.) and display helpers (`displayPlan`, `handleResolveError`).

Zig resolves this within a single compilation unit, so it compiles, but it makes the two sides impossible to reason about in isolation.

## Bypass of the Registry Abstraction

`solver.zig` imports `alpm` and `pacman` directly, bypassing the `registry` layer it also depends on. This couples the solver to the concrete database backend — the comptime-generic `SolverImpl` only abstracts the `Registry`, not the underlying alpm calls for conflict checking.
