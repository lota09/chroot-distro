# chroot-distro development plan

## 1) Planned features (4 items)

- Config-driven setup: Linux Deploy-style .conf parsing and mapping
- Safe stop/unmount: full cleanup without system damage
- Post-setup automation: ssh, vnc, network, users, desktop
- Termux GPU setup: host + chroot wiring for acceleration (termux-only)

## 2) Two-track strategy

- Initial setup script: docs/chroot_distro_ubuntu_init.sh
  - Runs inside chroot, applies base fixes, users, desktop, optional ssh/vnc/pulse
- Host wrapper (start script)
  - Mounts, starts services, launches desktop, then enters shell
  - Keeps service start/stop and mounts out of the chroot itself

## 3) New commands (alias: chd)

- chd start ubuntu
  - Mount installed distro
  - Run host wrapper (start script)
  - Enter shell

- chd login ubuntu
  - Do not mount
  - Enter shell only (avoid duplicate mounts/services)

- Alternative: merge behavior
  - chd login ubuntu
    - If not mounted -> mount + start script + shell
    - If mounted -> shell only

- chd config
  - Create or edit .conf files

- (deferred) chd setgpu ubuntu
  - Termux-only GPU acceleration setup

## 4) Changed command behavior

- chd install ubuntu
  - Install
  - Mount
  - Run initial setup script
  - Run start script
  - Enter shell
