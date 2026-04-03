#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must run as root inside the chroot." >&2
  exit 1
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
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
  shift
done

if [ -z "$conf_file" ] || [ ! -f "$conf_file" ]; then
  echo "no input config file" >&2
  exit 1
fi

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
  echo "Missing CHROOT_USER/USER_NAME in config" >&2
  exit 1
fi

echo "[Step 7] Network + Android group mappings"
# Step 7: basic network + Android group mappings
printf "nameserver 8.8.8.8\n" > /etc/resolv.conf
printf "127.0.0.1 localhost\n::1 localhost\n" > /etc/hosts

getent group aid_inet >/dev/null 2>&1 || groupadd -g 3003 aid_inet
getent group aid_net_raw >/dev/null 2>&1 || groupadd -g 3004 aid_net_raw
getent group aid_graphics >/dev/null 2>&1 || groupadd -g 1003 aid_graphics

if id _apt >/dev/null 2>&1; then
  usermod -g 3003 -G 3003,3004 -a _apt || true
fi
usermod -G 3003 -a root || true

echo "[Step 7] apt update/upgrade + base tools"
apt update
apt upgrade -y
apt install -y vim net-tools sudo git

echo "[Step 8] Timezone configuration"
# Step 8: timezone (non-interactive)
apt install -y tzdata
dpkg-reconfigure tzdata

echo "[Step 9] User creation and groups"
# Step 9: user creation
getent group storage >/dev/null 2>&1 || groupadd storage
getent group wheel >/dev/null 2>&1 || groupadd wheel
getent group users >/dev/null 2>&1 || groupadd users
if ! id "${CHROOT_USER}" >/dev/null 2>&1; then
  useradd -m -g users -G wheel,audio,video,storage,aid_inet -s /bin/bash "${CHROOT_USER}"
fi
if [ -n "${CHROOT_PASS}" ]; then
  printf "%s:%s\n" "${CHROOT_USER}" "${CHROOT_PASS}" | chpasswd
fi

echo "[Step 10] Sudoers configuration"
# Step 10: sudoers drop-in (avoids visudo)
printf "%s ALL=(ALL:ALL) ALL\n" "${CHROOT_USER}" > "/etc/sudoers.d/99-${CHROOT_USER}"
chmod 440 "/etc/sudoers.d/99-${CHROOT_USER}"

echo "[Step 10] SSH setup (optional)"
# Linux Deploy extra: ssh
if [ "${CHROOT_SSH}" = "true" ]; then
  apt install -y openssh-server
  sed -i -E 's/#?PasswordAuthentication .*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
  sed -i -E 's/#?PermitRootLogin .*/PermitRootLogin yes/g' /etc/ssh/sshd_config
  sed -i -E 's/#?AcceptEnv .*/AcceptEnv LANG/g' /etc/ssh/sshd_config
fi

echo "[Step 10] PulseAudio setup (optional)"
# Linux Deploy extra: pulse
if [ "${CHROOT_PULSE}" = "true" ]; then
  apt install -y libasound2-plugins
  if [ -d /etc/profile.d ]; then
    printf "PULSE_SERVER=%s:%s\nexport PULSE_SERVER\n" "${CHROOT_PULSE_HOST}" "${CHROOT_PULSE_PORT}" > /etc/profile.d/pulse.sh
  fi
  {
    echo "pcm.!default { type pulse }"
    echo "ctl.!default { type pulse }"
    echo "pcm.pulse { type pulse }"
    echo "ctl.pulse { type pulse }"
  } > /etc/asound.conf
fi

echo "[Step 11] Locales"
# Step 11: locales
apt install -y locales
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

echo "[Step 12] Desktop environment"
# Step 12: desktop environment
case "${CHROOT_DESKTOP}" in
  lxde)
    apt install -y desktop-base x11-xserver-utils xfonts-base xfonts-utils lxde lxde-common menu-xdg hicolor-icon-theme gtk2-engines
    echo 'exec startlxde' > "/home/${CHROOT_USER}/.xsession"
    if [ -e /etc/xdg/autostart/lxpolkit.desktop ]; then
      rm /etc/xdg/autostart/lxpolkit.desktop
    fi
    if [ -e /usr/bin/lxpolkit ]; then
      mv /usr/bin/lxpolkit /usr/bin/lxpolkit.bak
    fi
    chown "${CHROOT_USER}:${CHROOT_USER}" "/home/${CHROOT_USER}/.xsession"
    ;;
  mate)
    apt install -y desktop-base dbus-x11 x11-xserver-utils xfonts-base xfonts-utils mate-core
    {
      echo 'XKL_XMODMAP_DISABLE=1'
      echo 'export XKL_XMODMAP_DISABLE'
      echo 'exec dbus-launch --exit-with-session mate-session'
    } > "/home/${CHROOT_USER}/.xsession"
    chown "${CHROOT_USER}:${CHROOT_USER}" "/home/${CHROOT_USER}/.xsession"
    ;;
  xterm)
    apt install -y desktop-base x11-xserver-utils xfonts-base xfonts-utils xterm
    echo 'exec xterm -max' > "/home/${CHROOT_USER}/.xsession"
    chown "${CHROOT_USER}:${CHROOT_USER}" "/home/${CHROOT_USER}/.xsession"
    ;;
  xfce)
    apt install -y desktop-base dbus-x11 x11-xserver-utils xfonts-base xfonts-utils xfce4 xfce4-terminal tango-icon-theme hicolor-icon-theme
    echo 'exec dbus-launch --exit-with-session xfce4-session' > "/home/${CHROOT_USER}/.xsession"
    chown "${CHROOT_USER}:${CHROOT_USER}" "/home/${CHROOT_USER}/.xsession"
    ;;
  kde)
    apt install -y kubuntu-desktop
    ;;
  none)
    ;;
  *)
    echo "Unknown CHROOT_DESKTOP='${CHROOT_DESKTOP}'. Use lxde, xfce, mate, xterm, kde, or none." >&2
    exit 1
    ;;
 esac

  echo "[Step 12] VNC setup (optional)"
  # Linux Deploy extra: vnc
  if [ "${CHROOT_VNC}" = "true" ]; then
    apt install -y tightvncserver
    vnc_home="/home/${CHROOT_USER}/.vnc"
    mkdir -p "${vnc_home}"
    echo "${CHROOT_VNC_PASS}" | vncpasswd -f > "${vnc_home}/passwd" || true
    chmod 600 "${vnc_home}/passwd"
    ln -sf ../.xinitrc "${vnc_home}/xstartup"
    chown -R "${CHROOT_USER}:${CHROOT_USER}" "${vnc_home}"
    printf "VNC ready: :%s %sx%s depth %s\n" "${CHROOT_VNC_DISPLAY}" "${CHROOT_VNC_WIDTH}" "${CHROOT_VNC_HEIGHT}" "${CHROOT_VNC_DEPTH}"
  fi

  echo "[Step 12] X11 setup (optional)"
  # Linux Deploy extra: x11 hint
  if [ "${CHROOT_X11}" = "true" ]; then
    echo "X11 ready. Use: export DISPLAY=127.0.0.1:0"
  fi

echo "[Step 13] Disable snapd"
# Step 13: disable snapd
apt-get autopurge -y snapd || true
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
