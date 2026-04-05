# chroot-distro

chroot-distro installs and manages GNU/Linux distributions in a chroot on Android.
The workflow is profile-based and supports multiple suites and multiple instances per suite.

## Highlights

- Profile-based installs (conf files) with prompts and sane defaults.
- Suite-aware rootfs archives (`ubuntu-noble.tar.xz`, etc.).
- Instance-based lifecycle: install, backup, restore, rename, uninstall.
- Optional automated init for Ubuntu via `chroot_ubuntu_init.sh`.
- Safe unmount flow with force and residual checks.
- Works as a Magisk module; `chd` is available as a short alias.

## Requirements

- Rooted Android device (Magisk / KernelSU / APatch).
- BusyBox for Android NDK is recommended (v1.36.1+).

## Paths and layout

Default path: `/data/local/chroot-distro` (or `/opt/chroot-distro` on GNU/Linux).

```
/data/local/chroot-distro/
├── .backup/           # Instance backups
├── .rootfs/           # Downloaded rootfs archives
├── .profile/          # Profile configs (<name>.conf)
├── .config/           # Installed instance configs (<instance>.conf)
└── <instance>/        # Instance rootfs
```

## Quick start

```bash
# create or edit a profile
chd profile my_profile

# install the instance using the profile
chd install my_profile

# login
chd login my_profile
```

## Command overview

```bash
# general
chd help
chd env
chd list [-i|--installed]

# profiles
chd profile [name]

# install / uninstall
chd install [--no-init] <profile>
chd uninstall [-f|--force] [--include-profile] <instance>

# download and rootfs
chd download [--force] <distro> [suite-or-url]
chd delete <distro>            # suite-aware
chd remove <distro>            # suite-aware

# runtime
chd login <instance>
chd command <instance> <command>
chd mount <instance>
chd unmount <instance|all> [-f|--force] [-a|--all]

# backups
chd backup <instance> [path]
chd restore <instance> [-d|--default] [--force] [path]
chd unbackup <instance>
chd rename <old_instance> <new_instance>
```

Notes:
- `download` prompts for suites when needed. Use `--force` to overwrite an existing rootfs.
- `uninstall` keeps `.config/<instance>.conf` unless `--include-profile` is used.
- `remove` deletes all instances for a suite and its rootfs. Backups are preserved.

## Supported distros

See `system/bin/chroot-distro` for the current list. Use lowercase identifiers.

## Configuration

Environment variables:

```bash
export CHROOT_DISTRO_PATH=<path>
export CHROOT_DISTRO_BUSYBOX=<path>
export CHROOT_DISTRO_TMP=false
export CHROOT_DISTRO_EXIT=false
export CHROOT_DISTRO_MOUNT=false
export CHROOT_DISTRO_LOG=<value>
```

## Docs

- [docs/how-to.md](docs/how-to.md)
- [docs/android_gui.md](docs/android_gui.md)
- [docs/development_guide.md](docs/development_guide.md)
- [docs/development_plan.md](docs/development_plan.md)

## License

GPLv3. See [LICENSE](LICENSE).
