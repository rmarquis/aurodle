# aurodle

An AUR helper that builds packages into a local pacman repository.

Packages are built with makepkg, and pacman then installs and upgrades them like any other package.

Two programs share the same code:

- `aurodle` works on AUR packages only, with its own commands (`sync`, `upgrade`, `search`, ...).
- `pacsaur` takes pacman's command line (`-S`, `-Syu`, `-Ss`, ...) and runs each operation on pacman, on the AUR, or on both in turn.

Named after Urodela, the salamander order, as a nod to Zig's mascot Suzie.

## Dependencies

- zig
- libalpm (pacman)
- git
- scdoc (for the man pages)

## Installation

aurodle is available on the AUR as [`aurodle-git`](https://aur.archlinux.org/packages/aurodle-git).

```bash
git clone https://aur.archlinux.org/aurodle-git.git
cd aurodle-git
makepkg -si
```

## Usage

### aurodle

```bash
aurodle sync <package>        # build and install a package
aurodle build <package>       # build without installing
aurodle upgrade               # upgrade outdated AUR packages
aurodle search <query>        # search the AUR
aurodle info <package>        # show package details
aurodle outdated              # list outdated AUR packages
aurodle clean                 # remove uninstalled built packages
aurodle clone <package>       # clone AUR package repositories
aurodle show <package>        # display package build files
aurodle resolve <package>     # show dependency tree
aurodle buildorder <package>  # show build order (machine-readable)
aurodle status                # show infrastructure status
```

### pacsaur

```bash
pacsaur -S <package>...       # install official and AUR packages
pacsaur -S aur/<package>      # take a package from the AUR
pacsaur -Sw <package>...      # download or build without installing
pacsaur -Syu                  # upgrade the system, then AUR packages
pacsaur -Ss <query>           # search the sync databases and the AUR
pacsaur -Si <package>...      # show package details
pacsaur -Qu                   # list upgradable packages
pacsaur -Sc                   # clean the package cache and built packages
pacsaur -Rns <package>        # any other operation goes to pacman
pacsaur --dry-run -Syu        # show what would run, without running it
```

Official targets go to pacman, others to the AUR. Run pacsaur as a normal user: pacman steps that need root use `PACMAN_AUTH`. See `pacsaur(1)`.

## Building

**Development build:**

```bash
zig build
```

**Release build:**

```bash
zig build --release=safe
```

Both build `zig-out/bin/aurodle` and `zig-out/bin/pacsaur`. The man pages are built with scdoc:

```bash
scdoc < man/aurodle.1.scd > aurodle.1
scdoc < man/pacsaur.1.scd > pacsaur.1
```

Shell completions are in `completions/`.

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

pacsaur needs this setup for AUR packages only; official packages work without it.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `AURDEST` | `$XDG_CACHE_HOME/aurodle`, or `~/.cache/aurodle` | Directory where AUR package sources are cloned. |
| `PKGDEST` | from `makepkg.conf` | Directory where built packages are placed. Overrides the value in the `makepkg.conf` files, which aurodle reads in makepkg's order: `/etc/makepkg.conf`, `/etc/makepkg.conf.d/*.conf`, then `$XDG_CONFIG_HOME/pacman/makepkg.conf` or, if that file is missing, `~/.makepkg.conf`. |
| `PKGEXT` | `.pkg.tar.zst` | Package file extension. Overrides the value in `makepkg.conf`. |
| `PACMAN_AUTH` | from `makepkg.conf` | Privilege escalation command passed to pacman (e.g. `sudo`). Overrides the value in `makepkg.conf`. |
| `CHROOT_DIR` | `/var/lib/aurodle/chroot` | Chroot root directory used with the `--chroot` flag. |
| `PAGER` | — | Pager used to review PKGBUILDs before building. Falls back to `VISUAL`, then `EDITOR`. |
| `VISUAL` | — | Fallback editor/pager for PKGBUILD review when `PAGER` is unset. |
| `EDITOR` | — | Fallback editor for PKGBUILD review when `PAGER` and `VISUAL` are unset. |
