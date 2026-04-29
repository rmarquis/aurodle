# aurodle

An AUR helper that builds packages into a local repository.
Named after Urodela — the salamander order — as a nod to Zig's mascot Suzie.

Packages are built with makepkg and added to a local pacman repo, so pacman handles installs and upgrades natively.

## Dependencies

- zig
- libalpm (pacman)
- git

## Installation

aurodle is available on the AUR as [`aurodle-git`](https://aur.archlinux.org/packages/aurodle-git).

```bash
git clone https://aur.archlinux.org/aurodle-git.git
cd aurodle-git
makepkg -si
```

## Usage

```bash
aurodle sync <package>        # build and install a package
aurodle build <package>       # build without installing
aurodle upgrade               # upgrade outdated AUR packages
aurodle search <query>        # search the AUR
aurodle info <package>        # show package details
aurodle outdated              # list outdated AUR packages
aurodle clean                 # remove stale packages from the local repo
aurodle clone <package>       # clone AUR package repositories
aurodle show <package>        # display package build files
aurodle resolve <package>     # show dependency tree
aurodle buildorder <package>  # show build order (machine-readable)
aurodle status                # show infrastructure status
```

See `aurodle(1)` for all options.

## Building

**Development build:**

```bash
zig build
```

**Release build:**

```bash
zig build --release=safe
```

## Setup

aurodle requires a local pacman repository before first use. Set `PKGDEST` in `/etc/makepkg.conf` and add a matching `file://` repository to `/etc/pacman.conf`:

```ini
# /etc/makepkg.conf
PKGDEST=/var/lib/aurodle/aur
```

```ini
# /etc/pacman.conf
[aur]
SigLevel = Optional TrustAll
Server = file:///var/lib/aurodle/aur
```

Then initialise the repository database:

```bash
sudo install -d -o $USER /var/lib/aurodle/aur
repo-add /var/lib/aurodle/aur/aur.db.tar.xz
sudo pacman -Syu
```

See `aurodle(1)` for full configuration details, usage, and environment variables.
