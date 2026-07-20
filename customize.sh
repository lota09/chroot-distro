#!/sbin/sh

# Magisk module customization script
# This script is the single authority for tool synchronization and deployment.

ui_print "*******************************"
ui_print "       chroot-distro Sync      "
ui_print "*******************************"

# Define important paths
EXTERNAL_ZIP="/sdcard/Documents/chroot-distro.zip"
HOST_ROOT="/data/local/chroot-distro"
HOST_SCRIPTS="$HOST_ROOT/scripts"

# Ensure the host directory exists
mkdir -p "$HOST_ROOT"

# Phase 1: Synchronization
if [ -f "$EXTERNAL_ZIP" ]; then
    ui_print "- External zip found in /sdcard/Documents/"
    ui_print "- Synchronizing everything from external zip..."

    # 1. Sync scripts and assets to the correct host root
    unzip -qo "$EXTERNAL_ZIP" -d "$HOST_ROOT"

    # 2. Sync all tool binaries to Magisk module path
    if [ -d "$HOST_ROOT/system/bin" ]; then
        mkdir -p "$MODPATH/system/bin"
        cp -af "$HOST_ROOT/system/bin"/. "$MODPATH/system/bin/"
        ui_print "  [Success] Binaries synced to module path"
    fi
else
    ui_print "- No external zip found. Deploying from flashed package..."

    # Fallback: Copy scripts from the currently flashed module to the host path
    if [ -d "$MODPATH/scripts" ]; then
        mkdir -p "$HOST_SCRIPTS"
        cp -af "$MODPATH/scripts"/* "$HOST_SCRIPTS/"
        ui_print "  [Success] Host scripts deployed from flashed zip"
    fi
fi

# Phase 2: Sanitization and Permissions
ui_print "- Finalizing permissions and line endings..."

if [ -d "$HOST_SCRIPTS" ]; then
    # Force Unix line endings (LF) on all host scripts
    find "$HOST_SCRIPTS" -type f -exec sed -i 's/\r$//' {} +
    # Ensure execution permissions
    chmod -R 755 "$HOST_SCRIPTS"
fi

# Set default Magisk permissions for the whole module...
set_perm_recursive "$MODPATH" 0 0 0755 0644

# ...then explicitly re-mark EVERY file under system/bin/ as executable (0755).
# set_perm_recursive above sets ALL files to 0644 (non-executable) including
# these; a previous version of this script only re-fixed chroot-distro
# specifically, silently leaving every OTHER tool in system/bin/ (e.g. the
# "chd" wrapper) non-executable after a normal reboot-based magic-mount.
# Looping here instead of hardcoding one filename means any binary added to
# system/bin/ in the future is covered automatically.
if [ -d "$MODPATH/system/bin" ]; then
    for bin_path in "$MODPATH/system/bin"/*; do
        [ -f "$bin_path" ] || continue
        set_perm "$bin_path" 0 0 0755
    done
fi

# Phase 3: Hot-Mount (best-effort, non-reboot activation)
#
# IMPORTANT: this is best-effort, not guaranteed. Bind mounts performed here
# run inside whatever mount namespace the Magisk app's installer process is
# using. Depending on the device/Magisk version, that namespace is not
# always the same one a freshly opened `adb shell` (or a new terminal
# session) ends up in — in which case the tools are mounted successfully
# from this script's point of view, but still invisible ("not found") from
# a brand new shell. If that happens, a reboot forces Magisk's normal
# post-fs-data magic-mount, which DOES run in the global/init mount
# namespace and is visible everywhere. So: try a hot-mounted shell first,
# but don't be surprised if a reboot is still required — that isn't a sign
# something is broken, just a limitation of hot-mount itself.
if [ "$BOOTMODE" = "true" ]; then
    ui_print "- Activating binaries without reboot (Hot-Mount, best-effort)..."
    _hotmount_failed=0
    for bin_path in "$MODPATH/system/bin"/*; do
        [ -f "$bin_path" ] || continue
        bin=$(basename "$bin_path")

        # Ensure Unix line endings for binary scripts
        sed -i 's/\r$//' "$bin_path"
        chmod 755 "$bin_path"

        # Apply hot-mount — and actually check whether it worked, instead of
        # unconditionally printing success regardless of the mount result.
        umount "/system/bin/$bin" >/dev/null 2>&1
        [ -f "/system/bin/$bin" ] || touch "/system/bin/$bin"
        if mount -o bind "$bin_path" "/system/bin/$bin" 2>/dev/null; then
            ui_print "    [OK] $bin"
        else
            ui_print "    [FAIL] $bin (bind mount failed — see below)"
            _hotmount_failed=1
        fi
    done
    if [ "$_hotmount_failed" -eq 0 ]; then
        ui_print "  [Success] Tools bind-mounted in this install context."
        ui_print "  If a NEW shell (e.g. adb shell) still can't find them, reboot once —"
        ui_print "  hot-mount doesn't always propagate to other mount namespaces."
    else
        ui_print "  [WARN] One or more binaries failed to hot-mount."
        ui_print "  Reboot to activate them via Magisk's normal magic-mount instead."
    fi
else
    ui_print "- BOOTMODE is not 'true' (recovery/non-app install) — hot-mount skipped."
    ui_print "  Reboot is required to activate the tools."
fi

ui_print "*******************************"
ui_print "   Module Ready for Action!    "
ui_print "*******************************"
