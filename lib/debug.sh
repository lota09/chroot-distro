# lib/debug.sh - `chd debug` (renamed from the original `env`): environment dump
# for diagnosing device issues from a single command's output.
chd_cmd_debug() {
    print_message info "=== chd debug ==="
    echo "version        : chd $CHD_VERSION"
    if [ -f /data/adb/modules/chroot-distro/module.prop ]; then
        sed -n 's/^version=/module version : /p;s/^versionCode=/module vcode   : /p' /data/adb/modules/chroot-distro/module.prop
    else
        echo "module         : NOT under /data/adb/modules (not installed via Magisk?)"
    fi
    echo "script         : $0"
    command -v md5sum >/dev/null 2>&1 && echo "md5            : $(md5sum "$0" 2>/dev/null | cut -d' ' -f1)"
    echo "CHD_ROOT       : $CHD_ROOT"
    echo "arch           : ${CHD_ARCH:-?} (uname: $(uname -m 2>/dev/null))"
    echo "uid            : $(id -u 2>/dev/null) ($(id -un 2>/dev/null))"

    echo "--- toolchain ---"
    command -v toybox >/dev/null 2>&1 && echo "toybox         : $(toybox --version 2>/dev/null | head -1)" || echo "toybox         : not found"
    _bb="$(command -v busybox 2>/dev/null)"
    if [ -z "$_bb" ]; then
        for pp in /data/adb/modules/busybox-ndk/system/*/busybox /data/adb/magisk/busybox /data/adb/ksu/bin/busybox; do
            [ -f "$pp" ] && { _bb="$pp"; break; }
        done
    fi
    if [ -n "$_bb" ]; then echo "busybox        : $_bb ($("$_bb" 2>/dev/null | head -1))"; else echo "busybox        : not found"; fi
    tar --help 2>&1 | grep -q -- '-J' && echo "tar xz         : supported" || echo "tar xz         : NOT supported (busybox too old)"
    command -v losetup >/dev/null 2>&1 && echo "losetup        : $(command -v losetup)" || echo "losetup        : not found"
    command -v mke2fs  >/dev/null 2>&1 && echo "mke2fs         : $(command -v mke2fs)"  || echo "mke2fs         : not found (image mode create will fail)"

    echo "--- host apps ---"
    [ -d /data/data/com.termux ]     && echo "Termux         : installed" || echo "Termux         : NOT installed (virgl/pulse unavailable)"
    [ -d /data/data/com.termux.x11 ] && echo "Termux:X11     : installed" || echo "Termux:X11     : NOT installed (x11 graphics unavailable)"

    echo "--- mount policy (fixed) ---"
    echo "ram-mount      : $([ "${CHD_RAM_MOUNT:-1}" != 0 ] && echo y || echo n) (tmpfs /tmp /run /var/tmp /dev/shm)"
    echo "storage-mount  : $([ "${CHD_STORAGE_MOUNT:-1}" != 0 ] && echo y || echo n) (/sdcard /storage/*)"
    echo "android-mount  : $([ "${CHD_ANDROID_MOUNT:-0}" = 1 ] && echo y || echo n) (/data /system ... ; enable: CHD_ANDROID_MOUNT=1)"

    echo "--- instances ---"
    _n=0
    for d in "$CHD_ROOT"/*/; do
        [ -d "$d" ] || continue
        b=$(basename "$d"); chd_is_reserved "$b" && continue
        [ -d "$d/etc" ] || continue
        _n=$((_n+1))
        _mc=$(_chd_mounts_under "${d%/}" | grep -c . 2>/dev/null)
        echo "  $b  (mounts under it: ${_mc:-0})"
    done
    [ "$_n" = 0 ] && echo "  (none)"
    echo "--- profiles ---"
    ls "$CHD_ROOT"/.profile/*.conf 2>/dev/null | sed 's/.*\//  /;s/\.conf$//' || echo "  (none)"
    echo "--- rootfs archives ---"
    ls -sh "$CHD_ROOT"/.rootfs/ 2>/dev/null | sed 's/^/  /' | head -10
    echo "--- install logs (newest first) ---"
    ls -1t "$CHD_ROOT"/log/install-*.log 2>/dev/null | head -5 | sed 's/^/  /' || echo "  (none)"
    echo "--- backups ---"
    ls -sh "$CHD_ROOT"/.backup/ 2>/dev/null | sed 's/^/  /' | head -10
    echo "--- loop devices ---"
    losetup -a 2>/dev/null | sed 's/^/  /' | head -10 || echo "  (none)"
    echo "--- mounts under CHD_ROOT ---"
    _chd_mounts_under "$CHD_ROOT" | sed 's/^/  /' | head -30
    print_message info "=== end debug ==="
}
