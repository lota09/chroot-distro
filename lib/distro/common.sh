# lib/distro/common.sh - distro-agnostic INIT framework (OSMD). The only per-distro
# part of the whole system is init; this file dispatches to a family backend and
# provides the shared glue: run a guest init script inside the chroot, register
# supervisord programs (host-side, via supervisor.sh), and write the adaptive env.

# Map a DISTRIB value to an init family.
_chd_family() {
    case "$1" in
        debian|ubuntu|kali|parrot|backbox|deepin|pardus|openkylin) echo "debian" ;;
        *) echo "" ;;
    esac
}

# Home dir of a guest user (parse the guest /etc/passwd; fall back sanely).
_chd_user_home() {
    _uh=$(awk -F: -v u="$2" '$1==u{print $6}' "$1/etc/passwd" 2>/dev/null)
    [ -n "$_uh" ] && { echo "$_uh"; return 0; }
    [ "$2" = "root" ] && echo "/root" || echo "/home/$2"
}

# Desktop launch command for a DE (foreground; supervisord-friendly).
_chd_desktop_cmd() {
    case "$1" in
        lxde)  echo 'exec dbus-launch --exit-with-session startlxde' ;;
        lxqt)  echo 'exec dbus-launch --exit-with-session startlxqt' ;;
        mate)  echo 'exec dbus-launch --exit-with-session mate-session' ;;
        xfce)  echo 'exec dbus-launch --exit-with-session startxfce4' ;;
        gnome) echo 'exec dbus-launch --exit-with-session gnome-session' ;;
        kde)   echo 'exec dbus-launch --exit-with-session startplasma-x11' ;;
        xterm) echo 'exec /usr/bin/xterm' ;;
        *)     echo 'exec dbus-launch --exit-with-session startxfce4' ;;
    esac
}

# Write the instance profile into the guest so the guest init script can read it.
_chd_write_guest_profile() {
    _p="$1"; _name="$2"
    mkdir -p "$_p/root/.chd-init"
    _src="$(chd_instance_conf "$_name")"
    [ -f "$_src" ] && cp "$_src" "$_p/root/.chd-init/profile.conf"
}

# Copy a guest init script in and run it inside the chroot (with the Android
# timezone passed through). <path> <script-basename>. Returns the script's rc.
_chd_run_guest_init() {
    _p="$1"; _script="$2"
    _host="$CHD_SCRIPTS/guest/$_script"
    if [ ! -f "$_host" ]; then
        print_message error "guest init script missing: $_host"; return 1
    fi
    mkdir -p "$_p/root/.chd-init"
    cp "$_host" "$_p/root/.chd-init/$_script"
    chmod 0755 "$_p/root/.chd-init/$_script"
    # proc-smi: copy the host tool into the guest (shebang -> /bin/sh). Best-effort.
    if [ -f /system/bin/proc-smi ]; then
        mkdir -p "$_p/usr/local/bin"
        { echo '#!/bin/sh'; tail -n +2 /system/bin/proc-smi; } > "$_p/usr/local/bin/proc-smi" 2>/dev/null \
            && chmod 0755 "$_p/usr/local/bin/proc-smi"
    fi
    # CRITICAL: the guest apt runs here, BEFORE any login/jail, so its DNS resolver
    # must exist NOW or `apt update` fails to resolve mirrors. jail's fix_env runs
    # too late for install; seed resolv.conf (+ localtime) up front, as the original did.
    if command -v _chd_fix_dns >/dev/null 2>&1; then
        _chd_fix_dns "$_p"
    else
        [ -s "$_p/etc/resolv.conf" ] || printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n' > "$_p/etc/resolv.conf" 2>/dev/null || true
    fi
    _tz=$(getprop persist.sys.timezone 2>/dev/null | tr -d '[:space:]')
    [ -z "$_tz" ] && _tz=$(head -n1 /etc/timezone 2>/dev/null | tr -d '[:space:]')
    [ -z "$_tz" ] && _tz="Etc/UTC"
    print_message info "Running guest init ($_script, tz=$_tz) - this installs packages, may take a while..."
    # TMPDIR/HOME must point INSIDE the chroot. The Android host sets
    # TMPDIR=/data/local/tmp which does not exist in the guest, breaking package
    # postinst scripts (ca-certificates, dictionaries-common, cracklib...). Pin
    # them to guest paths (/tmp is the ram-mount tmpfs).
    chroot "$_p" /usr/bin/env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/root TMPDIR=/tmp TERM="${TERM:-xterm}" DEBIAN_FRONTEND=noninteractive \
        TIMEZONE="$_tz" /bin/sh /root/.chd-init/"$_script" --conf /root/.chd-init/profile.conf
}

# Write the GPU-adaptive X11 startup script for the desktop user (decision 8).
# Chooses virpipe at RUNTIME only if /tmp/.virgl_test exists, else softpipe.
_chd_write_xstartup() {
    _xsp="$1"; _xsuser="$2"; _xscmd="$3"; _xspulse="$4"; _xsdisplay="$5"; _xsbe="${6:-softpipe}"
    _xshome="$(_chd_user_home "$_xsp" "$_xsuser")"
    mkdir -p "$_xsp$_xshome"
    cat > "$_xsp$_xshome/.xstartup_native" <<XEOF
#!/bin/sh
export PULSE_SERVER="$_xspulse"
export DISPLAY="$_xsdisplay"
export XAUTHORITY="$_xshome/.Xauthority"
export XFWM4_DISABLE_COMPOSITOR=1
export MESA_NO_ERROR=1
export MESA_GL_VERSION_OVERRIDE=4.3
export MESA_GLES_VERSION_OVERRIDE=3.2
# Desktop session backend is the user's explicit profile choice (DESKTOP_BACKEND).
# virpipe = GPU-accelerated session (faster, may black-screen on some desktops);
# softpipe = software session (stable). Per-app GPU stays available via gpuacc.
# virpipe still self-guards: if the virgl socket is somehow absent, fall back to
# softpipe so the session never launches against a dangling GPU target.
if [ "$_xsbe" = "virpipe" ] && [ -S /tmp/.virgl_test ]; then
    export GALLIUM_DRIVER=virpipe
else
    export GALLIUM_DRIVER=softpipe
    export LIBGL_ALWAYS_SOFTWARE=1
fi
$_xscmd
XEOF
    chmod 0755 "$_xsp$_xshome/.xstartup_native"
    # gpuacc helper: force-GPU prefix for individual apps.
    mkdir -p "$_xsp/usr/local/bin"
    cat > "$_xsp/usr/local/bin/gpuacc" <<'GEOF'
#!/bin/sh
# gpuacc <cmd> - run a command with GPU (virpipe) forced.
export MESA_NO_ERROR=1 MESA_GL_VERSION_OVERRIDE=4.3 MESA_GLES_VERSION_OVERRIDE=3.2 GALLIUM_DRIVER=virpipe
[ "$#" -eq 0 ] && { echo "usage: gpuacc <command> [args...]" >&2; exit 1; }
exec "$@"
GEOF
    chmod 0755 "$_xsp/usr/local/bin/gpuacc"
    # ownership of the user's xstartup (best-effort; guest init also chowns home).
    _xsgid=$(awk -F: -v u="$_xsuser" '$1==u{print $4}' "$_xsp/etc/passwd" 2>/dev/null)
    _xsuid=$(awk -F: -v u="$_xsuser" '$1==u{print $3}' "$_xsp/etc/passwd" 2>/dev/null)
    [ -n "$_xsuid" ] && [ -n "$_xsgid" ] && chown "$_xsuid:$_xsgid" "$_xsp$_xshome/.xstartup_native" 2>/dev/null || true
}

# Register supervisord programs from the profile (host-side; uses supervisor.sh).
chd_register_services() {
    # _rs_* names survive the chd_sv_add_program / _chd_write_xstartup calls
    # (POSIX sh has no locals; callees must not clobber what we need afterwards).
    _rs_name="$1"; _rs_p="$2"
    chd_profile_load "$_rs_name" 2>/dev/null || true
    _rs_user="${USER_NAME:-root}"
    _rs_graphics="${GRAPHICS:-none}"
    _rs_desktop="${DESKTOP:-none}"
    _rs_x11=false; case "$_rs_graphics" in *x11*) _rs_x11=true ;; esac
    _rs_vnc=false; case "$_rs_graphics" in *vnc*) _rs_vnc=true ;; esac
    _rs_ssh="${SSH_ENABLE:-true}"
    _rs_pulse="tcp:127.0.0.1:${PULSE_PORT:-4713}"
    _rs_display=":0"; { [ "$_rs_vnc" = true ] && [ "$_rs_x11" = false ]; } && _rs_display=":${VNC_DISPLAY:-1}"

    if ! chd_sv_installed "$_rs_p"; then
        print_message note "supervisor not installed in guest - services not registered (init may have failed)."
        return 0
    fi
    chd_sv_write_main "$_rs_p"

    # /run is tmpfs (fresh every session): sshd needs its privsep dir recreated
    # each start or it exits immediately after the first reboot.
    [ "$_rs_ssh" = "true" ] && chd_sv_add_program "$_rs_p" sshd \
        "/bin/sh -c 'mkdir -p /run/sshd /var/run/sshd && exec /usr/sbin/sshd -D'" root "" true
    [ -x "$_rs_p/usr/sbin/cron" ] && chd_sv_add_program "$_rs_p" cron "/usr/sbin/cron -f" root "" true

    if [ "$_rs_x11" = "true" ] && [ "$_rs_desktop" != "none" ]; then
        _rs_dcmd="$(_chd_desktop_cmd "$_rs_desktop")"
        _chd_write_xstartup "$_rs_p" "$_rs_user" "$_rs_dcmd" "$_rs_pulse" "$_rs_display" "${DESKTOP_BACKEND:-softpipe}"
        _rs_home="$(_chd_user_home "$_rs_p" "$_rs_user")"
        # user= only setuids; HOME/USER/LOGNAME must be explicit or the DE writes
        # ~/.config etc. to whatever HOME supervisord inherited (broken session).
        _rs_denv="HOME=\"$_rs_home\",USER=\"$_rs_user\",LOGNAME=\"$_rs_user\",SHELL=\"/bin/bash\""
        chd_sv_add_program "$_rs_p" desktop "/bin/sh -lc 'exec $_rs_home/.xstartup_native'" "$_rs_user" "$_rs_denv" true
    fi
    if [ "$_rs_vnc" = "true" ]; then
        _rs_home="$(_chd_user_home "$_rs_p" "$_rs_user")"
        _rs_venv="HOME=\"$_rs_home\",USER=\"$_rs_user\",LOGNAME=\"$_rs_user\""
        # NOTE: no -ncache. x11vnc's client-side pixel cache makes the advertised
        # framebuffer ~(1+N)x TALLER than the real screen (the lower region is a
        # scratch cache). Many VNC clients render that as a mostly-black canvas
        # with the desktop squeezed into a thin vertical strip. Verified on-device
        # that dropping -ncache restores a correct full-screen desktop.
        chd_sv_add_program "$_rs_p" x11vnc \
            "/usr/bin/x11vnc -display :0 -noshm -noxdamage -nowf -nowcr -rfbauth $_rs_home/.vnc/passwd -rfbport 5900 -xkb -shared -forever" \
            "$_rs_user" "$_rs_venv" true
    fi
    print_message info "supervisord programs registered (ssh=$_rs_ssh x11=$_rs_x11 vnc=$_rs_vnc desktop=$_rs_desktop)."
    chd_sv_reload "$_rs_p" 2>/dev/null || true
}

# Login-time self-heal (PLAN 1-6): env/gpuacc/proc-smi are generated once at init,
# and regenerated here if missing (deleted by user, wiped image, etc.).
chd_self_heal() {
    _sh_name="$1"; _sh_p="$2"
    [ -d "$_sh_p/etc" ] || return 0
    chd_profile_load "$_sh_name" 2>/dev/null || true
    # proc-smi
    if [ ! -x "$_sh_p/usr/local/bin/proc-smi" ] && [ -f /system/bin/proc-smi ]; then
        mkdir -p "$_sh_p/usr/local/bin"
        { echo '#!/bin/sh'; tail -n +2 /system/bin/proc-smi; } > "$_sh_p/usr/local/bin/proc-smi" 2>/dev/null \
            && chmod 0755 "$_sh_p/usr/local/bin/proc-smi"
    fi
    # shell env (mirror of what guest init writes)
    if [ ! -f "$_sh_p/etc/profile.d/chd_env.sh" ]; then
        _sh_disp=":0"
        case "${GRAPHICS:-none}" in vnc) _sh_disp=":${VNC_DISPLAY:-1}" ;; esac
        mkdir -p "$_sh_p/etc/profile.d"
        {
            echo '#!/bin/sh'
            echo 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH'
            echo "export PULSE_SERVER=tcp:${PULSE_HOST:-127.0.0.1}:${PULSE_PORT:-4713}"
            echo "export DISPLAY=$_sh_disp"
            echo 'export MESA_NO_ERROR=1'
            echo 'export MESA_GL_VERSION_OVERRIDE=4.3'
            echo 'export MESA_GLES_VERSION_OVERRIDE=3.2'
            echo 'if [ -S /tmp/.virgl_test ]; then export GALLIUM_DRIVER=virpipe; else export GALLIUM_DRIVER=softpipe; export LIBGL_ALWAYS_SOFTWARE=1; fi'
        } > "$_sh_p/etc/profile.d/chd_env.sh"
        chmod 644 "$_sh_p/etc/profile.d/chd_env.sh"
        print_message note "self-heal: regenerated /etc/profile.d/chd_env.sh"
    fi
    # xstartup/gpuacc/supervisor confs for graphics profiles
    case "${GRAPHICS:-none}" in
        *x11*)
            _sh_home="$(_chd_user_home "$_sh_p" "${USER_NAME:-root}")"
            if [ ! -f "$_sh_p$_sh_home/.xstartup_native" ] || [ ! -x "$_sh_p/usr/local/bin/gpuacc" ]; then
                print_message note "self-heal: regenerating xstartup/gpuacc/service confs"
                chd_register_services "$_sh_name" "$_sh_p"
            fi ;;
    esac
    return 0
}

# The dispatcher install() calls. Returns 0 ok, 2 no-backend (extract-only), 1 fail.
chd_distro_init() {
    _name="$1"; _p="$2"
    chd_profile_load "$_name" 2>/dev/null || true
    _fam="$(_chd_family "${DISTRIB:-$_name}")"
    if [ -z "$_fam" ]; then
        print_message note "No init backend for '${DISTRIB:-$_name}' yet - leaving as a bare rootfs (login still works)."
        return 2
    fi
    _chd_write_guest_profile "$_p" "$_name"
    case "$_fam" in
        debian) chd_init_debian "$_name" "$_p" ;;
        *)      print_message note "family '$_fam' not implemented."; return 2 ;;
    esac
}
