pacsaur(1)

# NAME

pacsaur - pacman's command line for official and AUR packages

# SYNOPSIS

*pacsaur* <operation> [options] [targets...]

# DESCRIPTION

Pacsaur takes *pacman*(8) operations and options, and runs each on pacman,
on the AUR commands of *aurodle*(1), or on both in turn, pacman first. AUR
packages are built into aurodle's local repository and installed from
it, so AUR packages need the setup described in *aurodle*(1). Official
packages do not.

# OPERATIONS

## Operations on official and AUR packages

*-S* <target>...
	Install _targets_: official ones with pacman, the others from the
	AUR. With *-y*, pacman refreshes the databases first, even if every
	target is from the AUR.

*-Sw* <target>...
	Download official _targets_ and build AUR ones into the local
	repository, without installing anything.

*-Si* <target>...
	Display information on official _targets_ from pacman, and on the
	others from the AUR.

*-Ss* <term>...
	Search the sync databases, then the AUR. The local AUR repository is
	left out of pacman's results; the AUR results show the installed
	version instead. Without _terms_, only pacman lists its packages.

*-Su* [target...]
	Upgrade the system, then outdated AUR packages. Official _targets_ are
	installed with the system upgrade, and AUR ones with the AUR upgrade.

*-Suw* [target...]
	Download the system upgrades, and build outdated AUR packages into the
	local repository, without installing anything. Official _targets_ are
	downloaded and AUR ones built. A later *-Su* installs what was built
	without building it again.

*-Qu*
	List upgradable packages, then outdated AUR packages.

*-Sc*, *-Scc*
	Clean pacman's package cache, then aurodle's built packages and clones
	as *aurodle clean* does, or *aurodle clean --all* with *-Scc*.

## Other operations

Any other operation goes to pacman alone, including *-Sy* without
targets, *-Sl*, *-Sg* and any *-S* operation with *-p*.

# TARGETS

A target in an official repository, or a group or a package provided by
one, goes to pacman. A target in the local AUR repository goes to the
AUR side, which checks it for an update before installing it, and any
other target is taken from the AUR. Only the local databases are read to
decide.

*aur/*<name>
	Take _name_ from the AUR.

<repo>*/*<name>
	Take _name_ from repository _repo_, with pacman.

# OPTIONS

## Pacsaur options

*-h*, *--help*
	Show help and exit.

*-V*, *--version*
	Show version and exit.

*--dry-run*
	Print the steps that would run, and exit.

*--repo*
	Send the whole command to pacman.

*--aur*
	Send the whole command to the AUR side. Only the operations above are
	available.

## Options for both sides

*--needed*, *--noconfirm*, *--asdeps*, *--asexplicit*, *--ignore* <pkg>[,<pkg>...], *-q*, *--quiet*
	Passed to pacman, and applied to AUR packages as in *aurodle*(1).

Any other pacman option is passed to pacman only.

## AUR options

These apply to AUR packages only, and are never passed to pacman. Using
one with an operation that has no AUR step is an error.

*--noshow*
	Skip the build file review.

*--rebuild*
	Rebuild packages already built or up to date.

*--chroot*
	Build in a clean chroot.

*--devel*
	With *-Su* and *-Qu*, also check VCS packages for updates.

*--all*
	With *-Su* and *-Qu*, also check the packages in the local AUR
	repository that are not installed. *-Su* builds them into the
	repository without installing them.

*--by* <field>, *--sort* <field>, *--rsort* <field>
	With *-Ss*, search the AUR by _field_ and sort the results.

See *aurodle*(1) for details.

# EXIT STATUS

The exit status of the last step that ran. Usage errors exit with 2.

# ENVIRONMENT

*PACMAN_AUTH*
	Command used to run the pacman steps that need root, as for
	*aurodle*(1). Defaults to *sudo*, falling back to *su*.

AUR steps read the same environment and configuration as *aurodle*(1).

# NOTES

Run pacsaur as a normal user. When a pacman step needs root, credentials
are checked before any step runs, so a refused password changes nothing.
AUR packages are never built as root: such a command is refused before
any step runs.

# SEE ALSO

*aurodle*(1), *pacman*(8), *makepkg*(8)

# AUTHORS

Rémy Marquis <remy.marquis@gmail.com>
