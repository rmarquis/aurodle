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

aurodle builds AUR packages into a local pacman repository. Before using it, create the repository directory and register it with pacman.

**1. Create the repository directory:**

```bash
sudo install -d -o $USER /var/lib/aurodle/aur
```

**2. Add the repository to `/etc/pacman.conf`:**

```ini
[aur]
SigLevel = Optional TrustAll
Server = file:///var/lib/aurodle/aur
```

**3. Set PKGDEST in `/etc/makepkg.conf`:**

```bash
PKGDEST=/var/lib/aurodle/aur
```

This tells makepkg to place built packages directly into the local repository.

**4. Create an empty local aur repo database**

```bash
repo-add /var/lib/aurodle/aur/aur.db.tar.xz
```

**5. Sync the database:**

```bash
sudo pacman -Syu
```

After setup, packages built with `aurodle sync <package>` will be added to the local repository and installed via pacman.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `AURDEST` | `~/.cache/aurodle` | Directory where AUR package sources are cloned. |
| `PKGDEST` | from `makepkg.conf` | Directory where built packages are placed. Overrides the value in `/etc/makepkg.conf` and `~/.makepkg.conf`. |
| `PKGEXT` | `.pkg.tar.zst` | Package file extension. Overrides the value in `makepkg.conf`. |
| `PACMAN_AUTH` | from `makepkg.conf` | Privilege escalation command passed to pacman (e.g. `sudo`). Overrides the value in `makepkg.conf`. |
| `CHROOT_DIR` | `/var/lib/aurodle/chroot` | Chroot root directory used with the `--chroot` flag. |
| `PAGER` | — | Pager used to review PKGBUILDs before building. Falls back to `VISUAL`, then `EDITOR`. |
| `VISUAL` | — | Fallback editor/pager for PKGBUILD review when `PAGER` is unset. |
| `EDITOR` | — | Fallback editor for PKGBUILD review when `PAGER` and `VISUAL` are unset. |
