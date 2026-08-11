# lib/services.sh - HOST-side service orchestration (runs in Termux/root context,
# OUTSIDE the chroot) + the login hook that ensures guest supervisord is up.
# Distro-agnostic (OSMD). Faithful port of the original host_run_in_termux + the
# virgl/x11/pulse socket-wait + bind-mount flows.

CHD_TERMUX_DIR="/data/data/com.termux"
CHD_TERMUX_PREFIX="$CHD_TERMUX_DIR/files/usr"
CHD_TERMUX_TMP="$CHD_TERMUX_PREFIX/tmp"
CHD_X11_DISPLAY="${X11_DISPLAY:-0}"
CHD_PULSE_PORT="${PULSE_PORT:-4713}"

# Run a command as the Termux app user, with Termux env + network GIDs, then
# relabel Termux symlinks (root-via-su poisons their SELinux MCS categories).
host_run_in_termux() {
    _tu=$(stat -c %u "$CHD_TERMUX_DIR" 2>/dev/null)
    if [ -z "$_tu" ] || [ "$_tu" = "0" ] || [ "$_tu" = "root" ]; then
        # No Termux (or unresolvable owner) - best effort run as-is.
        sh -c "$*"
        return
    fi
    su "$_tu" -G 3003 -G 3004 -G 3005 -c "env PREFIX=$CHD_TERMUX_PREFIX \
LD_LIBRARY_PATH=$CHD_TERMUX_PREFIX/lib \
PATH=$CHD_TERMUX_PREFIX/bin:/system/bin \
HOME=$CHD_TERMUX_DIR/files/home \
TMPDIR=$CHD_TERMUX_PREFIX/tmp \
/system/bin/sh -c \"cd \$HOME && $*\""
    _rc=$?
    # SELinux MCS heal: only per-file relabel reliably fixes poisoned symlinks.
    if command -v restorecon >/dev/null 2>&1; then
        find "$CHD_TERMUX_DIR" -type l -exec restorecon {} \; >/dev/null 2>&1 || true
    fi
    return $_rc
}

_chd_termux_present() { [ -d "$CHD_TERMUX_DIR" ]; }

# --- PulseAudio (host) ------------------------------------------------------
chd_host_pulse() {
    _log="$1"
    _chd_termux_present || { print_message warning "Termux not found; skipping PulseAudio."; return 1; }
    print_message info "Starting host PulseAudio (port $CHD_PULSE_PORT)..."
    host_run_in_termux "PULSE_PORT=$CHD_PULSE_PORT sh $CHD_SCRIPTS/host/host_start_pulseaudio.sh" >> "$_log" 2>&1
    # Honest check: is something listening on the pulse TCP port?
    if _chd_port_listening "$CHD_PULSE_PORT"; then
        print_message info "[OK] PulseAudio listening on 127.0.0.1:$CHD_PULSE_PORT."
        return 0
    fi
    print_message warning "PulseAudio not confirmed listening on $CHD_PULSE_PORT (see host log)."
    return 1
}

_chd_port_listening() {
    _port="$1"
    # hex port for /proc/net/tcp scan (portable, no ss/netstat dependency).
    _hex=$(printf '%04X' "$_port" 2>/dev/null)
    [ -n "$_hex" ] || return 1
    grep -qi ":$_hex " /proc/net/tcp 2>/dev/null || grep -qi ":$_hex " /proc/net/tcp6 2>/dev/null
}

# --- Termux:X11 (host) ------------------------------------------------------
chd_host_x11() {
    _p="$1"; _log="$2"
    if [ ! -d "/data/data/com.termux.x11" ]; then
        print_message error "Termux:X11 app not installed - cannot start X11 graphics."
        return 1
    fi
    print_message info "Starting Termux:X11 bindings (display :$CHD_X11_DISPLAY)..."
    host_run_in_termux "X11_DISPLAY=$CHD_X11_DISPLAY sh $CHD_SCRIPTS/host/host_start_x11.sh" >> "$_log" 2>&1 || true
    _sock="$CHD_TERMUX_TMP/.X11-unix/X$CHD_X11_DISPLAY"
    _i=0
    while [ "$_i" -lt 6 ]; do
        [ -S "$_sock" ] && break
        sleep 0.5; _i=$((_i+1))
    done
    if [ ! -S "$_sock" ]; then
        print_message error "Termux:X11 socket not found ($_sock). Open the Termux:X11 app, then retry."
        return 1
    fi
    mkdir -p "$_p/tmp/.X11-unix"
    if chd_is_mounted "$_p/tmp/.X11-unix"; then
        print_message info "[OK] X11 socket already bound."
    elif mount --bind "$CHD_TERMUX_TMP/.X11-unix" "$_p/tmp/.X11-unix" 2>/dev/null; then
        print_message info "[OK] X11 socket bound into guest."
    else
        print_message error "Failed to bind .X11-unix into guest."
        return 1
    fi
    return 0
}

# --- virgl / GPU (host) -----------------------------------------------------
chd_host_virgl() {
    _p="$1"; _log="$2"
    _chd_termux_present || { print_message error "Termux not found - cannot start virgl."; return 1; }
    print_message info "Starting host virgl server..."
    host_run_in_termux "sh $CHD_SCRIPTS/host/host_start_virgl.sh" >> "$_log" 2>&1 || true
    _sock="$CHD_TERMUX_TMP/.virgl_test"
    _i=0
    while [ "$_i" -lt 10 ]; do
        [ -S "$_sock" ] && break
        sleep 0.5; _i=$((_i+1))
    done
    if [ ! -S "$_sock" ]; then
        print_message warning "virgl socket not present ($_sock) - GPU accel unavailable; desktop will use softpipe."
        [ -f "$CHD_TERMUX_TMP/chd_host_virgl.log" ] && {
            print_message note "--- host_start_virgl.sh log ---"
            cat "$CHD_TERMUX_TMP/chd_host_virgl.log" >&2
        }
        return 1
    fi
    # Expose the socket inside the chroot at the standard /tmp/.virgl_test path.
    mkdir -p "$_p/tmp/host_virgl"
    if chd_is_mounted "$_p/tmp/host_virgl"; then
        :
    elif mount --bind "$CHD_TERMUX_TMP" "$_p/tmp/host_virgl" 2>/dev/null; then
        chmod 666 "$_p/tmp/host_virgl/.virgl_test" 2>/dev/null || true
    else
        print_message error "Failed to bind Termux tmp for virgl."
        return 1
    fi
    ln -sf /tmp/host_virgl/.virgl_test "$_p/tmp/.virgl_test" 2>/dev/null || true
    print_message info "[OK] virgl socket exposed at guest /tmp/.virgl_test."
    return 0
}

# --- the login hook: bring up host services, then ensure guest supervisord ---
# chd_services_up <name> <path>  (called from login/command; profile already
# loaded by the caller, but we re-derive defensively).
chd_services_up() {
    _name="$1"; _p="$2"
    chd_profile_load "$_name" 2>/dev/null || true
    _graphics="${GRAPHICS:-none}"
    _has_x11=false;  case "$_graphics" in *x11*) _has_x11=true ;; esac
    _has_vnc=false;  case "$_graphics" in *vnc*) _has_vnc=true ;; esac
    _virgl="${VIRGL_ENABLE:-false}"
    _pulse="${PULSE_ENABLE:-true}"

    mkdir -p "$CHD_ROOT/log"
    _hlog="$CHD_ROOT/log/host_services.log"; : > "$_hlog"

    # 0) self-heal guest-side artifacts init created (env/gpuacc/proc-smi/xstartup)
    if command -v chd_self_heal >/dev/null 2>&1; then
        chd_self_heal "$_name" "$_p"
    fi

    # 1) host audio
    [ "$_pulse" = "true" ] && chd_host_pulse "$_hlog"
    # 2) host X11 bindings (needed by desktop + vnc mirror)
    if [ "$_has_x11" = "true" ]; then
        chd_host_x11 "$_p" "$_hlog" || print_message warning "X11 host bring-up failed."
    fi
    # 3) host GPU (only if the profile asked for it)
    if [ "$_virgl" = "true" ]; then
        chd_host_virgl "$_p" "$_hlog" || true   # non-fatal: desktop falls back to softpipe
    fi
    # 4) guest service manager (systemctl replacement). Absorbs the old "startup".
    if command -v chd_sv_ensure >/dev/null 2>&1; then
        chd_sv_reload "$_p" 2>/dev/null || true
        chd_sv_ensure "$_p"; _svrc=$?
        if [ "$_svrc" = 2 ]; then
            print_message note "Guest services will be managed once init installs supervisord (chd install)."
        fi
    fi
    return 0
}
