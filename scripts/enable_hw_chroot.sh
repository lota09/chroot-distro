#!/bin/sh
set -eu

# chroot helper to run programs (or a desktop) with appropriate env for hardware
# Usage: enable_hw_chroot.sh [zink|virgl|turnip] -- <command...>
# If no command provided after --, it prints recommended env and exits.

MODE="${1:-zink}"
shift || true

log() { printf "%s\n" "[chroot-hw] $*"; }

case "$MODE" in
  zink)
    export GALLIUM_DRIVER=zink
    export ZINK_DESCRIPTORS=lazy
    export MESA_GL_VERSION_OVERRIDE=4.0
    log "Configured ZINK environment (GALLIUM_DRIVER=zink)"
    ;;
  virgl)
    export GALLIUM_DRIVER=virpipe
    export MESA_GL_VERSION_OVERRIDE=4.0
    log "Configured VIRGL environment (GALLIUM_DRIVER=virpipe)"
    ;;
  turnip)
    export MESA_LOADER_DRIVER_OVERRIDE=zink
    export TU_DEBUG=noconform
    log "Configured TURNIP environment (MESA_LOADER_DRIVER_OVERRIDE=zink)"
    ;;
  *)
    log "Unknown mode: $MODE (use zink|virgl|turnip)"
    exit 1
    ;;
esac

# If caller provided a command (after --), exec it with the env set.
if [ "$#" -gt 0 ]; then
  log "Executing: $*"
  exec "$@"
else
  cat <<EOF
[chroot-hw] Environment configured for mode: $MODE
Examples:
  enable_hw_chroot.sh $MODE -- glxgears
  enable_hw_chroot.sh $MODE -- dbus-launch --exit-with-session startxfce4

Make sure Termux side started the matching server (Termux-Desktops/scripts/start_hw_termux.sh).
Also ensure /tmp (and any required sockets) are shared between Termux and chroot.
EOF
fi
