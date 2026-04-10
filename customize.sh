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

# Ensure the main binary has correct permissions
if [ -f "$MODPATH/system/bin/chroot-distro" ]; then
    chmod 755 "$MODPATH/system/bin/chroot-distro"
fi

# Set default Magisk permissions for the rest of the module
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/system/bin/chroot-distro" 0 0 0755

# Phase 3: Hot-Mount (Non-reboot support)
if [ "$BOOTMODE" = "true" ]; then
    ui_print "- Activating binaries without reboot (Hot-Mount)..."
    for bin_path in "$MODPATH/system/bin"/*; do
        [ -f "$bin_path" ] || continue
        bin=$(basename "$bin_path")
        
        # Ensure Unix line endings for binary scripts
        sed -i 's/\r$//' "$bin_path"
        chmod 755 "$bin_path"
        
        # Apply hot-mount
        umount "/system/bin/$bin" >/dev/null 2>&1
        [ -f "/system/bin/$bin" ] || touch "/system/bin/$bin"
        mount -o bind "$bin_path" "/system/bin/$bin"
    done
    ui_print "  [Success] Tools are now active. No reboot required!"
fi

ui_print "*******************************"
ui_print "   Module Ready for Action!    "
ui_print "*******************************"
