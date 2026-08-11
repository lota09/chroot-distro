# lib/profile.sh - profile TEMPLATES (.profile/<name>.conf) + instance conf load.
# Two-layer structure (original):
#   chd profile <name>  -> wizard -> TEMPLATE  $CHD_ROOT/.profile/<name>.conf
#   chd install <name>  -> reads template -> instance + $CHD_ROOT/.config/<name>.conf
# Wizard (original flow, numbered menus): distro -> suite -> user -> graphics ->
# desktop -> ssh -> pulse -> advanced(virgl, target file/dir, img path/size/fs, arch).
# Mount policy is FIXED (ram y / storage y / android n) - no questions, no keys.

chd_profile_default_suite() {
    case "$1" in
        ubuntu)  echo "noble" ;;
        debian)  echo "debian_bookworm" ;;
        kali)    echo "minimal" ;;
        fedora)  echo "v4.24.0" ;;
        chimera) echo "bootstrap" ;;
        adelie)  echo "mini" ;;
        *)       echo "" ;;
    esac
}

_chd_suite_options() {
    case "$1" in
        ubuntu)  echo "noble jammy focal bionic plucky oracular xenial trusty" ;;
        debian)  echo "debian_bookworm debian_trixie debian_bullseye debian" ;;
        kali)    echo "minimal full nano" ;;
        fedora)  echo "v4.24.0 v4.23.0 v4.17.3 v4.15.0" ;;
        chimera) echo "bootstrap full" ;;
        adelie)  echo "mini full" ;;
        *)       echo "" ;;
    esac
}

# Numbered menu -> stdout item. Menu text on stderr. 'q' cancels (rc 1).
_chd_menu() {
    _mt="$1"; _mdef="$2"; shift 2
    _mn=$#
    printf '\n%s\n' "$_mt" >&2
    _k=1
    for _it in "$@"; do printf '  [%d] %s\n' "$_k" "$_it" >&2; _k=$((_k+1)); done
    while true; do
        printf 'Select (1-%d) [%s]: ' "$_mn" "$_mdef" >&2
        read -r _ma
        [ -z "$_ma" ] && _ma="$_mdef"
        case "$_ma" in
            q|Q) return 1 ;;
            *[!0-9]*|'') printf 'Please enter a number (or q to cancel).\n' >&2; continue ;;
        esac
        if [ "$_ma" -ge 1 ] && [ "$_ma" -le "$_mn" ]; then
            _k=1
            for _it in "$@"; do
                [ "$_k" = "$_ma" ] && { printf '%s' "$_it"; return 0; }
                _k=$((_k+1))
            done
        fi
        printf 'Out of range (1-%d).\n' "$_mn" >&2
    done
}

_chd_prompt() {
    printf '%s [%s]: ' "$1" "$2" >&2
    read -r _pa
    printf '%s' "${_pa:-$2}"
}

_chd_yesno() {
    _yd="y"; [ "$2" = "false" ] && _yd="n"
    while true; do
        printf '%s (y/n) [%s]: ' "$1" "$_yd" >&2
        read -r _ya
        _ya="${_ya:-$_yd}"
        case "$_ya" in
            y|Y|yes) echo "true"; return 0 ;;
            n|N|no)  echo "false"; return 0 ;;
            *) printf 'Please enter y or n.\n' >&2 ;;
        esac
    done
}

# Index (1-based) of a value in an item list; empty if absent. Used to make the
# wizard's numbered menus default to the values loaded from an existing template.
_chd_index_of() {
    _io_v="$1"; shift
    _io_i=1
    for _io_x in "$@"; do
        [ "$_io_x" = "$_io_v" ] && { printf '%s' "$_io_i"; return 0; }
        _io_i=$((_io_i+1))
    done
    printf ''
    return 1
}

# Wizard display order: lead with the distros that have an init backend so the
# default (index 1) is debian, not alpine (which would produce a bare rootfs).
CHD_DISTRO_MENU="debian ubuntu kali alpine arch artix deepin fedora manjaro openkylin opensuse pardus void parrot backbox centos_stream rocky adelie chimera gentoo"

chd_profile_sanitize_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'; }

# Resolve a TEMPLATE conf: explicit path, or .profile/<name>.conf.
chd_profile_resolve_conf() {
    [ -n "$1" ] || return 1
    if [ -f "$1" ]; then printf '%s' "$1"; return 0; fi
    if [ -f "$CHD_ROOT/.profile/$1.conf" ]; then
        printf '%s' "$CHD_ROOT/.profile/$1.conf"; return 0
    fi
    return 1
}

# Load an INSTANCE conf (.config/<name>.conf).
chd_profile_load() {
    # Reset every instance-specific var FIRST so a failed load (or a conf missing
    # some keys) never leaks the previous instance's values (e.g. TARGET_PATH,
    # which would make unmount detach the wrong loop device or skip .img deletion).
    DISTRIB=""; SUITE=""; USER_NAME=""; USER_PASSWORD=""; GRAPHICS=""; DESKTOP=""
    VIRGL_ENABLE=""; DESKTOP_BACKEND=""; SSH_ENABLE=""; PULSE_ENABLE=""; INCLUDE=""; ARCH=""
    TARGET_TYPE=""; TARGET_PATH=""; DISK_SIZE=""; FS_TYPE=""
    VNC_DISPLAY=""; VNC_WIDTH=""; VNC_HEIGHT=""; VNC_PASSWORD=""
    _conf="$(chd_instance_conf "$1")"
    [ -f "$_conf" ] || return 1
    # shellcheck disable=SC1090
    . "$_conf"
    : "${DISTRIB:=$1}"
    : "${SUITE:=}"
    : "${TARGET_TYPE:=file}"
    return 0
}

_chd_profile_write() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<CONF
ARCH="$ARCH"
DESKTOP="$DESKTOP"
DESKTOP_BACKEND="$DESKTOP_BACKEND"
DISK_SIZE="$DISK_SIZE"
DISTRIB="$DISTRIB"
FS_TYPE="$FS_TYPE"
GRAPHICS="$GRAPHICS"
INCLUDE="$INCLUDE"
PULSE_ENABLE="$PULSE_ENABLE"
SSH_ENABLE="$SSH_ENABLE"
SUITE="$SUITE"
TARGET_PATH="$TARGET_PATH"
TARGET_TYPE="$TARGET_TYPE"
USER_NAME="$USER_NAME"
USER_PASSWORD="$USER_PASSWORD"
VIRGL_ENABLE="$VIRGL_ENABLE"
VNC_DISPLAY="${VNC_DISPLAY:-1}"
VNC_HEIGHT="${VNC_HEIGHT:-720}"
VNC_PASSWORD="${VNC_PASSWORD:-${USER_PASSWORD:-changeme}}"
VNC_WIDTH="${VNC_WIDTH:-1280}"
CONF
}

_chd_profile_include() {
    INCLUDE="bootstrap desktop graphics"
    [ "$SSH_ENABLE" = "true" ] && INCLUDE="$INCLUDE extra/ssh"
    [ "$PULSE_ENABLE" = "true" ] && INCLUDE="$INCLUDE extra/pulse"
    case "$GRAPHICS" in *x11*) INCLUDE="$INCLUDE graphics/x11" ;; esac
    case "$GRAPHICS" in *vnc*) INCLUDE="$INCLUDE graphics/vnc" ;; esac
    [ "$VIRGL_ENABLE" = "true" ] && INCLUDE="$INCLUDE hardware/virgl"
}

# Wizard.
#   chd profile <name>                                       interactive
#   chd profile <name> <distro> [suite] [graphics] [desktop] quick (scripting)
chd_cmd_profile() {
    _pname="$1"; { [ "$#" -gt 0 ] && shift; } || true
    if [ -z "$_pname" ]; then
        # No name given: profile management (original UX). List existing profiles;
        # offer create-new or edit-existing. Editing loads the template as defaults.
        _plist=""
        for _pf in "$CHD_ROOT"/.profile/*.conf; do
            [ -f "$_pf" ] && _plist="$_plist $(basename "$_pf" .conf)"
        done
        if [ -n "$_plist" ]; then
            _pa="$(_chd_menu 'Profile management:' 1 'Create a new profile' 'Edit an existing profile')" \
                || { print_message note "cancelled."; return 0; }
            case "$_pa" in
                Edit*) _pname="$(_chd_menu 'Edit which profile?' 1 $_plist)" \
                           || { print_message note "cancelled."; return 0; } ;;
                *)     _pname="$(_chd_prompt 'New profile name' 'my_profile')" ;;
            esac
        else
            _pname="$(_chd_prompt 'New profile name' 'my_profile')"
        fi
    fi
    _pname="$(chd_profile_sanitize_name "$_pname")"
    _ppath="$CHD_ROOT/.profile/$_pname.conf"

    if [ $# -ge 1 ]; then
        DISTRIB="$1"; SUITE="${2:-$(chd_profile_default_suite "$1")}"
        GRAPHICS="${3:-none}"; DESKTOP="${4:-none}"
        [ "$GRAPHICS" = "none" ] && DESKTOP="none"
        [ "$GRAPHICS" != "none" ] && [ "$DESKTOP" = "none" ] && DESKTOP="lxde"
        USER_NAME="${USER_NAME:-user}"; USER_PASSWORD="changeme"
        VIRGL_ENABLE="false"; [ "$GRAPHICS" != "none" ] && VIRGL_ENABLE="true"
        DESKTOP_BACKEND=""; [ "$GRAPHICS" != "none" ] && DESKTOP_BACKEND="softpipe"
        SSH_ENABLE="true"; PULSE_ENABLE="true"
        TARGET_TYPE="file"; TARGET_PATH="/sdcard/$_pname.img"
        DISK_SIZE="131072"; FS_TYPE="ext4"; ARCH="$CHD_ARCH"
        _chd_profile_include
        _chd_profile_write "$_ppath"
        print_message info "Profile template written: $_ppath"
        return 0
    fi

    if [ -f "$_ppath" ]; then
        # shellcheck disable=SC1090
        . "$_ppath"
        print_message info "Loaded existing profile as defaults: $_ppath"
    else
        # New profile: clear inherited state so menu defaults are canonical
        # (index 1 = debian), not whatever leaked from a prior operation.
        DISTRIB=""; SUITE=""; GRAPHICS=""; DESKTOP=""; USER_NAME=""
        TARGET_TYPE=""; TARGET_PATH=""; DISK_SIZE=""; FS_TYPE=""; ARCH=""
        SSH_ENABLE=""; PULSE_ENABLE=""; VIRGL_ENABLE=""; DESKTOP_BACKEND=""
    fi

    _ddef="$(_chd_index_of "${DISTRIB:-}" $CHD_DISTRO_MENU)"
    DISTRIB="$(_chd_menu 'Distribution:' "${_ddef:-1}" $CHD_DISTRO_MENU)" || { print_message note "cancelled."; return 1; }
    _sopts="$(_chd_suite_options "$DISTRIB")"
    if [ -n "$_sopts" ]; then
        _sdef="$(_chd_index_of "${SUITE:-}" $_sopts)"
        SUITE="$(_chd_menu "Suite / variant for $DISTRIB:" "${_sdef:-1}" $_sopts)" || { print_message note "cancelled."; return 1; }
    else
        SUITE="$(chd_profile_default_suite "$DISTRIB")"
    fi

    USER_NAME="$(_chd_prompt 'User name' "${USER_NAME:-user}")"
    USER_PASSWORD="changeme"

    _gdef=3
    case "${GRAPHICS:-}" in none) _gdef=1 ;; x11) _gdef=2 ;; vnc+x11) _gdef=3 ;; esac
    _g="$(_chd_menu 'Graphics Mode:' "$_gdef" \
        'Headless   (CLI Only / No Graphics)' \
        'Termux-X11 (GPU Accelerated, requires Termux:X11 app)' \
        'X11 + VNC  (Termux:X11 + x11vnc mirror - GPU Accelerated, Recommended)')" \
        || { print_message note "cancelled."; return 1; }
    case "$_g" in
        Headless*)   GRAPHICS="none" ;;
        Termux-X11*) GRAPHICS="x11" ;;
        *)           GRAPHICS="vnc+x11" ;;
    esac

    if [ "$GRAPHICS" != "none" ]; then
        _kdef=1
        case "${DESKTOP:-}" in lxde) _kdef=1 ;; xfce) _kdef=2 ;; lxqt) _kdef=3 ;; mate) _kdef=4 ;; gnome) _kdef=5 ;; kde) _kdef=6 ;; esac
        _d="$(_chd_menu 'Desktop Environment:' "$_kdef" \
            'LXDE         (Recommended for VNC - Lightweight, no compositor)' \
            'XFCE4        (Fast, but compositor may conflict with virgl GPU)' \
            'LXQt         (Ultra Lightweight Qt)' \
            'MATE         (Classic)' \
            'GNOME        (Very heavy - Requires strong GPU/RAM)' \
            'KDE Plasma   (Heavy - Modern UI)')" \
            || { print_message note "cancelled."; return 1; }
        case "$_d" in
            LXDE*)  DESKTOP="lxde" ;;
            XFCE*)  DESKTOP="xfce" ;;
            LXQt*)  DESKTOP="lxqt" ;;
            MATE*)  DESKTOP="mate" ;;
            GNOME*) DESKTOP="gnome" ;;
            KDE*)   DESKTOP="kde" ;;
        esac
        VIRGL_ENABLE="true"
        # Desktop SESSION rendering backend. Separate from VIRGL_ENABLE (which keeps
        # the host GPU stack up so individual apps can use `gpuacc`). Driving a whole
        # desktop through virpipe is faster but can black-screen on some setups, so
        # the choice is explicit and defaults to the stable option.
        _bedef=1; [ "${DESKTOP_BACKEND:-}" = "virpipe" ] && _bedef=2
        _be="$(_chd_menu 'Desktop rendering backend:' "$_bedef" \
            'softpipe (CPU)        - decent performance, stable' \
            'virpipe  (GPU accel.) - better performance, may be unstable (black screen on some desktops)')" \
            || { print_message note "cancelled."; return 1; }
        case "$_be" in softpipe*) DESKTOP_BACKEND="softpipe" ;; *) DESKTOP_BACKEND="virpipe" ;; esac
    else
        DESKTOP="none"
        VIRGL_ENABLE="false"
        DESKTOP_BACKEND=""
    fi

    printf '\n[ SSH Server ]  remote terminal via ssh user@<device-ip>\n' >&2
    SSH_ENABLE="$(_chd_yesno 'Enable SSH' "${SSH_ENABLE:-true}")"
    printf '\n[ PulseAudio ]  route chroot audio to Android\n' >&2
    PULSE_ENABLE="$(_chd_yesno 'Enable PulseAudio' "${PULSE_ENABLE:-true}")"

    _adv="$(_chd_yesno 'Configure Advanced Options?' 'false')"
    if [ "$_adv" = "true" ]; then
        if [ "$GRAPHICS" != "none" ]; then
            VIRGL_ENABLE="$(_chd_yesno 'Enable GPU Acceleration (Turnip/Zink)' "${VIRGL_ENABLE:-true}")"
        fi
        _tdef=1; [ "${TARGET_TYPE:-file}" = "dir" ] && _tdef=2
        TARGET_TYPE="$(_chd_menu 'Target type:' "$_tdef" \
            'file (disk image .img - REQUIRED on Samsung/FDE devices)' \
            'dir  (plain directory - only if /data allows exec)')" \
            || { print_message note "cancelled."; return 1; }
        case "$TARGET_TYPE" in file*) TARGET_TYPE="file" ;; *) TARGET_TYPE="dir" ;; esac
        if [ "$TARGET_TYPE" = "file" ]; then
            TARGET_PATH="$(_chd_prompt 'Image path' "${TARGET_PATH:-/sdcard/$_pname.img}")"
            DISK_SIZE="$(_chd_prompt 'Image size (MB)' "${DISK_SIZE:-131072}")"
            _fdef="$(_chd_index_of "${FS_TYPE:-ext4}" ext4 f2fs xfs)"
            FS_TYPE="$(_chd_menu 'Filesystem:' "${_fdef:-1}" ext4 f2fs xfs)" || FS_TYPE="ext4"
        else
            TARGET_PATH=""; DISK_SIZE=""; FS_TYPE=""
        fi
        ARCH="$(_chd_prompt 'Arch' "${ARCH:-$CHD_ARCH}")"
    else
        TARGET_TYPE="${TARGET_TYPE:-file}"
        if [ "$TARGET_TYPE" = "file" ]; then
            TARGET_PATH="${TARGET_PATH:-/sdcard/$_pname.img}"
            DISK_SIZE="${DISK_SIZE:-131072}"
            FS_TYPE="${FS_TYPE:-ext4}"
        else
            TARGET_PATH=""; DISK_SIZE=""; FS_TYPE=""
        fi
        ARCH="${ARCH:-$CHD_ARCH}"
    fi

    _chd_profile_include
    _chd_profile_write "$_ppath"
    print_message info "Profile saved: $_ppath"
    print_message note "Install it with:  chd install $_pname"
}
