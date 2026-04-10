#!/bin/sh
set -eu

DEBUG_TRACE="${DEBUG_TRACE:-false}"
if [ "${DEBUG_TRACE}" = "true" ]; then
  set -x
fi

log() {
  printf "%s\n" "$*"
}

run() {
  log "CMD: $*"
  "$@"
}

# Ensure standard paths are available inside a minimal rootfs.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

if command -v id >/dev/null 2>&1; then
  if [ "$(id -u)" -ne 0 ]; then
    log "ERROR: This script must run as root inside the chroot."
    exit 1
  fi
else
  log "WARN: 'id' not found; assuming root inside chroot."
fi

conf_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --conf)
      shift
      conf_file="${1:-}"
      ;;
    --conf=*)
      conf_file="${1#*=}"
      ;;
    *)
      log "ERROR: Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

# Normalize config path: prefer absolute paths; if relative, resolve against cwd and /root/.chd-init
case "$conf_file" in
  /*) : ;;
  *)
    if [ -f "./$conf_file" ]; then
      conf_file="$(pwd)/$conf_file"
    elif [ -f "/root/.chd-init/$conf_file" ]; then
      conf_file="/root/.chd-init/$conf_file"
    fi
    ;;
esac

if [ -z "$conf_file" ] || [ ! -f "$conf_file" ]; then
  log "ERROR: no input config file: ${conf_file:-<empty>}"
  exit 1
fi

log "Loading config: ${conf_file}"
. "$conf_file"

has_include() {
  case " ${INCLUDE:-} " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Map Linux Deploy-style config values to script variables.
CHROOT_USER="${CHROOT_USER:-${USER_NAME:-}}"
CHROOT_PASS="${CHROOT_PASS:-${USER_PASSWORD:-}}"
CHROOT_DESKTOP="${CHROOT_DESKTOP:-${DESKTOP:-xfce}}"
CHROOT_SSH="${CHROOT_SSH:-${SSH_ENABLE:-true}}"
CHROOT_PULSE="${CHROOT_PULSE:-${PULSE_ENABLE:-true}}"
CHROOT_VNC="${CHROOT_VNC:-${VNC_ENABLE:-false}}"
CHROOT_VNC_PASS="${CHROOT_VNC_PASS:-${VNC_PASSWORD:-${CHROOT_PASS:-changeme}}}"
CHROOT_VNC_DISPLAY="${CHROOT_VNC_DISPLAY:-${VNC_DISPLAY:-0}}"
CHROOT_VNC_DEPTH="${CHROOT_VNC_DEPTH:-${VNC_DEPTH:-16}}"
CHROOT_VNC_DPI="${CHROOT_VNC_DPI:-${VNC_DPI:-75}}"
CHROOT_VNC_WIDTH="${CHROOT_VNC_WIDTH:-${VNC_WIDTH:-800}}"
CHROOT_VNC_HEIGHT="${CHROOT_VNC_HEIGHT:-${VNC_HEIGHT:-480}}"
CHROOT_X11="${CHROOT_X11:-${X11_ENABLE:-false}}"
CHROOT_PULSE_HOST="${CHROOT_PULSE_HOST:-${PULSE_HOST:-127.0.0.1}}"
CHROOT_PULSE_PORT="${CHROOT_PULSE_PORT:-${PULSE_PORT:-4712}}"
CHROOT_SSH_PORT="${CHROOT_SSH_PORT:-${SSH_PORT:-22}}"
CHROOT_SSH_ARGS="${CHROOT_SSH_ARGS:-${SSH_ARGS:-}}"

if [ -n "${INCLUDE:-}" ]; then
  log "INCLUDE detected: ${INCLUDE}"
  has_include "extra/ssh" && CHROOT_SSH="true" || CHROOT_SSH="false"
  has_include "extra/pulse" && CHROOT_PULSE="true" || CHROOT_PULSE="false"
  has_include "graphics/vnc" && CHROOT_VNC="true" || CHROOT_VNC="false"
  has_include "graphics/x11" && CHROOT_X11="true" || CHROOT_X11="false"

  if has_include "graphics"; then
    case "${GRAPHICS:-}" in
      vnc) CHROOT_VNC="true" ;;
      x11) CHROOT_X11="true" ;;
    esac
  fi

  if has_include "desktop/lxde"; then
    CHROOT_DESKTOP="lxde"
  elif has_include "desktop/xfce"; then
    CHROOT_DESKTOP="xfce"
  elif has_include "desktop/mate"; then
    CHROOT_DESKTOP="mate"
  elif has_include "desktop/xterm"; then
    CHROOT_DESKTOP="xterm"
  fi
fi

if [ -z "${CHROOT_USER}" ]; then
  log "ERROR: Missing CHROOT_USER/USER_NAME in config"
  exit 1
fi

log "[Step 7] Network + Android group mappings"
# Step 7: basic network + Android group mappings
log "CMD: write /etc/resolv.conf"
printf "nameserver 8.8.8.8\n" > /etc/resolv.conf
log "CMD: write /etc/hosts"
printf "127.0.0.1 localhost\n::1 localhost\n" > /etc/hosts

# Ensure Android-specific groups and memberships exist BEFORE any apt network operations.
# Some chroot environments lack `groupadd`/`usermod` but we can create group entries
# and append users directly to /etc/group as a fallback so APT (which downloads as
# the `_apt` user) has network permission.
getent group aid_inet >/dev/null 2>&1 || groupadd -g 3003 aid_inet
getent group aid_net_raw >/dev/null 2>&1 || groupadd -g 3004 aid_net_raw
getent group aid_graphics >/dev/null 2>&1 || groupadd -g 1003 aid_graphics
usermod -g 3003 -G 3003,3004 -a _apt
usermod -G 3003 -a root

log "[Step 7] apt update/upgrade + base tools"
run apt update
run apt upgrade -y
run apt install -y coreutils passwd adduser libc-bin
run apt install -y vim net-tools sudo git dbus-x11

log "[Step 8] Timezone configuration"
# Ensure debconf runs noninteractive and preseed tzdata to avoid prompts
export DEBIAN_FRONTEND=noninteractive
# Preseed tzdata to avoid interactive prompts
TZ_VALUE="${TIMEZONE:-$(cat /etc/timezone 2>/dev/null || true)}"
[ -z "${TZ_VALUE}" ] && TZ_VALUE="Etc/UTC"
AREA="${TZ_VALUE%%/*}"
ZONE="${TZ_VALUE#*/}"
printf "tzdata tzdata/Areas select %s\n" "${AREA}" | debconf-set-selections || true
printf "tzdata tzdata/Zones/%s select %s\n" "${AREA}" "${ZONE}" | debconf-set-selections || true
run apt install -y tzdata
printf "%s\n" "${TZ_VALUE}" > /etc/timezone
if [ -f "/usr/share/zoneinfo/${TZ_VALUE}" ]; then
  ln -sf "/usr/share/zoneinfo/${TZ_VALUE}" /etc/localtime
fi
dpkg-reconfigure -f noninteractive tzdata || true

log "[Step 9] User creation and groups"
# Step 9: user creation (Ubuntu default: adduser creates user group)
if getent group storage >/dev/null 2>&1; then
  log "storage group already exists"
else
  run groupadd storage
fi
if getent group sudo >/dev/null 2>&1; then
  log "sudo group already exists"
else
  run groupadd sudo
fi
if ! id "${CHROOT_USER}" >/dev/null 2>&1; then
  log "Creating user with adduser (Ubuntu default behavior)"
  run adduser --disabled-password --gecos "" "${CHROOT_USER}"
  run usermod -aG sudo,audio,video,storage,aid_inet "${CHROOT_USER}"
else
  log "User ${CHROOT_USER} already exists"
fi
if [ -n "${CHROOT_PASS}" ]; then
  log "CMD: set password for ${CHROOT_USER}"
  printf "%s:%s\n" "${CHROOT_USER}" "${CHROOT_PASS}" | chpasswd
else
  log "No CHROOT_PASS provided, skipping password set"
fi

log "[Step 10] Sudoers configuration"
# Step 10: sudoers drop-in (avoids visudo)
log "CMD: write /etc/sudoers.d/99-${CHROOT_USER}"
printf "%s ALL=(ALL:ALL) ALL\n" "${CHROOT_USER}" > "/etc/sudoers.d/99-${CHROOT_USER}"
run chmod 440 "/etc/sudoers.d/99-${CHROOT_USER}"

log "[Step 10] SSH setup (optional)"
# Linux Deploy extra: ssh
if [ "${CHROOT_SSH}" = "true" ]; then
  log "SSH enabled"
  run apt install -y openssh-server
  run sed -i -E 's/#?PasswordAuthentication .*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
  run sed -i -E 's/#?PermitRootLogin .*/PermitRootLogin yes/g' /etc/ssh/sshd_config
  run sed -i -E 's/#?AcceptEnv .*/AcceptEnv LANG/g' /etc/ssh/sshd_config
else
  log "SSH disabled"
fi

log "[Step 10] PulseAudio setup (optional)"
# Linux Deploy extra: pulse
if [ "${CHROOT_PULSE}" = "true" ]; then
  log "PulseAudio enabled"
  run apt install -y libasound2-plugins
  if [ -d /etc/profile.d ]; then
# Install base tools early so `groupadd`/`usermod` exist before use.
    log "CMD: write /etc/profile.d/pulse.sh"
    printf "PULSE_SERVER=%s:%s\nexport PULSE_SERVER\n" "${CHROOT_PULSE_HOST}" "${CHROOT_PULSE_PORT}" > /etc/profile.d/pulse.sh
  fi
  log "CMD: write /etc/asound.conf"
  {
    echo "pcm.!default { type pulse }"
    echo "ctl.!default { type pulse }"
    echo "pcm.pulse { type pulse }"
    echo "ctl.pulse { type pulse }"
  } > /etc/asound.conf
else
  log "PulseAudio disabled"
fi

log "[Step 11] Locales"
# Step 11: locales
LOCALE_TO_GEN="${LOCALE:-en_US.UTF-8}"
printf "locales locales/locales_to_be_generated multiselect %s UTF-8\n" "${LOCALE_TO_GEN}" | debconf-set-selections || true
printf "locales locales/default_environment_locale select %s\n" "${LOCALE_TO_GEN}" | debconf-set-selections || true
run apt install -y locales
run locale-gen "${LOCALE_TO_GEN}"
run update-locale LANG="${LOCALE_TO_GEN}"

log "[Step 12] Desktop environment"
# Step 12: desktop environment
case "${CHROOT_DESKTOP}" in
  lxde)
    log "Desktop: lxde"
    run apt install -y desktop-base x11-xserver-utils xfonts-base xfonts-utils lxde lxde-common menu-xdg hicolor-icon-theme gtk2-engines
    log "CMD: write /home/${CHROOT_USER}/.xsession"
    echo 'exec startlxde' > "/home/${CHROOT_USER}/.xsession"
    if [ -e /etc/xdg/autostart/lxpolkit.desktop ]; then
      run rm /etc/xdg/autostart/lxpolkit.desktop
    fi
    if [ -e /usr/bin/lxpolkit ]; then
      run mv /usr/bin/lxpolkit /usr/bin/lxpolkit.bak
    fi
    user_group="$(id -gn "${CHROOT_USER}")"
    run chown "${CHROOT_USER}:${user_group}" "/home/${CHROOT_USER}/.xsession"
    ;;
  mate)
    log "Desktop: mate"
    run apt install -y desktop-base dbus-x11 x11-xserver-utils xfonts-base xfonts-utils mate-core
    log "CMD: write /home/${CHROOT_USER}/.xsession"
    {
      echo 'XKL_XMODMAP_DISABLE=1'
      echo 'export XKL_XMODMAP_DISABLE'
      echo 'exec dbus-launch --exit-with-session mate-session'
    } > "/home/${CHROOT_USER}/.xsession"
    user_group="$(id -gn "${CHROOT_USER}")"
    run chown "${CHROOT_USER}:${user_group}" "/home/${CHROOT_USER}/.xsession"
    ;;
  xterm)
    log "Desktop: xterm"
    run apt install -y desktop-base x11-xserver-utils xfonts-base xfonts-utils xterm
    log "CMD: write /home/${CHROOT_USER}/.xsession"
    echo 'exec xterm -max' > "/home/${CHROOT_USER}/.xsession"
    user_group="$(id -gn "${CHROOT_USER}")"
    run chown "${CHROOT_USER}:${user_group}" "/home/${CHROOT_USER}/.xsession"
    ;;
  xfce)
    log "Desktop: xfce"
    run apt install -y desktop-base dbus-x11 x11-xserver-utils xfonts-base xfonts-utils xfce4 xfce4-terminal tango-icon-theme hicolor-icon-theme
    log "CMD: write /home/${CHROOT_USER}/.xsession"
    echo 'exec dbus-launch --exit-with-session xfce4-session' > "/home/${CHROOT_USER}/.xsession"
    user_group="$(id -gn "${CHROOT_USER}")"
    run chown "${CHROOT_USER}:${user_group}" "/home/${CHROOT_USER}/.xsession"
    ;;
  kde)
    log "Desktop: kde"
    run apt install -y kubuntu-desktop
    ;;
  none)
    log "Desktop: none"
    ;;
  *)
    log "ERROR: Unknown CHROOT_DESKTOP='${CHROOT_DESKTOP}'. Use lxde, xfce, mate, xterm, kde, or none."
    exit 1
    ;;
 esac

  log "[Step 12] VNC setup (optional)"
  # Linux Deploy extra: vnc
  if [ "${CHROOT_VNC}" = "true" ]; then
    log "VNC enabled"
    run apt install -y tigervnc-standalone-server
    vnc_home="/home/${CHROOT_USER}/.vnc"
    run mkdir -p "${vnc_home}"
    log "CMD: write VNC password"
    echo "${CHROOT_VNC_PASS}" | vncpasswd -f > "${vnc_home}/passwd" || true
    run chmod 600 "${vnc_home}/passwd"
  cat > "${vnc_home}/xstartup" <<'EOF'
#!/bin/sh
export XKL_XMODMAP_DISABLE=1
export DISPLAY=:${CHROOT_VNC_DISPLAY}
exec dbus-launch --exit-with-session startxfce4
EOF
  run chmod +x "${vnc_home}/xstartup"
    user_group="$(id -gn "${CHROOT_USER}")"
    run chown -R "${CHROOT_USER}:${user_group}" "${vnc_home}"
    printf "VNC ready: :%s %sx%s depth %s\n" "${CHROOT_VNC_DISPLAY}" "${CHROOT_VNC_WIDTH}" "${CHROOT_VNC_HEIGHT}" "${CHROOT_VNC_DEPTH}"
  else
    log "VNC disabled"
  fi

  log "[Step 12] X11 setup (optional)"
  # Linux Deploy extra: x11 hint
  if [ "${CHROOT_X11}" = "true" ]; then
    echo "X11 ready. Use: export DISPLAY=127.0.0.1:0"
  else
    log "X11 disabled"
  fi

log "[Step 13] Disable snapd"
# Step 13: disable snapd
run apt-get autopurge -y snapd || true
log "CMD: write /etc/apt/preferences.d/nosnap.pref"
cat <<'EOF' > /etc/apt/preferences.d/nosnap.pref
# To prevent repository packages from triggering the installation of Snap,
# this file forbids snapd from being installed by APT.
# For more information: https://linuxmint-user-guide.readthedocs.io/en/latest/snap.html
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF

cat <<EOF
Done.

Next steps (run from host):
- Start the desktop with chroot-distro command, for example:
  chroot-distro command ubuntu "su - ${CHROOT_USER} -c 'export DISPLAY=:0 PULSE_SERVER=tcp:127.0.0.1:4713 ; dbus-launch --exit-with-session startxfce4'"

If you want KDE, replace startxfce4 with startplasma-x11.
EOF
