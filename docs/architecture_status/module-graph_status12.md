# Aurodle — Module Dependency Graph

> Reflects the codebase after Phases 11–15 (`66c8547`).
> Supersedes `module-graph_status11.md`.
> Sentrux scan: 2026-11-13, quality signal 6767/10000 (fresh scan, clean checkout).
>
> **Conventions** (same as status11):
> - **`color.zig`** is frontend-only. Only the `term → color` edge is drawn; `commands/*` and `main` also import it, but those edges are omitted for readability.
> - **`root.zig`** is omitted (test discovery only).
> - **Test-only files** (`*/tests.zig`, `*/mocks.zig`, `git/test_repo.zig`) have dashed borders and are not drawn as edge targets.
> - **Thick arrows (`==>`)** mark one longest dependency chain (depth 10). A second chain of the same length is listed below the graph.

```mermaid
flowchart TD
    %% ── External systems ──────────────────────────────────────────────────
    C_libalpm(["libalpm\n(C library)"])
    AUR_API(["AUR RPC\n(HTTPS)"])
    AUR_status(["status.archlinux.org\n(HTTPS)"])
    devtools(["devtools\nmkarchroot · makechrootpkg"])

    %% ── Layer 0 — Primitives (leaves) ────────────────────────────────────
    subgraph L0["Layer 0 · Primitives"]
        utils["utils\nIo · process execution\nparallelFor · buffered stdout"]
        provider["provider\nProviderCandidate\nProviderChooser\nProviderSelection"]
        source["source\nSource enum"]
        report["report\nReporter · Level"]
    end

    %% ── Layer 1 — Infrastructure ──────────────────────────────────────────
    subgraph L1["Layer 1 · Infrastructure"]
        alpm["alpm\nlibalpm FFI"]
        aur["aur\nAUR HTTP client"]
        git["git\nclone / fetch\napplyUpstream"]
        auth["auth\nsudo / su wrapper\nkeepalive"]
        chroot["chroot\nclean chroot setup\npacman.conf · staging"]
        repo["repo\nlocal pacman repo\nrepo-add · clean"]
        makepkg["makepkg\nmakepkg.conf parsing"]
        repo_conf["repo_conf\nrepo name derivation\nDEFAULT_REPO_NAME"]
        pacman_conf["pacman_conf\nPacmanConf\nregisterSyncDbs"]
        version["version\nVersionConstraint\ncheckVersion"]
        plan["plan\nBuildPlan · BuildEntry\nConflict · SolverOptions"]
    end

    %% ── Layer 2 — Domain ─────────────────────────────────────────────────
    subgraph L2["Layer 2 · Domain"]
        subgraph pacman_grp["pacman (façade + sub-modules)"]
            pacman["pacman.zig\nlibalpm domain layer\ninstalled / sync queries"]
            p_provides["pacman/provides\nProvidesIndex\nper-db provider scans"]
            p_repo_deps["pacman/repo_deps\ntransitive repo deps\nSyncProviderChoice"]
        end
        devel["devel\nVCS version check\nsource stamps"]
        dep_spec["dep_spec\nDepSpec\nparseDep"]
    end

    %% ── Layer 3 — Resolution ─────────────────────────────────────────────
    subgraph L3["Layer 3 · Resolution"]
        registry["registry\nmulti-source lookup\ninstalled→sync→AUR→provider"]

        subgraph solver_grp["solver (façade + sub-modules)"]
            solver["solver.zig\norchestrator\nBFS · plan assembly"]
            s_graph["solver/graph\nDepGraph · alias resolution"]
            s_topo["solver/topo\nKahn topo sort"]
            s_conflicts["solver/conflicts\nconflict detection"]
        end
    end

    %% ── Layer 4 — Commands (frontend) ────────────────────────────────────
    subgraph L4["Layer 4 · Commands (frontend)"]
        term["term\nconfirm · provider prompts"]
        color["color\nANSI styling"]
        types["commands/types\nFlags · solverOptions\nExitCode · writers"]
        q_ctx["commands/query_context\nQueryContext"]
        b_ctx["commands/build_context\nBuildContext"]
        display["commands/display\ndisplayPlan · fmtSize\ngap · aurRowCount"]
        outdated["commands/outdated\ncollectOutdated\ncompareWithAur · mergeDevelVersion"]
        commands["commands.zig\npure router"]

        query["commands/query\ninfo · search · outdated"]
        analysis["commands/analysis\nresolve · buildorder"]
        status["commands/status\nArch status page"]

        build_cmd["build_cmd.zig\norchestrator\nclone · sync · upgrade · clean"]
        b_execute["build_execute\nmakepkg · makechrootpkg\nfailure propagation"]
        b_install["build_install\npacman invocations\nprovider selection"]
        b_review["build_review\nPKGBUILD review\ndiff · conflict prompts"]
    end

    %% ── Layer 5 — Entry point ────────────────────────────────────────────
    main["main\nCLI parse · dispatch · wiring"]

    %% ── Test files (dashed, wired through root.zig) ──────────────────────
    s_tests["solver/tests\n+ solver/mocks"]
    r_tests["registry/tests\n+ registry/mocks"]
    pt["pacman/tests\n+ pacman/mocks"]
    rt["repo/tests"]
    gt["git/tests\n+ git/test_repo"]
    at["aur/tests"]

    %% ── External links ───────────────────────────────────────────────────
    alpm --> C_libalpm
    aur  --> AUR_API
    status --> AUR_status
    chroot --> devtools

    %% ── Critical path (depth 10) ─────────────────────────────────────────
    main ==> commands
    commands ==> analysis
    analysis ==> solver
    solver ==> s_conflicts
    s_conflicts ==> registry
    registry ==> pacman
    pacman ==> dep_spec
    dep_spec ==> version
    version ==> alpm
    alpm ==> utils

    %% ── Layer 1 edges ────────────────────────────────────────────────────
    aur --> utils
    git --> utils
    auth --> utils
    chroot --> auth & report & utils
    repo --> makepkg & repo_conf & report & utils
    makepkg --> utils
    repo_conf --> utils
    pacman_conf --> alpm & utils
    plan --> provider & source

    %% ── Layer 2 edges ────────────────────────────────────────────────────
    pacman --> alpm & pacman_conf & provider & repo_conf & version & p_provides & p_repo_deps
    p_provides --> alpm & provider
    p_repo_deps --> provider
    devel --> git & utils

    %% ── Layer 3 edges ────────────────────────────────────────────────────
    registry --> alpm & aur & dep_spec & devel & provider & source
    solver --> aur & plan & registry & s_graph & s_topo & version
    s_graph --> aur & source
    s_topo --> s_graph
    s_conflicts --> plan & s_graph

    %% ── Layer 4 — frontend support ───────────────────────────────────────
    term --> color & provider & utils
    types --> aur & plan & report & term & utils

    %% ── Layer 4 — contexts (no solver import) ────────────────────────────
    q_ctx --> types & aur & pacman & registry
    b_ctx --> types & aur & auth & pacman & registry & repo

    %% ── Layer 4 — commands ───────────────────────────────────────────────
    commands --> query & build_cmd & status
    display --> types & devel & pacman & plan
    outdated --> types & b_ctx & devel & git & pacman & registry & utils
    query --> types & q_ctx & b_ctx & outdated & aur & devel & pacman & registry
    analysis --> types & b_ctx & display & registry
    status --> types & utils
    build_cmd --> types & b_ctx & q_ctx & b_execute & b_install & b_review & display & outdated & aur & devel & git & pacman & repo & solver & term & utils
    b_execute --> types & b_ctx & auth & chroot & devel & git & plan & repo & utils
    b_install --> types & b_ctx & pacman & plan & registry & repo & term & utils
    b_review --> types & b_ctx & git & plan & term & utils

    %% ── entry point ──────────────────────────────────────────────────────
    main --> types & q_ctx & b_ctx & aur & auth & git & pacman & registry & repo & term & utils

    %% ── test file edges (dashed, not targets) ───────────────────────────
    s_tests -.-> solver
    r_tests -.-> registry
    pt -.-> pacman
    pt -.-> p_repo_deps
    rt -.-> repo
    gt -.-> git
    at -.-> aur

    %% ── styling ──────────────────────────────────────────────────────────
    classDef external  fill:#1a1a2e,stroke:#4a4a8a,color:#aaaaff
    classDef prim      fill:#1e3a2f,stroke:#3a7a5a,color:#aaffcc
    classDef infra     fill:#2a2a1e,stroke:#7a7a3a,color:#ffffaa
    classDef domain    fill:#2a1e2a,stroke:#7a3a7a,color:#ffaaff
    classDef resolv    fill:#2a1e1e,stroke:#8a3a3a,color:#ffaaaa
    classDef cmd       fill:#1e2a3a,stroke:#3a6a9a,color:#aaccff
    classDef entry     fill:#3a2a1e,stroke:#9a6a3a,color:#ffccaa
    classDef testonly  fill:#1a1a1a,stroke:#5a5a5a,color:#aaaaaa,stroke-dasharray: 5 5

    class C_libalpm,AUR_API,AUR_status,devtools external
    class utils,provider,source,report prim
    class alpm,aur,git,auth,chroot,repo,makepkg,repo_conf,pacman_conf,version,plan infra
    class pacman,p_provides,p_repo_deps,devel,dep_spec domain
    class registry,solver,s_graph,s_topo,s_conflicts resolv
    class term,color,commands,types,q_ctx,b_ctx,display,outdated,query,build_cmd,b_execute,b_install,b_review,analysis,status cmd
    class main entry
    class s_tests,r_tests,pt,rt,gt,at testonly
```

## Depth chain (10 levels)

Levels count import steps from a leaf (the sentrux convention). Two chains tie:

```
utils → alpm → version → dep_spec → pacman → registry →
    solver/conflicts → solver → analysis → commands → main          (drawn ==>)
    build_context → outdated → query → commands → main               (same length)
```

All files by level:

| Level | Files |
|---:|---|
| 0 | `utils`, `provider`, `source`, `report`, `color` |
| 1 | `alpm`, `aur`, `auth`, `git`, `makepkg`, `plan`, `repo_conf`, `term`, `pacman/repo_deps` |
| 2 | `chroot`, `commands/types`, `devel`, `pacman_conf`, `pacman/provides`, `repo`, `solver/graph`, `version` |
| 3 | `commands/status`, `dep_spec`, `solver/topo` |
| 4 | `pacman` |
| 5 | `commands/display`, `registry` |
| 6 | `commands/build_context`, `commands/query_context`, `solver/conflicts` |
| 7 | `commands/build_execute`, `build_install`, `build_review`, `outdated`, `solver` |
| 8 | `commands/analysis`, `commands/build_cmd`, `commands/query` |
| 9 | `commands` |
| 10 | `main` |

`build_context` moved from level 8 (status11) to level 6. The command files that only take a `*BuildContext` (`build_execute`, `build_install`, `build_review`, `outdated`) moved from level 9 to level 7.

## What changed since status11

### Structural changes

| Change | status11 | status12 |
|---|---|---|
| `commands/build_context.zig` | Imports `solver`; `newSolver()` | No `solver` import; no `newSolver()` |
| `solver.zig` | `init(allocator, registry)` + loose `rebuild`/`needed`/`ignore` fields | `init(allocator, registry, SolverOptions)` |
| `plan.zig` | Plan types | + `SolverOptions` |
| `commands/types.zig` | `Flags` | + `Flags.solverOptions()` |
| `pacman.zig` | 941 lines; imports `repo` | 671 lines; imports `repo_conf`, `pacman/provides`, `pacman/repo_deps` |
| `pacman/provides.zig` | — | New: `ProvidesIndex`, per-db provider scans |
| `pacman/repo_deps.zig` | — | New: transitive repo-dep walks, `SyncProviderChoice` |
| `commands/outdated.zig` | Decisions inline in `collectOutdated` | Pure `filterByName`, `compareWithAur`, `vcsPkgbases`, `mergeDevelVersion` |
| `commands/display.zig` | Spacing inline; `printSize` duplicates `fmtSize` | `gap`, `aurRowCount`; `printSize` reuses `fmtSize` |
| `root.zig` | Test discovery incl. `build_context` | + `commands/outdated`, `commands/display` |

### Edges added and removed

| Edge | Change |
|---|---|
| `commands/build_context → solver` | removed |
| `pacman → repo` | removed |
| `pacman/tests → repo` | removed |
| `pacman → repo_conf` | added |
| `pacman → pacman/provides` | added |
| `pacman → pacman/repo_deps` | added |
| `pacman/provides → alpm`, `pacman/provides → provider` | added |
| `pacman/repo_deps → provider` | added |
| `pacman/tests → repo_conf`, `pacman/tests → pacman/repo_deps` | added (test only) |

### Metric shifts

| Metric | status11 | status12 | Change |
|---|---|---|---|
| Quality signal | 6591 | 6767 | +176 (+2.7%) |
| Bottleneck | Depth | Modularity | Shifted |
| Depth | 12 | 10 | −2 levels |
| Modularity | 0.131 | 0.139 | +0.008 |
| Propagation cost | 20.94% | 19.52% | −1.42pp |
| Same-level edges | 0 | 0 | → |
| Clusters | 0 | 0 | → |
| Files (sentrux, incl. Markdown) | 126 | 130 | +4 (2 status11 docs, 2 new source files) |
| Import edges | 206 | 211 | +5 |

### DSM

| Metric | status11 | status12 |
|---|---|---|
| Above diagonal | 0 | 0 |
| Below diagonal | 206 | 211 |
| Same level | 0 | 0 |
| Clusters | 0 | 0 |
| Level breaks | 12 | 10 |

Zero cycles and zero same-level edges are held. Acyclicity is still perfect.
