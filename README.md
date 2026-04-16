# aurodle

An AUR helper that builds packages into a local repository.
Named after Urodela — the salamander order — as a nod to Zig's mascot Suzie.

Packages are built with makepkg and added to a local pacman repo, so pacman handles installs and upgrades natively.

## Dependencies

- zig
- libalpm (pacman)
- git

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
sudo pacman -Sy
```

After setup, packages built with `aurodle sync <package>` will be added to the local repository and installed via pacman.
