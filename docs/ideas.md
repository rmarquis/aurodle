# Ideas

Ideas for future development. Nothing here is scheduled; items get picked up as development resources allow.

## `--format` custom output formatting

Field-placeholder output for `info` and `search`, e.g. `{name}`, `{depends:, }`, `{modified:%Y-%m-%d}`, with array delimiters and strftime date formatting.

## `--raw` JSON output

Print the raw AUR RPC JSON for `info` and `search`, for scripting.

## Regex search with `--literal` toggle

Regex pattern matching for search terms instead of plain substring matching, with `--literal` to opt out.

## Search sorting by date

`--sort` / `--rsort` by `firstsubmitted` and `lastmodified`, in addition to name, votes, and popularity.

## `buildorder --quiet` and `--resolve-deps`

`--quiet` to print only the AUR packages that need building. `--resolve-deps <deplist>` to choose which dependency types (depends, makedepends, checkdepends) are considered.

## `clone` updates and `--clean`

Make `clone` update existing clones instead of reporting them as already cloned (`sync` already fetches), and add `--clean` to remove a clone before cloning again.

## `show` improvements

Syntax highlighting for PKGBUILD display, and `--file <filename>` to show a single file from the clone.

## Build logs

Capture makepkg output to `~/.cache/aurodle/logs/<pkgbase>.log` while still displaying it in real time, report the log path on build failure, and have `clean` remove stale logs.

## `--rmdeps`

Remove makedepends after a successful build. Mostly moot with `--chroot`.

## Concurrency lock

A lock file to prevent concurrent aurodle instances from corrupting shared state (repository database, clone directories).

## Clean SIGINT handling

On Ctrl+C, abandon the current operation cleanly: keep completed builds and repo-adds, terminate the in-progress build, and make sure its partial output is not added to the repository.

## Repository integrity check

Validate the local repository on startup, for example database entries whose package file is missing (`clean` already removes these).

## Structured error messages

A consistent `error: <category>: <issue>` structure with context and a suggested fix, and a parseable log output format.

## News integration

Display the latest Arch news (from archlinux.org news RSS) before system upgrades, so users can catch announcements that require manual intervention.

## GPG package signing

Sign built packages with GPG. This concerns the packages themselves; the local repository database is unsigned per Resolved Design Decision 6 in [requirements/aurodle-aur-helper.md](requirements/aurodle-aur-helper.md).
