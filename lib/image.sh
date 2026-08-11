# lib/image.sh - rootfs disk image (.img) support. Ported from the original
# chroot_distro_mount_rootfs_image. REQUIRED on Samsung/FDE devices: /data is
# FBE/FDE-locked for exec, so the rootfs must live inside a loop-mounted ext4
# image instead of a plain directory.
#
#   chd_image_mount  <img> <sizeMB> <fstype> <mount_point>  create-if-missing + mount
#   chd_image_detach <img>                                   detach loop devices backing img

# chd_image_mount: mount (creating + formatting if needed) an image on a dir.
chd_image_mount() {
    _img="$1"; _sz="$2"; _fs="${3:-ext4}"; _mp="$4"
    [ -n "$_img" ] || { print_message error "image path empty"; return 1; }
    [ -n "$_mp" ]  || { print_message error "image mount point empty"; return 1; }

    # Idempotent: already mounted?
    if chd_is_mounted "$_mp"; then
        return 0
    fi

    if [ ! -f "$_img" ]; then
        if [ -z "$_sz" ]; then
            print_message error "Rootfs image not found: $_img (and no DISK_SIZE to create it)"
            return 1
        fi
        print_message info "Creating rootfs image: $_img (${_sz}M, sparse)"
        mkdir -p "$(dirname "$_img")" 2>/dev/null
        _sza="$_sz"
        case "$_sz" in
            *[KkMmGgTtPpEe]) _sza="$_sz" ;;
            *[0-9])          _sza="${_sz}M" ;;
        esac
        if ! truncate -s "$_sza" "$_img"; then
            print_message error "Failed to allocate image with truncate ($_sza)."
            return 1
        fi
        print_message info "Image allocated ($_sza). Formatting ($_fs)..."
        case "$_fs" in
            ext4)
                if ! mke2fs -t ext4 "$_img"; then
                    print_message error "mke2fs ext4 failed."; rm -f "$_img"; return 1
                fi ;;
            *)
                if command -v "mkfs.$_fs" >/dev/null 2>&1; then
                    if ! "mkfs.$_fs" "$_img"; then
                        print_message error "mkfs.$_fs failed."; rm -f "$_img"; return 1
                    fi
                else
                    print_message error "mkfs.$_fs not available; use ext4."; rm -f "$_img"; return 1
                fi ;;
        esac
        print_message info "Image formatted ($_fs)."
    fi

    mkdir -p "$_mp"
    # Original mount strategy: plain mount first, then explicit -t <fs> -o loop.
    if ! mount -o rw,relatime "$_img" "$_mp" 2>/dev/null; then
        if ! mount -t "$_fs" -o loop,rw,relatime "$_img" "$_mp" 2>/dev/null; then
            print_message error "Failed to loop-mount image on $_mp"
            print_message note "If this is a new image, format it: mke2fs -t ext4 $_img"
            return 1
        fi
    fi
    # FDE/noexec workaround (original): ensure exec/suid/dev on the mount.
    mount -o remount,exec,suid,dev "$_mp" >/dev/null 2>&1 || true
    print_message info "Rootfs image mounted on $_mp"
    return 0
}

# chd_image_detach: detach any loop device whose backing file is this image.
chd_image_detach() {
    _img="$1"
    [ -n "$_img" ] || return 0
    command -v losetup >/dev/null 2>&1 || return 0
    losetup -a 2>/dev/null | grep -F "$_img" | cut -d: -f1 | while IFS= read -r _ld; do
        [ -n "$_ld" ] || continue
        losetup -d "$_ld" 2>/dev/null || true
    done
    return 0
}

# For a loaded instance conf: mount the image on the instance dir if file-mode.
# Usage: chd_image_ensure <instance_dir>   (reads TARGET_TYPE/TARGET_PATH/DISK_SIZE/FS_TYPE)
# chd_image_ensure <instance_dir> [create]
#   create=create (default, install path): make+format the image if missing.
#   create=nocreate (login/mount path): only mount an existing image; if the .img
#     is gone, error instead of silently allocating a fresh 131072MB image.
chd_image_ensure() {
    [ "${TARGET_TYPE:-file}" = "file" ] || return 0
    [ -n "${TARGET_PATH:-}" ] || return 0
    if [ "${2:-create}" = "nocreate" ] && [ ! -f "$TARGET_PATH" ]; then
        print_message error "image missing: $TARGET_PATH (reinstall with 'chd install')."
        return 1
    fi
    _isz="${DISK_SIZE:-}"
    [ "${2:-create}" = "nocreate" ] && _isz=""   # never create in the login/mount path
    chd_image_mount "$TARGET_PATH" "$_isz" "${FS_TYPE:-ext4}" "$1"
}
