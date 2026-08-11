# lib/util.sh - shared helpers. Sourced by the chd entry. Distro-agnostic (OSMD).

: "${CHD_ROOT:=/data/local/chroot-distro}"
: "${CHD_LIB:=$CHD_ROOT/lib}"
: "${CHD_SCRIPTS:=$CHD_ROOT/scripts}"
CHD_VERSION="4.1.7"

# Reserved top-level names under CHD_ROOT that are NOT instances.
CHD_RESERVED="lib scripts log .config .profile .rootfs .backup .cache _to_delete"


# --- busybox enforcement (ported from the original) -------------------------
# Android's default PATH puts toybox first; toybox tar cannot decompress xz and
# toybox has no wget. The original defined tar/wget/sort wrappers pointing at the
# Magisk busybox; without them, .tar.xz extraction and rootfs downloads fail.
chd_setup_busybox() {
    # chroot wrapper FIRST (independent of busybox): jail runs `PATH= chroot ...`,
    # and with an emptied PATH the shell cannot find the `chroot` command
    # ("chroot: inaccessible or not found"). A function bypasses PATH lookup and
    # calls chroot by absolute path - exactly what the original did.
    _cr="$(command -v chroot 2>/dev/null)"
    [ -z "$_cr" ] && [ -x /system/bin/chroot ] && _cr=/system/bin/chroot
    [ -z "$_cr" ] && [ -x /system/xbin/chroot ] && _cr=/system/xbin/chroot
    if [ -n "$_cr" ]; then
        CHD_CHROOT="$_cr"
        chroot() { "$CHD_CHROOT" "$@"; }
    fi

    CHD_BUSYBOX="$(command -v busybox 2>/dev/null)"
    [ -n "${CHROOT_DISTRO_BUSYBOX:-}" ] && CHD_BUSYBOX="$CHROOT_DISTRO_BUSYBOX"
    if [ -z "$CHD_BUSYBOX" ]; then
        for _bp in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox                    /data/adb/ap/bin/busybox /data/adb/modules/busybox-ndk/system/*/busybox; do
            [ -f "$_bp" ] && { CHD_BUSYBOX="$_bp"; break; }
        done
    fi
    if [ -z "${CHD_CHROOT:-}" ] && [ -n "$CHD_BUSYBOX" ]; then
        CHD_CHROOT="$CHD_BUSYBOX"
        chroot() { "$CHD_BUSYBOX" chroot "$@"; }
    fi
    [ -n "$CHD_BUSYBOX" ] || { CHD_BUSYBOX=""; return 1; }
    # tar: only override if the current tar lacks xz (-J) support.
    if ! tar --help 2>&1 | grep -q -- '-J' 2>/dev/null; then
        tar() { "$CHD_BUSYBOX" tar "$@"; }
    fi
    sort() { "$CHD_BUSYBOX" sort "$@"; }
    # wget: prefer busybox; if its build lacks https, fall back to system wget.
    if "$CHD_BUSYBOX" wget --help 2>&1 | grep -q -- 'https' 2>/dev/null; then
        wget() { "$CHD_BUSYBOX" wget "$@"; }
    fi
    return 0
}

print_message() {
    _lvl="$1"; { [ "$#" -gt 0 ] && shift; } || true
    # Optional per-service tag so concurrently-running bring-ups (pulse/x11/virgl)
    # stay readable when their logs interleave on the console.
    _tag=""
    [ -n "${CHD_SVC_TAG:-}" ] && _tag="[$CHD_SVC_TAG]"
    case "$_lvl" in
        error)        printf '[chroot-distro]%s[ERROR] %s\n' "$_tag" "$*" >&2 ;;
        warning|warn) printf '[chroot-distro]%s[warn] %s\n'  "$_tag" "$*" >&2 ;;
        note)         printf '[chroot-distro]%s[note] %s\n'  "$_tag" "$*" >&2 ;;
        *)            printf '[chroot-distro]%s %s\n'        "$_tag" "$*" >&2 ;;
    esac
}

chd_die()  { print_message error "$*"; exit 1; }
chd_exit() { exit "${1:-0}"; }

chd_require_root() {
    [ "$(id -u 2>/dev/null)" = "0" ] || chd_die "must run as root (use su)."
}

# Dispatch to a command function if the module defining it is loaded.
chd_dispatch() {
    _fn="$1"; { [ "$#" -gt 0 ] && shift; } || true
    if command -v "$_fn" >/dev/null 2>&1; then
        "$_fn" "$@"
    else
        print_message error "'$_fn' is not wired yet (reborn build in progress)."
        exit 2
    fi
}

# Locate the 'su' binary inside a rootfs (used by jail).
chd_find_su() {
    _root="$1"
    for p in /bin/su /usr/bin/su /usr/local/bin/su; do
        if [ -f "$_root$p" ] || [ -L "$_root$p" ]; then echo "$p"; return 0; fi
    done
    echo ""; return 1
}

# Mounted? Parse /proc/mounts (exact mountpoint match) instead of the `mountpoint`
# binary - matches the original's proven approach and removes a busybox-applet
# dependency. Exact column-2 compare avoids the false-positives grep -w can hit.
chd_is_mounted() {
    [ -n "$1" ] || return 1
    awk -v m="$1" '$2==m{f=1} END{exit !f}' /proc/mounts 2>/dev/null
}
chd_instance_dir() { echo "$CHD_ROOT/$1"; }
chd_instance_conf(){ echo "$CHD_ROOT/.config/$1.conf"; }

chd_instance_exists() {
    _d="$CHD_ROOT/$1"
    [ -n "$1" ] && [ -d "$_d/etc" ]
}

chd_is_reserved() {
    for r in $CHD_RESERVED; do [ "$1" = "$r" ] && return 0; done
    return 1
}

# Minimal instance listing (milestone-1; instance.sh may override with more detail).
chd_list_basic() {
    print_message info "Installed instances (under $CHD_ROOT):"
    _found=0
    for d in "$CHD_ROOT"/*/; do
        [ -d "$d" ] || continue
        b=$(basename "$d")
        chd_is_reserved "$b" && continue
        [ -d "$d/etc" ] || continue
        echo "  $b"; _found=1
    done
    [ "$_found" = 0 ] && echo "  (none)"
}
