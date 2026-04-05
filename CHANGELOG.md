# What's Changed

### Major Fixes
- Added safe unmount handling for dynamic mount points and loopbacks.
- Prevented path duplication when unmounting self-bind mounts.
- Fixed duplicate Android group injection in `prepare_chroot_distro`.
- Fixed user-facing messages that accidentally printed `$script` literally.

### Improvements
- Profile-based installs and instance management (multiple suites and instances).
- Suite-aware `download`, `delete`, and `remove` behavior.
- Instance-based `backup`, `restore`, `unbackup`, and `rename`.
- `download --force` overwrite support and merged redownload behavior.
- `uninstall` keeps instance config by default; `--include-profile` removes it.

### Documentation
- Updated development plan and command behavior details.
- Refresh README to match profile-based workflow and `chd` alias.
