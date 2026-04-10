#!/bin/sh
set -eu

# Start VNC server inside chroot for CHROOT_USER using settings from
# /root/.chd-init/noble_final.conf if available.
CONF="/root/.chd-init/noble_final.conf"
[ -f "$CONF" ] && . "$CONF"

log() { printf "%s\n" "[chroot-start-vnc] $*"; }

: ${CHROOT_USER:=root}
: ${CHROOT_VNC_DISPLAY:=1}
: ${CHROOT_VNC_WIDTH:=800}
: ${CHROOT_VNC_HEIGHT:=480}
: ${CHROOT_VNC_DEPTH:=16}

# Prefer DESKTOP from config if CHROOT_DESKTOP not set
CHROOT_DESKTOP="${CHROOT_DESKTOP:-${DESKTOP:-xfce}}"

# Resolve user home directory
user_home=$(getent passwd "${CHROOT_USER}" | cut -d: -f6 2>/dev/null || echo "/root")
vnc_home="${user_home}/.vnc"

if ! command -v vncserver >/dev/null 2>&1; then
  log "vncserver not found; install tigervnc-standalone-server in init script"
  exit 1
fi

log "Preparing VNC xstartup for user ${CHROOT_USER} (home=${user_home})"
run mkdir -p "${vnc_home}"

# Choose desktop start command based on CHROOT_DESKTOP
case "${CHROOT_DESKTOP}" in
  lxde) desktop_cmd='exec dbus-launch --exit-with-session startlxde' ;;
  mate) desktop_cmd='exec dbus-launch --exit-with-session mate-session' ;;
  xterm) desktop_cmd='exec xterm -max' ;;
  xfce) desktop_cmd='exec dbus-launch --exit-with-session startxfce4' ;;
  kde) desktop_cmd='exec dbus-launch --exit-with-session startplasma-x11' ;;
  *) desktop_cmd='exec dbus-launch --exit-with-session startxfce4' ;;
esac

# Verify the desktop command exists; if not, fall back to xterm
desktop_bin=$(echo "${desktop_cmd}" | awk '{print $NF}')
if ! command -v "${desktop_bin}" >/dev/null 2>&1; then
  log "Warning: desktop command '${desktop_bin}' not found; falling back to xterm"
  desktop_cmd='exec /usr/bin/xterm'
fi

cat > "${vnc_home}/xstartup" <<EOF
#!/bin/sh
export XKL_XMODMAP_DISABLE=1
export DISPLAY=:${CHROOT_VNC_DISPLAY}
${desktop_cmd}
EOF

run chmod +x "${vnc_home}/xstartup"
run chown -R "${CHROOT_USER}:$(id -gn "${CHROOT_USER}" 2>/dev/null || "${CHROOT_USER}")" "${vnc_home}"

vnc_cmd="vncserver :${CHROOT_VNC_DISPLAY} -geometry ${CHROOT_VNC_WIDTH}x${CHROOT_VNC_HEIGHT} -depth ${CHROOT_VNC_DEPTH} -localhost no"

log "Starting VNC for user ${CHROOT_USER} on :${CHROOT_VNC_DISPLAY} (TCP port $((5900 + CHROOT_VNC_DISPLAY)))"
su - "${CHROOT_USER}" -c "$vnc_cmd" || log "vncserver returned $?"
