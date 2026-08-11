MODID=chroot-distro
AUTOMOUNT=true
PROPFILE=false
POSTFSDATA=false
LATESTARTSERVICE=false

print_modname() { ui_print "chd (reborn)"; }
REPLACE=""

# Fallback perm hook (customize.sh is primary). Re-mark every system/bin binary 0755.
set_permissions() {
    set_perm_recursive "$MODPATH" 0 0 0755 0644
    for bin_path in "$MODPATH/system/bin"/*; do
        [ -f "$bin_path" ] || continue
        set_perm "$bin_path" 0 0 0755
    done
}
