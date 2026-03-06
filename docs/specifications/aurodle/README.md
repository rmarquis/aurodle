# Aurodle Specifications

Executable test specifications defining the formal contracts, expected behaviors, and invariant properties for Aurodle's module system. Written in Zig using `std.testing`.

**Architecture**: [docs/architecture/aurodle-aur-helper.md](../../architecture/aurodle-aur-helper.md)
**Requirements**: [docs/requirements/aurodle-aur-helper.md](../../requirements/aurodle-aur-helper.md)

## Specification Levels

- **Contracts**: Interface obligations each module must satisfy. Defines inputs, outputs, and error conditions.
- **Behaviors**: Acceptance-criteria-driven tests derived from functional requirements. Uses Given/When/Then structure.
- **Properties**: Mathematical invariants that must hold for all inputs (idempotency, commutativity, roundtrips).

## Contract Specifications

| File | Module | Methods Covered |
|------|--------|----------------|
| [aur_contract_spec.zig](contracts/aur_contract_spec.zig) | `aur.Client` | init, deinit, info, multiInfo, search, Package struct |
| [alpm_contract_spec.zig](contracts/alpm_contract_spec.zig) | `alpm.Handle/Database/AlpmPackage` | init, deinit, getLocalDb, registerSyncDb, getPackage, vercmp |
| [pacman_contract_spec.zig](contracts/pacman_contract_spec.zig) | `pacman.Pacman` | isInstalled, installedVersion, isInSyncDb, satisfies, findProvider, refreshAurDb, allForeignPackages |
| [registry_contract_spec.zig](contracts/registry_contract_spec.zig) | `registry.Registry` | resolve, resolveMany, invalidate, cascade priority |
| [solver_contract_spec.zig](contracts/solver_contract_spec.zig) | `solver.Solver` | resolve → BuildPlan, cycle detection, pkgbase dedup |
| [repo_contract_spec.zig](contracts/repo_contract_spec.zig) | `repo.Repository` | ensureExists, addBuiltPackages, listPackages, clean, isConfigured |
| [git_contract_spec.zig](contracts/git_contract_spec.zig) | `git.*` | clone, update, cloneOrUpdate, listFiles, readFile, isCloned |
| [commands_contract_spec.zig](contracts/commands_contract_spec.zig) | `commands.*` | sync, build, info, search, show, outdated, upgrade, clean, --devel |
| [devel_contract_spec.zig](contracts/devel_contract_spec.zig) | `devel.*` | isVcsPackage, checkVersion, parseSrcinfoVersion, VcsVersionResult |
| [main_contract_spec.zig](contracts/main_contract_spec.zig) | `main` | parseArgs, exit codes, preconditions, module init order |
| [utils_contract_spec.zig](contracts/utils_contract_spec.zig) | `utils.*` | runCommand, runCommandWithLog, runSudo, promptYesNo, expandHome |

## Behavior Specifications

| File | Requirements Traced | Acceptance Criteria |
|------|--------------------|--------------------|
| [aur_rpc_behavior_spec.zig](behaviors/aur_rpc_behavior_spec.zig) | FR-1 | Info endpoint, multi-info, search, pkgbase resolution, error handling, std.http transport |
| [package_info_behavior_spec.zig](behaviors/package_info_behavior_spec.zig) | FR-2 | Metadata display, multi-package, not-found exit code, --raw, --format |
| [package_search_behavior_spec.zig](behaviors/package_search_behavior_spec.zig) | FR-3 | Search display, no-results exit 0, --by, --sort/--rsort, --raw, --literal, --format |
| [libalpm_behavior_spec.zig](behaviors/libalpm_behavior_spec.zig) | FR-4 | DB init, installed query, sync query, vercmp, version satisfaction, selective refresh, no libalpm installs |
| [dependency_resolution_behavior_spec.zig](behaviors/dependency_resolution_behavior_spec.zig) | FR-5, FR-6, FR-7 | Recursive discovery, classification, cascade priority, fail-fast, versioned deps, cycle detection, buildorder display |
| [git_clone_behavior_spec.zig](behaviors/git_clone_behavior_spec.zig) | FR-8 | Clone to cache, pkgbase resolution, idempotent clone, --recurse, --clean, AURDEST |
| [package_building_behavior_spec.zig](behaviors/package_building_behavior_spec.zig) | FR-9 | makepkg invocation, --syncdeps, topo order, aurpkgs refresh, PKGDEST, split packages, log capture, --needed/--rebuild |
| [sync_workflow_behavior_spec.zig](behaviors/sync_workflow_behavior_spec.zig) | FR-10 | Full workflow, review, confirmation, install targets only, --asdeps, --noconfirm, --noshow, --ignore |
| [outdated_upgrade_behavior_spec.zig](behaviors/outdated_upgrade_behavior_spec.zig) | FR-12, FR-13 | Outdated detection, version comparison, --devel VCS check, upgrade workflow, --rebuild, filter by targets |
| [cache_cleanup_behavior_spec.zig](behaviors/cache_cleanup_behavior_spec.zig) | FR-18 | Stale clone/log detection, size display, confirmation prompt, --noconfirm, --quiet |
| [local_repo_behavior_spec.zig](behaviors/local_repo_behavior_spec.zig) | FR-14, NFR-2 | Auto-create, repo-add -R, valid pacman repo, config check, atomic updates, build isolation |
| [cli_options_behavior_spec.zig](behaviors/cli_options_behavior_spec.zig) | FR-15, FR-16, NFR-3, NFR-4 | Help, version, unknown commands, exit codes, security review, root rejection, signal handling, sudo |

## Property Specifications

| File | Module | Properties Verified |
|------|--------|-------------------|
| [alpm_version_property_spec.zig](properties/alpm_version_property_spec.zig) | `alpm.vercmp` | Antisymmetry, reflexivity, transitivity, epoch dominance, pkgrel secondary, determinism |
| [solver_property_spec.zig](properties/solver_property_spec.zig) | `solver.Solver` | Ordering (deps before dependents), completeness, no duplicates, pkgbase dedup, target marking, exclusion, cycle detection termination, determinism |
| [registry_property_spec.zig](properties/registry_property_spec.zig) | `registry.Registry` | Cascade priority, cache idempotency, batch equivalence, invalidation correctness/isolation, constraint re-check, order independence |
| [aur_property_spec.zig](properties/aur_property_spec.zig) | `aur.Client` | Cache consistency, batch splitting correctness, cache monotonicity, search independence, field completeness, idempotent fetch |
| [repo_property_spec.zig](properties/repo_property_spec.zig) | `repo.Repository` | ensureExists idempotency, filename parsing roundtrip, add idempotency, clean safety, split package completeness, config instructions stability |
| [git_property_spec.zig](properties/git_property_spec.zig) | `git.*` | Clone idempotency, cleanup on failure, cloneOrUpdate completeness, path traversal safety, PKGBUILD-first ordering, listFiles completeness, isCloned consistency |
| [devel_property_spec.zig](properties/devel_property_spec.zig) | `devel.*` | Suffix completeness/exclusivity, case sensitivity, version format, epoch inclusion, field order independence, pkgbase isolation, whitespace tolerance |

## Traceability Matrix

| Requirement | Contract Spec | Behavior Spec | Property Spec |
|-------------|--------------|---------------|---------------|
| FR-1: AUR RPC Integration | aur_contract | aur_rpc_behavior | aur_property |
| FR-2: Package Info Display | commands_contract | package_info_behavior | — |
| FR-3: Package Search | commands_contract | package_search_behavior | — |
| FR-4: Libalpm Database Integration | alpm_contract, pacman_contract | libalpm_behavior | alpm_version_property |
| FR-5: Dependency Resolution | solver_contract, registry_contract | dependency_resolution_behavior | solver_property, registry_property |
| FR-6: Provider Resolution | registry_contract, pacman_contract | dependency_resolution_behavior | registry_property |
| FR-7: Build Order Generation | solver_contract | dependency_resolution_behavior | solver_property |
| FR-8: Git Clone Management | git_contract | git_clone_behavior | git_property |
| FR-9: Package Building | commands_contract, repo_contract | package_building_behavior | repo_property |
| FR-10: Package Sync | commands_contract | sync_workflow_behavior | — |
| FR-11: Package Show/Review | commands_contract | sync_workflow_behavior | — |
| FR-12: Outdated Detection | commands_contract | outdated_upgrade_behavior | — |
| FR-13: Package Upgrade | commands_contract, devel_contract | outdated_upgrade_behavior | devel_property |
| FR-14: Local Repository | repo_contract | local_repo_behavior | repo_property |
| FR-15: Global CLI Options | main_contract | cli_options_behavior | — |
| FR-16: Privilege Escalation | utils_contract | cli_options_behavior | — |
| FR-17: Pacman Configuration | pacman_contract | libalpm_behavior | — |
| FR-18: Cache Cleanup | commands_contract, repo_contract | cache_cleanup_behavior | repo_property |
| NFR-2: Reliability | commands_contract | local_repo_behavior, cli_options_behavior | solver_property |
| NFR-3: Security | git_contract | cli_options_behavior | git_property (path traversal) |
| NFR-4: Usability | main_contract | cli_options_behavior | — |

## Running Specifications

Once implementation exists, specifications can be compiled and run with:

```bash
# Run all contract specs
zig test docs/specifications/aurodle/contracts/aur_contract_spec.zig

# Run all behavior specs
zig test docs/specifications/aurodle/behaviors/sync_workflow_behavior_spec.zig

# Run all property specs (deterministic via fixed seed)
zig test docs/specifications/aurodle/properties/solver_property_spec.zig
```

**Note**: All specification files currently contain `TODO` comments for imports and assertions. These become executable tests once the corresponding `src/*.zig` modules are implemented. The test structure, naming, and assertions are complete — only the `@import` and uncommented code blocks need activation.

## Specification Conventions

1. **Contract test names**: Describe the obligation directly — `"method returns X for Y input"`
2. **Behavior test names**: Follow Given/When/Then — `"given X when Y then Z"`
3. **Property test names**: State the invariant — `"antisymmetry: vercmp(a,b) and vercmp(b,a) have opposite signs"`
4. **Fixed PRNG seed**: All property specs use `seed = 42` for deterministic, reproducible test runs
5. **100 iterations**: Property tests default to 100 random inputs per invariant
6. **Traceability**: Every file header references source architecture and requirements documents
