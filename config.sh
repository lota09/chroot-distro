MODID=chroot-distro
AUTOMOUNT=true
PROPFILE=false
POSTFSDATA=false
LATESTARTSERVICE=false

print_modname() {
  ui_print "*******************************"
  ui_print "               chroot-distro                "
  ui_print "*******************************"
}
dos2unix /system/bin/chroot-distro
REPLACE=""
set_permissions() {
  set_perm_recursive  $MODPATH  0  0  0755  0644
  # set_perm_recursive above marks every FILE 0644 (non-executable), including
  # everything under system/bin/. Explicitly re-mark each binary there as
  # 0755 -- a previous version of this only did chroot-distro by name, which
  # silently left other tools (e.g. the "chd" wrapper) non-executable after
  # install.
  for bin_path in "$MODPATH/system/bin"/*; do
    [ -f "$bin_path" ] || continue
    set_perm "$bin_path" 0 0 0755
  done
}
