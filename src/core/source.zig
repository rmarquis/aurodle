/// Package resolution source — where a dependency was found during the
/// four-tier lookup cascade (installed → official sync → AUR → provider).
/// Defined here at Layer 0 so both registry.zig and solver/graph.zig can
/// import it without creating a cross-layer cycle.
pub const Source = enum {
    satisfied_repos, // installed locally and available in official repos
    satisfied_aur, // installed locally (AUR / foreign package)
    repos, // not installed, available in official sync databases
    repo_aur, // not installed, available in aurpkgs local repo
    aur, // not installed, needs to be built from AUR
    unknown, // not found anywhere
};
