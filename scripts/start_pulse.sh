#!/bin/sh
set -eu

# Start PulseAudio client or system instance in chroot if applicable.
# This script prefers running pulse per-user if available.
CONF="/root/.chd-init/noble_final.conf"
[ -f "$CONF" ] && . "$CONF"

log() { printf "%s\n" "[chroot-start-pulse] $*"; }

if [ "${CHROOT_PULSE:-false}" != "true" ]; then
  log "PulseAudio not enabled in config; exiting"
  exit 0
fi

if command -v pulseaudio >/dev/null 2>&1; then
  log "Starting PulseAudio (per-user)"
  # run as CHROOT_USER if available
  : ${CHROOT_USER:=root}
  su - "${CHROOT_USER}" -c 'pulseaudio --start || pulseaudio --check || true'
else
  log "pulseaudio binary not found; install libasound2-plugins or pulseaudio in init script"
  exit 1
fi
