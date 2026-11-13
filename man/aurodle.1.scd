aurodle(1)

# NAME

aurodle - an AUR helper that builds packages into a local pacman repository

# SYNOPSIS

*aurodle* <command> [options] [targets...]

# DESCRIPTION

Aurodle builds Arch User Repository (AUR) packages with *makepkg*(8) into a
local pacman repository via *repo-add*(8), after which *pacman*(8) installs
them as if they were official packages. They appear in *pacman -Q*, are
removed with *pacman -R*, and satisfy dependencies for other packages.

A local pacman repository must be configured in _pacman.conf_ before first
use.

# COMMANDS

## Build and install commands

*sync*, *-S* <target>...
	Resolve dependencies, clone build files, build, and install _target(s)_.
	Missing AUR dependencies are built and installed automatically.

*build*, *-Sw* <target>...
	Like *sync* but stops after adding packages to the local repository.
	Does not invoke pacman to install them.

*upgrade*, *-Su* [target...]
	Upgrade outdated AUR packages. Without arguments, upgrades all
	installed foreign packages, including those installed from the local
	AUR repository, that have a newer version in the AUR. If _targets_ are
	given, only those packages are upgraded.

## Query commands

*search*, *-Ss* <term>...
	Search the AUR for packages matching _term_. Multiple terms return the
	intersection of results. Output shows name, version, votes, and
	popularity. Packages marked out of date are highlighted.

*info*, *-Si* <target>...
	Display detailed information for _target(s)_ from the AUR.

*outdated*, *-Qu* [target...]
	List installed foreign packages, including those installed from the
	local AUR repository, that have a newer version available in the AUR.
	Without arguments, checks all such packages. With *--devel*, also
	checks VCS packages by fetching their upstream source.

	Packages in the local AUR repository that are not installed are not
	checked, since the repository may be shared. Instead, *sync*, *build*,
	*resolve* and *buildorder* warn when a dependency they take from it is
	older than the AUR.

## Repository management commands

*clone* <target>...
	Clone AUR package repositories into the cache directory without
	building. Use *--recurse* to also clone AUR dependencies.

*show* <target>
	Display the PKGBUILD and install scripts for _target_.

*clean*, *-Sc*
	Remove built packages and clones of packages no longer installed, old
	package files the repository database no longer references, and
	database entries of uninstalled packages whose file is missing.

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

	The pkgbase is present for *AUR*, *TARGETAUR*, *REPOAUR* and
	*SATISFIEDAUR* entries. When AUR metadata was not fetched for a
	*SATISFIEDAUR* or *REPOAUR* entry, the pkgbase is read from the local
	package database or the local AUR repository. For a dependency met
	through a provision, it is the pkgbase of the package that provides
	it. Repository entries (*REPOS*, *SATISFIEDREPOS*, *TARGETREPO*) only
	carry a pkgname.

	Classification tokens:

	*TARGETAUR*      explicitly requested from AUR, built unless up to date

	*TARGETREPO*     explicitly requested, available in official repositories

	*AUR*            AUR dependency, will be built

	*REPOS*          repository dependency, will be installed via pacman

	*REPOAUR*        installed from the local AUR repository as is; a
	warning notes a newer AUR version

	*SATISFIEDAUR*   already installed from AUR, no action needed

	*SATISFIEDREPOS* already installed from official repositories

	*UNKNOWN*        not found in any source

	Entries are classified against the host, and the dependencies of
	satisfied packages are not listed. With *--chroot*, AUR packages
	installed on the host do not count: the output is the build order
	for a clean chroot.

	With *--quiet*, only the *AUR* and *TARGETAUR* lines of packages that
	get built are printed.

*status*
	Show the status of Arch Linux infrastructure from status.archlinux.org:
	each service's current state, daily uptime over the last 30 days, and
	90-day uptime ratio.

# OPTIONS

## Global options

*-h*, *--help*
	Show help and exit.

*-V*, *--version*
	Show version and exit.

*-q*, *--quiet*
	Reduce output verbosity. For *search*, shows only package names; for
	*buildorder*, only the packages to build.

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
	Build packages inside a clean chroot using *makechrootpkg*(1), from
	the *devtools* package. See *Clean chroot builds* under *NOTES*.
	With *resolve* and *buildorder*, resolve dependencies as for a chroot
	build, ignoring AUR packages installed on the host.

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
	*depends*, *makedepends*, *checkdepends*, *optdepends*, *maintainer*,
	*submitter*, *provides*, *conflicts*, *replaces*, *keywords*, *groups*,
	*comaintainers*.

*--sort* <field>
	Sort results in ascending order by _field_. Valid values: *name*,
	*votes*, *popularity*.

*--rsort* <field>
	Sort results in descending order by _field_.

# ENVIRONMENT

*CHROOT\_DIR*
	Directory of the clean chroot used by *--chroot*. Defaults to
	_/var/lib/aurodle/chroot_. Must not be on a *nosuid* mount, such as a
	tmpfs _/tmp_.

*AURDEST*
	Directory where AUR package repositories are cloned. Defaults to
	_$XDG\_CACHE\_HOME/aurodle_ (falling back to _~/.cache/aurodle_).

*PKGDEST*
	Directory where built packages are stored. Must be set here or in a
	_makepkg.conf_ file (see *CONFIGURATION*) and match the
	*Server = file://* path of a repository configured in _pacman.conf_.
	This is the primary mandatory configuration item for aurodle.

*PACMAN_AUTH*
	Command used to elevate privileges when invoking pacman. Read from
	here or a _makepkg.conf_ file. Supports *sudo*(8), *run0*(1), *doas*(1),
	*su*(1), or any compatible tool. The placeholder *%c* is substituted
	with the command to run. Defaults to *sudo* if unset, falling back to
	*su*.

*XDG\_CONFIG\_HOME*, *HOME*
	Used to locate the user's _makepkg.conf_.

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

Aurodle reads these files in makepkg's order, and the last assignment wins:

. _/etc/makepkg.conf_
. _/etc/makepkg.conf.d/\*.conf_, in sorted order
. _$XDG\_CONFIG\_HOME/pacman/makepkg.conf_ (by default
  _~/.config/pacman/makepkg.conf_), or _~/.makepkg.conf_ if that file is
  missing

The files are parsed, never executed, so shell expansions such as _$HOME_
are taken literally.

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

Updates are fetched without being applied, so each clone stays at the
version last accepted. A package cloned for the first time is shown in
full. When the AUR has new commits, the review shows the diff from the
version last accepted, even if they were fetched during an earlier,
interrupted run; they are applied once the review is done. When nothing
changed, aurodle only offers the local changes, if any, such as
the _pkgver_ that *makepkg*(8) rewrote for a VCS package. Use *show* to
view all files.

With *--devel*, version checks run on the version last accepted: new AUR
commits are only applied after the review.

## Clean chroot builds

With *--chroot*, packages are built with *makechrootpkg*(1) in a clean
chroot instead of on the host, so build dependencies never get installed
on the host and a PKGBUILD that forgets a dependency fails to build.

The chroot directory (*CHROOT\_DIR*) holds:

_pacman.conf_
	The chroot's pacman configuration, generated on first use from the
	template *devtools* uses for clean builds
	(_/usr/share/devtools/pacman.conf.d/extra.conf_, or _multilib.conf_
	when the host enables *[multilib]*), followed by the local AUR
	repository as the host configures it. The official repositories use
	the host's mirrors, which *arch-nspawn*(1) copies into the chroot on
	every run. The local repository's directory is made available
	read-only inside the chroot, so AUR dependencies are installed from
	it like any other package. Aurodle never overwrites this file: edit
	it to change the repositories used for builds, or delete it to
	generate it again. Its local repository section must keep a
	*file://* server pointing to the repository directory (*PKGDEST*);
	otherwise chroot builds stop with an error.

_makepkg.conf_
	Optional. The *makepkg.conf*(5) for chroot builds; without it, the one
	*devtools* uses for clean builds
	(_/usr/share/devtools/makepkg.conf.d/<arch>.conf_) is used. It is
	copied into _root_ on every run, and also decides which package files
	count as already built.

_root_
	The pristine chroot, created with *mkarchroot*(1) on first use, with
	*base-devel*, and *multilib-devel* when _pacman.conf_ enables
	*[multilib]*, and upgraded once at the start of each run.

Each package is built in a fresh copy of _root_, into an empty
staging directory in the cache (_chroot-pkgdest_), and what the build
produced is then moved into the local repository. Repository dependencies
are chosen by makepkg inside the chroot, so provider choices made before
the build do not apply to chroot builds. For a VCS package,
*makepkg --nobuild --nodeps* first runs _pkgver()_ on the host, installing
nothing, so a version already in the repository is not built again; if
that fails, the package is built anyway. AUR packages installed on the
host do not count as available: an AUR dependency missing from the local
repository is built, even if it is installed.

## Conflict detection

Before building, aurodle checks for conflicts between packages being
installed and packages already installed on the system, including
*provides* relationships. Conflicts are reported as warnings; the build
is not aborted automatically.

# SEE ALSO

*pacman*(8), *makepkg*(8), *repo-add*(8), *run0*(1), *doas*(1), *sudoers*(5)

# AUTHORS

Rémy Marquis <remy.marquis@gmail.com>
