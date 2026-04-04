# chroot-distro development plan

## 1) Planned features (4 items)

- Config-driven setup: Linux Deploy-style .conf parsing and mapping
- Safe stop/unmount: full cleanup without system damage
- Post-setup automation: ssh, vnc, network, users, desktop
- Termux GPU setup: host + chroot wiring for acceleration (termux-only)

## 2) Two-track strategy

- Initial setup script: docs/chroot_distro_ubuntu_init.sh
  - Runs inside chroot, applies base fixes, users, desktop, optional ssh/vnc/pulse
- Start script / chd start
  - Removed from default plan (user preference, not universal)

## 3) Focus areas

- chd login as primary entry point
- Safe mount/unmount handling and idempotent behavior

## 4) New commands (alias: chd)

- chd login ubuntu
  - Mount if needed
  - Enter shell

- chd umount ubuntu
  - Safe unmount and cleanup

- chd config
  - Create or edit .conf files

- (deferred) chd setgpu ubuntu
  - Termux-only GPU acceleration setup

## 5) Changed command behavior

- chd install ubuntu
  - Install
  - Img Mount
  - Run initial setup script
  - Enter shell
