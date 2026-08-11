#!/bin/sh
# init_debian.sh - GUEST-side Debian/Ubuntu setup. Runs INSIDE the chroot via
# `chroot ... /bin/sh init_debian.sh --conf profile.conf`. Idempotent + resilient:
# NEVER runs under `set -e` (a transient mirror 404 must not abort the whole init).
# Reads the reborn instance profile.conf. Installs base tools + supervisor + the
# selected desktop, creates the user, configures ssh/pulse/locale, writes the env
# and (for X11+VNC) the VNC password. supervisord PROGRAM confs are written by the
# host (chd_register_services), not here.

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH DEBIAN_FRONTEND=noninteractive

SUMMARY=/tmp/chd_init_summary.log
: > "$SUMMARY" 2>/dev/null || true
log()    { printf '%s\n' "$*"; }
result() { echo "[$1] $2" >> "$SUMMARY" 2>/dev/null || true; }
run()    { log "CMD: $*"; "$@"; }

# --- args / config ----------------------------------------------------------
conf_file=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --conf) shift; conf_file="${1:-}" ;;
        --conf=*) conf_file="${1#*=}" ;;
        *) log "WARN: unknown arg: $1" ;;
    esac
    shift
done
case "$conf_file" in
    /*) : ;;
    *) [ -f "/root/.chd-init/$conf_file" ] && conf_file="/root/.chd-init/$conf_file" ;;
esac
if [ -z "$conf_file" ] || [ ! -f "$conf_file" ]; then
    log "ERROR: no config file: ${conf_file:-<empty>}"; exit 1
fi
log "Loading config: $conf_file"
. "$conf_file"

USER_NAME="${USER_NAME:-user}"
USER_PASSWORD="${USER_PASSWORD:-changeme}"
DESKTOP="${DESKTOP:-none}"
GRAPHICS="${GRAPHICS:-none}"
SSH_ENABLE="${SSH_ENABLE:-true}"
PULSE_ENABLE="${PULSE_ENABLE:-true}"
VNC_PASSWORD="${VNC_PASSWORD:-${USER_PASSWORD}}"
VNC_DISPLAY="${VNC_DISPLAY:-1}"
PULSE_HOST="${PULSE_HOST:-127.0.0.1}"
PULSE_PORT="${PULSE_PORT:-4713}"
LOCALE_TO_GEN="${LOCALE:-en_US.UTF-8}"
TZ_VALUE="${TIMEZONE:-$(cat /etc/timezone 2>/dev/null || echo Etc/UTC)}"

HAS_X11=false; case "$GRAPHICS" in *x11*) HAS_X11=true ;; esac
HAS_VNC=false; case "$GRAPHICS" in *vnc*) HAS_VNC=true ;; esac

if command -v id >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
    log "ERROR: must run as root inside chroot"; exit 1
fi

# --- tzdata preseed (before ANY apt call, to avoid interactive hang) ---------
printf 'tzdata tzdata/Areas select %s\n' "${TZ_VALUE%%/*}" | debconf-set-selections 2>/dev/null || true
printf 'tzdata tzdata/Zones/%s select %s\n' "${TZ_VALUE%%/*}" "${TZ_VALUE#*/}" | debconf-set-selections 2>/dev/null || true
ln -sf "/usr/share/zoneinfo/$TZ_VALUE" /etc/localtime 2>/dev/null || true
printf '%s\n' "$TZ_VALUE" > /etc/timezone 2>/dev/null || true

# --- network + Android group mappings (MUST precede any apt network op) -------
# apt fetches as the _apt user with supplementary groups dropped, so _apt's
# PRIMARY gid must be 3003 (aid_inet) or DNS/download fail on Android paranoid-
# network. This mirrors the original init's Step 7 exactly (runs BEFORE apt).
log "=== Init: network + Android group mappings ==="
printf 'nameserver %s\n' "${DNS:-8.8.8.8}" > /etc/resolv.conf 2>/dev/null || true
printf '127.0.0.1 localhost\n::1 localhost\n' > /etc/hosts 2>/dev/null || true
getent group aid_inet     >/dev/null 2>&1 || groupadd -g 3003 aid_inet     2>/dev/null || true
getent group aid_net_raw  >/dev/null 2>&1 || groupadd -g 3004 aid_net_raw  2>/dev/null || true
getent group aid_graphics >/dev/null 2>&1 || groupadd -g 1003 aid_graphics 2>/dev/null || true
getent group aid_drmrpc   >/dev/null 2>&1 || groupadd -g 1026 aid_drmrpc   2>/dev/null || true
if getent passwd _apt >/dev/null 2>&1; then
    usermod -g 3003 -G 3003,3004 -a _apt 2>/dev/null || true
fi
usermod -G 3003 -a root 2>/dev/null || true
result Success "network + groups"

# --- apt: harden against snapd mirror rotation, then update/upgrade ----------
log "=== Init: apt update/upgrade + base tools ==="
mkdir -p /etc/apt/preferences.d
printf 'Package: snapd\nPin: release a=*\nPin-Priority: -10\n' > /etc/apt/preferences.d/nosnap.pref
apt-get purge -y snapd firefox >/dev/null 2>&1 || true
apt-get autoremove -y >/dev/null 2>&1 || true
apt-get update || true
# Network health gate: if apt got no package lists, everything downstream will
# "Unable to locate" - fail loudly now instead of building a broken instance.
if [ -z "$(ls /var/lib/apt/lists/*Packages* /var/lib/apt/lists/*_InRelease 2>/dev/null)" ]; then
    log "FATAL: apt fetched no package indexes (network/DNS failed inside chroot)."
    log "       _apt needs primary gid 3003; check 'chd debug' and retry 'chd install'."
    result Fatal "apt update produced no indexes - network blocked"
    exit 3
fi
if ! apt-get upgrade -y --fix-missing; then
    log "WARN: upgrade incomplete (transient mirror 404?) - refresh + retry once"
    apt-get update || true
    apt-get upgrade -y --fix-missing || log "WARN: upgrade still incomplete; continuing"
fi
run apt-get install -y coreutils passwd adduser libc-bin || result Warn "base libc tools"
run apt-get install -y net-tools sudo git cron dbus-x11 mesa-utils pulseaudio-utils alsa-utils || result Warn "base tools"
run apt-get install -y mesa-vulkan-drivers vulkan-tools libegl1 libgl1-mesa-dri || result Warn "gl tools"
# supervisor: the in-chroot service manager (systemctl replacement).
run apt-get install -y supervisor || result Warn "supervisor"
result Success "apt base tools"

# --- user + groups ----------------------------------------------------------
log "=== Init: user + groups ==="
getent group storage >/dev/null 2>&1 || groupadd storage 2>/dev/null || true
getent group sudo    >/dev/null 2>&1 || groupadd sudo 2>/dev/null || true
if ! id "$USER_NAME" >/dev/null 2>&1; then
    run adduser --disabled-password --gecos "" "$USER_NAME" || useradd -m -s /bin/bash "$USER_NAME" 2>/dev/null || true
fi
# Add the user to sudo + Android hardware/network groups (created by host prepare).
for g in sudo audio video storage aid_inet aid_graphics aid_video aid_audio aid_input; do
    getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" "$USER_NAME" 2>/dev/null || true
done
if [ -n "$USER_PASSWORD" ]; then
    printf '%s:%s\n' "$USER_NAME" "$USER_PASSWORD" | chpasswd 2>/dev/null || true
fi
printf '%s ALL=(ALL:ALL) ALL\n' "$USER_NAME" > "/etc/sudoers.d/99-$USER_NAME" 2>/dev/null || true
chmod 440 "/etc/sudoers.d/99-$USER_NAME" 2>/dev/null || true
result Success "user + groups"

# --- ssh (optional) ---------------------------------------------------------
if [ "$SSH_ENABLE" = "true" ]; then
    log "=== Init: ssh ==="
    run apt-get install -y openssh-server || result Warn "openssh-server"
    sed -i -E 's/#?PasswordAuthentication .*/PasswordAuthentication yes/g' /etc/ssh/sshd_config 2>/dev/null || true
    sed -i -E 's/#?PermitRootLogin .*/PermitRootLogin yes/g' /etc/ssh/sshd_config 2>/dev/null || true
    mkdir -p /etc/ssh/sshd_config.d
    printf 'PasswordAuthentication yes\nPermitRootLogin yes\n' > /etc/ssh/sshd_config.d/01-chd-allow-password.conf
    mkdir -p /run/sshd /var/run/sshd
    ssh-keygen -A 2>/dev/null || true
    getent passwd sshd >/dev/null 2>&1 && usermod -aG aid_inet sshd 2>/dev/null || true
    result Success "ssh"
fi

# --- pulse (optional) -------------------------------------------------------
if [ "$PULSE_ENABLE" = "true" ]; then
    log "=== Init: pulse ==="
    apt-get install -y libasound2-plugins >/dev/null 2>&1 || true
    printf 'PULSE_SERVER=tcp:%s:%s\nexport PULSE_SERVER\n' "$PULSE_HOST" "$PULSE_PORT" > /etc/profile.d/pulse.sh
    { echo 'pcm.!default { type pulse }'; echo 'ctl.!default { type pulse }'
      echo 'pcm.pulse { type pulse }'; echo 'ctl.pulse { type pulse }'; } > /etc/asound.conf
    result Success "pulse"
fi

# --- locale -----------------------------------------------------------------
log "=== Init: locale ==="
printf 'locales locales/locales_to_be_generated multiselect %s UTF-8\n' "$LOCALE_TO_GEN" | debconf-set-selections 2>/dev/null || true
printf 'locales locales/default_environment_locale select %s\n' "$LOCALE_TO_GEN" | debconf-set-selections 2>/dev/null || true
apt-get install -y locales >/dev/null 2>&1 || true
locale-gen "$LOCALE_TO_GEN" 2>/dev/null || true
update-locale LANG="$LOCALE_TO_GEN" 2>/dev/null || true
result Success "locale"

# --- desktop (only when X11 graphics requested) -----------------------------
if [ "$HAS_X11" = "true" ] && [ "$DESKTOP" != "none" ]; then
    log "=== Init: desktop ($DESKTOP) ==="
    case "$DESKTOP" in
        lxde)  apt-get install -y desktop-base x11-xserver-utils xfonts-base xfonts-utils lxde lxde-common menu-xdg hicolor-icon-theme gtk2-engines || result Warn "lxde"
               [ -e /etc/xdg/autostart/lxpolkit.desktop ] && rm -f /etc/xdg/autostart/lxpolkit.desktop
               [ -e /usr/bin/lxpolkit ] && mv /usr/bin/lxpolkit /usr/bin/lxpolkit.bak 2>/dev/null || true
               # A user autostart (no xscreensaver: it needs GL visuals unavailable
               # under software rendering and freezes the session).
               _uh=$(getent passwd "$USER_NAME" | cut -d: -f6); [ -z "$_uh" ] && _uh="/home/$USER_NAME"
               mkdir -p "$_uh/.config/lxsession/LXDE"
               printf '@lxpanel --profile LXDE\n@pcmanfm --desktop --profile LXDE\n' > "$_uh/.config/lxsession/LXDE/autostart"
               _ug=$(id -gn "$USER_NAME" 2>/dev/null || echo "$USER_NAME")
               chown -R "$USER_NAME:$_ug" "$_uh/.config" 2>/dev/null || true ;;
        xfce)  apt-get install -y desktop-base dbus-x11 x11-xserver-utils xfonts-base xfonts-utils xfce4 xfce4-terminal tango-icon-theme hicolor-icon-theme || result Warn "xfce"
               su - "$USER_NAME" -c "xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s false" 2>/dev/null || true ;;
        mate)  apt-get install -y desktop-base dbus-x11 x11-xserver-utils xfonts-base xfonts-utils mate-core || result Warn "mate" ;;
        lxqt)  apt-get install -y lxqt qterminal pcmanfm-qt featherpad || result Warn "lxqt" ;;
        gnome) apt-get install -y dbus-x11 gnome-session gnome-terminal gnome-control-center || result Warn "gnome" ;;
        kde)   apt-get install -y plasma-desktop konsole dolphin dbus-x11 || result Warn "kde" ;;
        xterm) apt-get install -y desktop-base x11-xserver-utils xfonts-base xfonts-utils xterm || result Warn "xterm" ;;
        *)     log "WARN: unknown DESKTOP=$DESKTOP; skipping" ;;
    esac
    result Success "desktop"
fi

# --- VNC password (X11+VNC mirror) ------------------------------------------
if [ "$HAS_VNC" = "true" ] && [ "$HAS_X11" = "true" ]; then
    log "=== Init: x11vnc + password ==="
    apt-get install -y x11vnc >/dev/null 2>&1 || result Warn "x11vnc"
    _uhome=$(getent passwd "$USER_NAME" | cut -d: -f6); [ -z "$_uhome" ] && _uhome="/home/$USER_NAME"
    mkdir -p "$_uhome/.vnc"
    x11vnc -storepasswd "$VNC_PASSWORD" "$_uhome/.vnc/passwd" 2>/dev/null || true
    chmod 600 "$_uhome/.vnc/passwd" 2>/dev/null || true
    _ug=$(id -gn "$USER_NAME" 2>/dev/null || echo "$USER_NAME")
    chown -R "$USER_NAME:$_ug" "$_uhome/.vnc" 2>/dev/null || true
    result Success "x11vnc password"
fi

# --- env orchestration (write-once shell env; GALLIUM chosen at login by xstartup) ---
log "=== Init: env ==="
RESOLVED_DISPLAY=":0"
{ [ "$HAS_VNC" = "true" ] && [ "$HAS_X11" = "false" ]; } && RESOLVED_DISPLAY=":$VNC_DISPLAY"
cat > /etc/profile.d/chd_env.sh <<EOF
#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH
export PULSE_SERVER=tcp:${PULSE_HOST}:${PULSE_PORT}
export DISPLAY=${RESOLVED_DISPLAY}
export MESA_NO_ERROR=1
export MESA_GL_VERSION_OVERRIDE=4.3
export MESA_GLES_VERSION_OVERRIDE=3.2
# Individual GL apps: use GPU if the virgl socket is present, else software.
if [ -S /tmp/.virgl_test ]; then export GALLIUM_DRIVER=virpipe; else export GALLIUM_DRIVER=softpipe; export LIBGL_ALWAYS_SOFTWARE=1; fi
EOF
chmod 644 /etc/profile.d/chd_env.sh
result Success "env"

# --- snapd block (final) ----------------------------------------------------
apt-get autopurge -y snapd >/dev/null 2>&1 || true

log ""
log "Install Result Summary"
log "----------------------------------------"
cat "$SUMMARY" 2>/dev/null || log "no results recorded"
log "----------------------------------------"
exit 0
