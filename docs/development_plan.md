# chroot-distro development plan

## 1) Planned features (updated)

- Config-driven setup (profile-based) with interactive prompts
- Safe stop/unmount: full cleanup without system damage
- Termux GPU setup: host + chroot wiring for acceleration (termux-only)

## 3) Focus areas

- chd login as primary entry point
- Safe mount/unmount handling and idempotent behavior

## 4) Deferred / pending

- Add chd setgpu ubuntu (termux-only)

## 5) Commands (alias: chd) and behavior details

### chd profile [profile_name]

- Store profiles at /data/local/chroot-distro/.profile/<name>.conf
- If no argument:
  - If profiles exist: show options (edit existing or create new)
  - If no profiles: go straight to create
- Create/edit flow:
  - Ask for profile name (new only)
  - Prompt for distro, ssh/vnc enable + settings, user/pass, etc.
  - Defaults: default.conf for new profile, existing profile for edits
  - Write <name>.conf

### chd install <profile_name>

- Merges download + install flow using profile settings
- Per-distro init script dispatch (example: ubuntu -> chroot_ubuntu_init.sh)
- Init script runs by default; can be disabled with --no-init
- Instance install path is /data/local/chroot-distro/<profile_name>

Examples:
- chd install my_profile
  - Profile-based install with init
- chd install --no-init my_profile
  - Profile-based install, skip init

### chd download <distro>

- Legacy, explicit download command is kept
- If the rootfs already exists:
  - Prompts to overwrite (or use --force)
- If the distro has suites (ubuntu/debian/kali/etc):
  - Prompts for a suite by number
  - Downloads to <distro>-<suite>.tar.xz
- If the distro has no suite concept (arch/others):
  - No prompt, downloads a single rootfs

### chd list

- Tree view grouped by distro
- Downloaded: suite list
- Installed: profile/instance list
- Backup: profile/instance list

### chd login <instance>

- Primary entry point
- Resolves instance -> distro/suite via .config/<instance>.conf
- Auto-mounts system points before entering

### chd command <instance> <command>

- Same instance resolution and auto-mount behavior as login

### chd mount <instance>

- Mounts system points without entering the shell

### chd unmount <instance|all>

- Instance-aware unmount, with optional -a to unmount all points
- Final safety check prevents removal if mounts/loopbacks remain

### chd uninstall <instance>

- Uninstalls a single instance directory
- Keeps .config/<instance>.conf by default
- Use --include-profile to remove the instance config

### chd backup <instance> [path]

- Instance-based backup (stores instance dir and its .config file)
- Uses instance name for default archive name

### chd restore <instance> [-d|--default] [--force] [path]

- Instance-based restore
- Uses config inside the archive when present
- Warns if config is missing (old backup format)

### chd unbackup <instance>

- Deletes the backup archive for the instance

### chd rename <old_instance> <new_instance>

- Renames instance directory and its .config/.backup files

### chd delete <distro>

- Suite-aware rootfs delete
- If multiple suites exist, prompt by number
- Deletes only the selected rootfs archive

### chd remove <distro>

- Suite-aware removal
- If multiple suites exist, prompt by number
- Removes all instances for the selected suite and its rootfs
- Backups are intentionally preserved

### chd add <distro>

- Registers a custom distro name (creates .config/<name>)
- Does not download or install rootfs by itself

### Implementation notes (completed)

- chroot-distro mount/login/command/unmount
  - System mount points are now auto-mounted on entry (login/command/install) and unmounted on uninstall
  - Added a final residual mount/loopback check after unmount to prevent unsafe removal if anything remains mounted
- chroot-distro list
  - Sanitizes map variable names derived from filesystem entries to avoid errors with names like lost+found
  - Prevents eval errors when non-alnum characters exist in directory names
- chroot-distro mount (image support)
  - Rootfs image mount now retries with explicit ext4 + loop options for Android builds that require it
- docs/chroot_distro_ubuntu_init.sh
  - Now supports Linux Deploy-style conf mapping and INCLUDE-based toggles
  - Optional SSH/Pulse/VNC/X11 and desktop profiles (xfce/lxde/mate/xterm/kde)
  - Verbose debug tracing and step-by-step logging for deterministic runs
  - User creation aligned with Ubuntu default (adduser) and safe chown using primary group