aurodle(1)

# NAME

aurodle - an AUR helper that builds packages into a local repository

# SYNOPSIS

*aurodle* <command> [options] [targets...]

# DESCRIPTION

Aurodle is an Arch User Repository (AUR) helper where *pacman*(8) handles
all installation and dependency management natively, keeping user interaction
to a minimum. Rather than installing
packages directly, aurodle builds them into a local pacman repository via
*repo-add*(8), after which pacman installs them as if they were official
packages. This means AUR packages participate in normal pacman operations:
they appear in `pacman -Q`, are removed with `pacman -R`, and satisfy
dependencies for other packages.

To achieve this, aurodle resolves dependency trees through the AUR RPC
interface, clones build files, and builds packages with makepkg. It requires
a local pacman repository to be configured in _pacman.conf_ before first use.

# COMMANDS

## Build and install commands

*sync*, *-S* <target>...
	Resolve dependencies, clone build files, build, and install _target(s)_.
	Missing AUR dependencies are built and installed automatically.

*build*, *-Sw* <target>...
	Like *sync* but stops after adding packages to the local repository.
	Does not invoke pacman to install them.

*upgrade*, *-Su* [target...]
	Upgrade outdated AUR packages. Without arguments, upgrades all foreign
	packages and packages present in the local AUR repository that have a
	newer version in the AUR. If _targets_ are given, only those packages
	are upgraded.

## Query commands

*search*, *-Ss* <term>...
	Search the AUR for packages matching _term_. Multiple terms return the
	intersection of results. Output shows name, version, votes, and
	popularity. Packages marked out of date are highlighted.

*info*, *-Si* <target>...
	Display detailed information for _target(s)_ from the AUR.

*outdated*, *-Qu* [target...]
	List foreign packages and packages present in the local AUR repository
	that have a newer version available in the AUR. Without arguments,
	checks all such packages. With *--devel*, also checks VCS packages by
	fetching their upstream source.

## Repository management commands

*clone* <target>...
	Clone AUR package repositories into the cache directory without
	building. Use *--recurse* to also clone AUR dependencies.

*show* <target>
	Display the PKGBUILD and install scripts for _target_.

*clean*, *-Sc*
	Remove stale built packages from the local repository (packages no
	longer installed) and offer to clean the source cache.

*clean --all*, *-Scc*
	Remove all built packages and sources from the local repository and
	cache.

## Utility commands

*resolve* <target>...
	Display the resolved dependency tree for _target(s)_ without building
	anything.

*buildorder* <target>...
	Print the resolved dependency information for _target(s)_, one entry per
	line, intended for scripting. Each line has the format:

	```
	PREFIX pkgbase pkgname
	```

	or, when the pkgbase is not known:

	```
	PREFIX pkgname
	```

	The pkgbase is always present for *AUR* and *TARGETAUR* entries. It is
	present for *REPOAUR* and *SATISFIEDAUR* entries only if AUR metadata
	was fetched for that package during the current invocation. Repository
	entries (*REPOS*, *SATISFIEDREPOS*, *TARGETREPO*) only carry a pkgname.

	Classification tokens:

	*TARGETAUR*      explicitly requested, will be built from AUR
	*TARGETREPO*     explicitly requested, available in official repositories
	*AUR*            AUR dependency, will be built
	*REPOS*          repository dependency, will be installed via pacman
	*REPOAUR*        available in the local AUR repository, already current
	*SATISFIEDAUR*   already installed from AUR, no action needed
	*SATISFIEDREPOS* already installed from official repositories
	*UNKNOWN*        not found in any source

*status*
	Check connectivity to the AUR RPC endpoint and the local repository
	configuration.

# OPTIONS

## Global options

*-h*, *--help*
	Show help and exit.

*-v*, *--version*
	Show version and exit.

*-q*, *--quiet*
	Reduce output verbosity. For *search*, shows only package names.

## Build options

*--noconfirm*
	Skip all confirmation prompts. Use with care in automated contexts.

*--noshow*
	Skip the PKGBUILD review step before building.

*--needed*
	Skip packages that are already up to date. For VCS packages, the
	source is still checked out but the build is skipped if the upstream
	version matches.

*--rebuild*
	Force a rebuild even if a package is already present in the local
	repository or is up to date.

*--asdeps*
	Mark installed packages as dependencies.

*--asexplicit*
	Mark installed packages as explicitly installed.

*--devel*
	Also consider VCS packages (names ending in *-git*, *-svn*, *-hg*,
	*-bzr*) when checking for upgrades. Each package's upstream source is
	fetched to determine the current version.

*--ignore* <pkg>[,<pkg>...]
	Skip _pkg_ during build and upgrade operations. Accepts a
	comma-separated list or multiple *--ignore* flags. Packages listed in
	_pacman.conf_ *IgnorePkg* are also honored.

*--chroot*
	Build packages inside a clean chroot using *makechrootpkg*(1).

## Clone options

*--recurse*
	When using the *clone* command, also recursively clone AUR
	dependencies.

## Clean options

*--all*
	Remove all built packages and all sources, not just stale ones.
	Equivalent to *-Scc*.

## Search options

*--by* <field>
	Search by _field_. Valid values: *name*, *name-desc* (default),
	*maintainer*.

*--sort* <field>
	Sort results in ascending order by _field_. Valid values: *name*,
	*votes*, *popularity*.

*--rsort* <field>
	Sort results in descending order by _field_.

# ENVIRONMENT

*AURDEST*
	Directory where AUR package repositories are cloned. Defaults to
	_$XDG\_CACHE\_HOME/aurodle_ (falling back to _~/.cache/aurodle_).

*PKGDEST*
	Directory where built packages are stored. Must be set in
	_/etc/makepkg.conf_ and match the *Server = file://* path of a
	repository configured in _pacman.conf_. This is the primary mandatory
	configuration item for aurodle.

*PACMAN_AUTH*
	Command used to elevate privileges when invoking pacman. Parsed from
	_makepkg.conf_. Supports *sudo*(8), *run0*(1), *doas*(1), *su*(1),
	or any compatible tool. The placeholder *%c* is substituted with the
	command to run. Defaults to *sudo* if unset, falling back to *su*.

*PAGER*, *VISUAL*, *EDITOR*
	Selects the program used to review PKGBUILD and install scripts before
	building. Checked in this order: *PAGER*, then *VISUAL*, then *EDITOR*.
	Falls back to *vim*(1) if none are set.

In addition, all makepkg environment variables are honored. See
*makepkg*(8).

# CONFIGURATION

Aurodle does not have its own configuration file. It is configured
entirely through existing system files:

## /etc/makepkg.conf

_PKGDEST_ must be set to the directory where aurodle stores built
packages:

```
PKGDEST=/var/lib/aurodle/aur
```

## /etc/pacman.conf

A repository section must exist whose *Server* directive points to
_PKGDEST_ via a *file://* URL:

```
[aur]
SigLevel = Optional TrustAll
Server = file:///var/lib/aurodle/aur
```

The repository name can be anything. Aurodle detects it automatically by
matching the *Server* path to _PKGDEST_.

# NOTES

## Required initial setup

Aurodle requires a local pacman repository to be configured before first
use. The *build* or *sync* commands will print setup instructions and exit
if this configuration is missing.

## Privilege escalation

Aurodle never runs makepkg as root. Privilege escalation is only used for
*pacman -S* installation steps, using the configured _PACMAN\_AUTH_
command (such as *sudo*(8), *run0*(1), or *doas*(1)).

## Privilege escalation session

Long builds can outlast a privilege escalation session. Aurodle keeps
the session alive automatically while building to prevent mid-build
authentication failures.

## Build file review

Before building, aurodle shows the PKGBUILD and install scripts for each
package. Use *--noshow* to skip this step or *--noconfirm* to also skip
the confirmation prompt.

## Conflict detection

Before building, aurodle checks for conflicts between packages being
installed and packages already installed on the system, including
*provides* relationships. Conflicts are reported as warnings; the build
is not aborted automatically.

# SEE ALSO

*pacman*(8), *makepkg*(8), *repo-add*(8), *run0*(1), *doas*(1), *sudoers*(5)

# AUTHORS

Rémy Marquis <remy.marquis@gmail.com>
