# lib/mount.sh - mount/unmount system points into an instance. Idempotent. OSMD.
# FIXED policy (final decision - no wizard questions, no conf keys):
#   ram-mount     y : tmpfs on /tmp(1777) /run /var/tmp /dev/shm
#                     (normal Linux boot behavior; /dev/shm is REQUIRED because the
#                      bound Android /dev has no shm -> browsers/desktop apps break)
#   storage-mount y : bind /sdcard + /storage/*  (file exchange)
#   android-mount n : other Android top-level dirs (/data /system /vendor /apex ...)
#                     NOT mounted - keeps chroot-accident blast radius inside the
#                     chroot, avoids delete/backup hazards + SELinux label poisoning.
# Hidden debug overrides (not user-facing): CHD_RAM_MOUNT=0, CHD_STORAGE_MOUNT=0,
# CHD_ANDROID_MOUNT=1.
# Core (always): bind /dev /sys /proc, fresh devpts on /dev/pts (bind fallback).

_chd_bind() {
    _src="$1"; _dst="$2"
    [ -e "$_src" ] || return 0
    if [ -d "$_src" ]; then mkdir -p "$_dst"
    else mkdir -p "$(dirname "$_dst")"; [ -e "$_dst" ] || touch "$_dst" 2>/dev/null; fi
    chd_is_mounted "$_dst" && return 0
    mount --bind "$_src" "$_dst" 2>/dev/null
}

_chd_tmpfs() {
    _dst="$1"; _mode="$2"; mkdir -p "$_dst"
    chd_is_mounted "$_dst" && return 0
    mount -t tmpfs tmpfs "$_dst" 2>/dev/null || return 1
    [ -n "$_mode" ] && chmod "$_mode" "$_dst" 2>/dev/null
    return 0
}

# fresh devpts so the chroot allocates its own ptys (sshd/screen need this);
# falls back to binding the host pts.
_chd_devpts() {
    _dst="$1"; mkdir -p "$_dst"
    chd_is_mounted "$_dst" && return 0
    mount -t devpts devpts "$_dst" 2>/dev/null && return 0
    _chd_bind /dev/pts "$_dst"
}

# android-mount (default OFF): remaining Android top-level dirs. Skip-list mirrors
# the original: never shadow the distro's own fs dirs, never expose FBE key dirs,
# storage handled separately by storage-mount.
_chd_bind_android() {
    _p="$1"
    for _d in /*; do
        [ -d "$_d" ] || continue
        case "$_d" in
            /storage|/sdcard) continue ;;  # storage-mount's job
            /bin|/boot|/etc|/home|/lib|/media|/opt|/root|/run|/sbin|/srv|/usr|/var|/linkerconfig|/tmp) continue ;;
            /keydata|/keyrefuge|/spu|/efs) continue ;;
            /dev|/sys|/proc) continue ;;   # core mounts
        esac
        _chd_bind "$_d" "$_p$_d"
    done
}

# chd_mount <instance_path>
chd_mount() {
    _p="$1"; chd_require_root
    [ -d "$_p" ] || { print_message error "instance path not found: $_p"; return 1; }
    # core
    _chd_bind   /dev  "$_p/dev"
    _chd_bind   /sys  "$_p/sys"
    _chd_bind   /proc "$_p/proc"
    _chd_devpts       "$_p/dev/pts"
    # ram-mount (fixed y)
    if [ "${CHD_RAM_MOUNT:-1}" != "0" ]; then
        _chd_tmpfs "$_p/tmp"     1777
        _chd_tmpfs "$_p/run"     ""
        _chd_tmpfs "$_p/var/tmp" 1777
        _chd_tmpfs "$_p/dev/shm" 1777
    fi
    # storage-mount (fixed y)
    if [ "${CHD_STORAGE_MOUNT:-1}" != "0" ]; then
        _chd_bind /sdcard "$_p/sdcard"
        for _s in /storage/*; do
            [ -e "$_s" ] || continue
            _chd_bind "$_s" "$_p$_s"
        done
    fi
    # android-mount (fixed n; env override only)
    if [ "${CHD_ANDROID_MOUNT:-0}" = "1" ]; then
        _chd_bind_android "$_p"
    fi
    # GPU nodes come with the /dev bind; loosen perms for the chroot user.
    [ -d "$_p/dev/dri" ] && chmod 666 "$_p"/dev/dri/* 2>/dev/null || true
    return 0
}

# List EVERY mount at or under a path, deepest-first.
_chd_mounts_under() {
    _mup="${1%/}"
    awk -v p="$_mup" '
        { mp=$2 }
        mp==p || index(mp, p "/")==1 { print length(mp) "\t" mp }
    ' /proc/mounts 2>/dev/null | sort -rn | cut -f2-
}

# chd_unmount <instance_path> - unmount everything under the instance, deepest
# first, lazy fallback; detach the backing loop device (file-mode). Returns 0
# ONLY if nothing remains mounted (callers rely on this before rm -rf: a live
# bind would make rm recurse into the real filesystem).
chd_unmount() {
    _p="$1"; chd_require_root
    _mounts=$(_chd_mounts_under "$_p")
    if [ -n "$_mounts" ]; then
        printf '%s\n' "$_mounts" | while IFS= read -r m; do
            [ -n "$m" ] || continue
            umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null
        done
    fi
    if command -v chd_image_detach >/dev/null 2>&1 && [ "${TARGET_TYPE:-file}" = "file" ] && [ -n "${TARGET_PATH:-}" ]; then
        chd_image_detach "$TARGET_PATH"
    fi
    [ -z "$(_chd_mounts_under "$_p")" ]
}
