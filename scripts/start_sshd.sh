#!/bin/sh
set -eu

# Start sshd inside chroot. Intended to be run on chroot mount/boot.
# Sources /root/.chd-init/noble_final.conf if present to pick up config.
CONF="/root/.chd-init/noble_final.conf"
[ -f "$CONF" ] && . "$CONF"

log() { printf "%s\n" "[chroot-start-sshd] $*"; }

log "Ensuring /var/run/sshd exists"
mkdir -p /var/run/sshd

if [ -x /usr/sbin/sshd ]; then
  log "Starting sshd"
  /usr/sbin/sshd || log "sshd exit code $?"
else
  log "sshd not found; install openssh-server in init script"
  exit 1
fi
