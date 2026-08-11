#!/sbin/sh
# Magisk install customization for chd (reborn).
# Deploys the runtime tree to a Termux-readable working dir, fixes perms/line
# endings, and does a best-effort honest hot-mount.

ui_print "*******************************"
ui_print "     chd (rb2) install     "
ui_print "*******************************"

CHD_ROOT="/data/local/chroot-distro"

# 1) Deploy lib/ + scripts/ to the working dir.
#    Why not run them straight from $MODPATH (/data/adb/modules/...)?
#    /data/adb is root-only (0700); the host scripts run as the Termux app UID
#    via su, which cannot read there. $CHD_ROOT is reachable, so we mirror there.
ui_print "- Deploying runtime tree to $CHD_ROOT ..."
mkdir -p "$CHD_ROOT"
for d in lib scripts docs; do
    if [ -d "$MODPATH/$d" ]; then
        rm -rf "$CHD_ROOT/$d"
        cp -af "$MODPATH/$d" "$CHD_ROOT/"
    fi
done
# Normalise line endings + exec bits on lib/ + scripts/ (docs are plain text).
find "$CHD_ROOT/lib" "$CHD_ROOT/scripts" -type f 2>/dev/null | while read -r f; do
    sed -i 's/\r$//' "$f"
    chmod 0755 "$f"
done
ui_print "  [OK] lib/ + scripts/ + docs/ deployed"

# 2) Permissions: default recursive, then re-mark EVERY binary in system/bin as
#    executable (set_perm_recursive makes files 0644; loop, don't hardcode names).
ui_print "- Finalizing permissions..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
if [ -d "$MODPATH/system/bin" ]; then
    for bin_path in "$MODPATH/system/bin"/*; do
        [ -f "$bin_path" ] || continue
        sed -i 's/\r$//' "$bin_path"
        set_perm "$bin_path" 0 0 0755
    done
fi

# 3) Hot-mount (best-effort, honest). On many devices /system/bin is read-only in
#    the installer context, so this fails and a reboot (magic-mount) is required.
if [ "$BOOTMODE" = "true" ]; then
    ui_print "- Hot-mount (best-effort)..."
    _failed=0
    for bin_path in "$MODPATH/system/bin"/*; do
        [ -f "$bin_path" ] || continue
        bin=$(basename "$bin_path")
        umount "/system/bin/$bin" >/dev/null 2>&1
        if [ -f "/system/bin/$bin" ] || touch "/system/bin/$bin" 2>/dev/null; then
            if mount -o bind "$bin_path" "/system/bin/$bin" 2>/dev/null; then
                ui_print "    [OK] $bin"
            else
                ui_print "    [FAIL] $bin (bind mount failed)"; _failed=1
            fi
        else
            ui_print "    [FAIL] $bin (/system/bin read-only)"; _failed=1
        fi
    done
    if [ "$_failed" -eq 0 ]; then
        ui_print "  [Success] bind-mounted in this context (reboot may still be needed for other shells)."
    else
        ui_print "  [WARN] hot-mount incomplete -> REBOOT to activate via magic-mount."
    fi
else
    ui_print "- Non-boot install: REBOOT required to activate."
fi

ui_print "*******************************"
ui_print "   chd ready (reboot if told)  "
ui_print "*******************************"
