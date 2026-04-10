#!/bin/sh
set -eu

# Termux helper to start a GPU passthrough / virgl/zink server from Termux
# Usage: start_hw_termux.sh [zink|virgl|turnip]
# - zink: starts virgl_test_server with ZINK settings
# - virgl: starts virgl_test_server_android (if available)
# - turnip: prints instructions (no server start)

MODE="${1:-zink}"

log() { printf "%s\n" "[termux-hw] $*"; }

case "$MODE" in
  zink)
    log "starting ZINK-compatible virgl server"
    if command -v virgl_test_server >/dev/null 2>&1; then
      log "using virgl_test_server"
      MESA_NO_ERROR=1 MESA_GL_VERSION_OVERRIDE=4.3COMPAT MESA_GLES_VERSION_OVERRIDE=3.2 \
        GALLIUM_DRIVER=zink ZINK_DESCRIPTORS=lazy virgl_test_server --use-egl-surfaceless --use-gles &
      log "virgl_test_server started (ZINK)"
    elif command -v virgl_test_server_android >/dev/null 2>&1; then
      log "using virgl_test_server_android"
      MESA_NO_ERROR=1 MESA_GL_VERSION_OVERRIDE=4.3COMPAT MESA_GLES_VERSION_OVERRIDE=3.2 \
        GALLIUM_DRIVER=zink ZINK_DESCRIPTORS=lazy virgl_test_server_android &
      log "virgl_test_server_android started (ZINK)"
    else
      log "ERROR: virgl/zink test server not found. Install mesa-zink/virglrenderer packages in Termux."
      exit 1
    fi
    ;;
  virgl)
    log "starting VIRGL server"
    if command -v virgl_test_server_android >/dev/null 2>&1; then
      virgl_test_server_android &
      log "virgl_test_server_android started"
    elif command -v virgl_test_server >/dev/null 2>&1; then
      virgl_test_server &
      log "virgl_test_server started"
    else
      log "ERROR: virgl test server not found. Install virglrenderer packages in Termux."
      exit 1
    fi
    ;;
  turnip)
    log "TURNIP uses kernel driver (Adreno). No server to start from Termux."
    log "Install the Turnip driver as documented and run programs with MESA_LOADER_DRIVER_OVERRIDE=zink"
    ;;
  *)
    log "Unknown mode: $MODE (use zink|virgl|turnip)"
    exit 1
    ;;
esac

log "Ensure /tmp is shared with the chroot/proot (bind mount or share)."
log "Done."
