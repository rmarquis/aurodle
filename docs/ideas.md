# Ideas

Ideas for future development. Nothing here is scheduled; items get picked up as development resources allow.

## `--format` custom output formatting

Field-placeholder output for `info` and `search`, e.g. `{name}`, `{depends:, }`, `{modified:%Y-%m-%d}`, with array delimiters and strftime date formatting. Tracked as a Nice to Have in FR-2 and FR-3 of [requirements/aurodle-aur-helper.md](requirements/aurodle-aur-helper.md).

## Regex search with `--literal` toggle

Regex pattern matching for search terms instead of plain substring matching, with `--literal` to opt out. Tracked as a Nice to Have in FR-3 of [requirements/aurodle-aur-helper.md](requirements/aurodle-aur-helper.md).

## News integration

Display the latest Arch news (from archlinux.org news RSS) before system upgrades, so users can catch announcements that require manual intervention.

## GPG package signing

Sign built packages with GPG. This concerns the packages themselves; the local repository database is unsigned per Resolved Design Decision 6 in [requirements/aurodle-aur-helper.md](requirements/aurodle-aur-helper.md).
