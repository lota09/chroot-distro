#!/system/bin/sh
set -eu

PROFILE_DIR="/data/local/chroot-distro/.profile"
DEFAULT_CONF_CANDIDATES="${CHD_DEFAULT_CONF:-} /data/local/chroot-distro/default.conf /data/local/chroot-distro/.config/default.conf"

log() {
  printf "%s\n" "$*"
}

prompt_default() {
  prompt="$1"
  default="$2"
  if [ -n "$default" ]; then
    printf "%s [%s]: " "$prompt" "$default" >&2
  else
    printf "%s: " "$prompt" >&2
  fi
  IFS= read -r value
  if [ -z "$value" ]; then
    value="$default"
  fi
  printf "%s" "$value"
}

prompt_yes_no() {
  prompt="$1"
  default="$2"
  if [ "$default" = "true" ]; then
    label="Y/n"
  else
    label="y/N"
  fi
  while true; do
    printf "%s [%s]: " "$prompt" "$label" >&2
    IFS= read -r value
    if [ -z "$value" ]; then
      value="$default"
    fi
    case "$value" in
      y|Y|yes|YES|true|TRUE) printf "true"; return 0 ;;
      n|N|no|NO|false|FALSE) printf "false"; return 0 ;;
      *) log "Please enter y or n." ;;
    esac
  done
}

prompt_select() {
  prompt="$1"
  default="$2"
  shift 2
  options="$*"
  log "$prompt" >&2
  count=0
  for opt in $options; do
    count=$((count + 1))
    printf "  %s) %s\n" "$count" "$opt" >&2
  done
  while true; do
    if [ -n "$default" ]; then
      printf "Select (1-%s) [default: %s]: " "$count" "$default" >&2
    else
      printf "Select (1-%s): " "$count" >&2
    fi
    IFS= read -r choice
    if [ -z "$choice" ]; then
      if [ -n "$default" ]; then
        printf "%s" "$default"
        return 0
      fi
      log "Please enter a number." >&2
      continue
    fi
    case "$choice" in
      *[!0-9]*) log "Please enter a number." >&2 ;;
      *)
        idx=1
        for opt in $options; do
          if [ "$idx" -eq "$choice" ]; then
            printf "%s" "$opt"
            return 0
          fi
          idx=$((idx + 1))
        done
        log "Invalid selection." >&2
        ;;
    esac
  done
}

prompt_select_or_custom() {
  prompt="$1"
  default="$2"
  shift 2
  options="$*"
  in_list="false"
  for opt in $options; do
    if [ "$opt" = "$default" ]; then
      in_list="true"
      break
    fi
  done
  select_default="$default"
  if [ "$in_list" != "true" ]; then
    select_default="custom"
  fi
  choice=$(prompt_select "$prompt" "$select_default" $options custom)
  if [ "$choice" = "custom" ]; then
    prompt_default "Custom value" "$default"
  else
    printf "%s" "$choice"
  fi
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_port() {
  port="$1"
  if ! is_uint "$port"; then
    return 1
  fi
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

is_username() {
  case "$1" in
    ''|*[!a-z0-9_]* ) return 1 ;;
    *) return 0 ;;
  esac
}

is_no_space() {
  case "$1" in
    *[[:space:]]*) return 1 ;;
    '') return 1 ;;
    *) return 0 ;;
  esac
}

prompt_typed() {
  label="$1"
  default="$2"
  type="$3"
  while true; do
    value=$(prompt_default "$label" "$default")
    case "$type" in
      uint)
        if is_uint "$value"; then
          printf "%s" "$value"
          return 0
        fi
        log "Please enter a valid number." >&2
        ;;
      port)
        if is_port "$value"; then
          printf "%s" "$value"
          return 0
        fi
        log "Please enter a valid port (1-65535)." >&2
        ;;
      username)
        if is_username "$value"; then
          printf "%s" "$value"
          return 0
        fi
        log "Use lowercase letters, numbers, and '_' only." >&2
        ;;
      nospace)
        if is_no_space "$value"; then
          printf "%s" "$value"
          return 0
        fi
        log "Spaces are not allowed." >&2
        ;;
      *)
        printf "%s" "$value"
        return 0
        ;;
    esac
  done
}

sanitize_name() {
  LC_ALL=C printf "%s" "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

load_defaults() {
  for candidate in $DEFAULT_CONF_CANDIDATES; do
    [ -n "$candidate" ] || continue
    if [ -f "$candidate" ]; then
      # shellcheck disable=SC1090
      . "$candidate"
      log "Loaded defaults from: $candidate"
      return 0
    fi
  done
  return 0
}

load_defaults

# Basic defaults
ARCH_DEFAULT="${ARCH:-$(uname -m | sed 's/aarch64/arm64/; s/armv.*/armhf/; s/x86_64/amd64/; s/i.86/i386/')}"
DISTRIB_DEFAULT="${DISTRIB:-ubuntu}"
SUITE_DEFAULT="${SUITE:-noble}"
DISK_SIZE_DEFAULT="${DISK_SIZE:-131072}"
FS_TYPE_DEFAULT="${FS_TYPE:-ext4}"
TARGET_TYPE_DEFAULT="${TARGET_TYPE:-file}"
DESKTOP_DEFAULT="${DESKTOP:-lxde}"
GRAPHICS_DEFAULT="${GRAPHICS:-vnc}"
USER_NAME_DEFAULT="${USER_NAME:-user}"
USER_PASSWORD_DEFAULT="${USER_PASSWORD:-changeme}"
SSH_PORT_DEFAULT="${SSH_PORT:-22}"
VNC_DISPLAY_DEFAULT="${VNC_DISPLAY:-0}"
VNC_WIDTH_DEFAULT="${VNC_WIDTH:-1920}"
VNC_HEIGHT_DEFAULT="${VNC_HEIGHT:-1080}"
VNC_DEPTH_DEFAULT="${VNC_DEPTH:-16}"
VNC_DPI_DEFAULT="${VNC_DPI:-75}"
X11_HOST_DEFAULT="${X11_HOST:-127.0.0.1}"
X11_DISPLAY_DEFAULT="${X11_DISPLAY:-0}"
X11_SDL_DEFAULT="${X11_SDL:-false}"
X11_SDL_DELAY_DEFAULT="${X11_SDL_DELAY:-15}"
LOCALE_DEFAULT="${LOCALE:-en_US.UTF-8}"
PULSE_HOST_DEFAULT="${PULSE_HOST:-127.0.0.1}"
PULSE_PORT_DEFAULT="${PULSE_PORT:-4712}"
SOURCE_PATH_DEFAULT="${SOURCE_PATH:-http://ports.ubuntu.com/}"
MOUNTS_DEFAULT="${MOUNTS:-/:/mnt/android}"
INIT_DEFAULT="${INIT:-run-parts}"
INIT_ASYNC_DEFAULT="${INIT_ASYNC:-true}"
INIT_LEVEL_DEFAULT="${INIT_LEVEL:-3}"
INIT_PATH_DEFAULT="${INIT_PATH:-/etc/rc.local}"
INIT_USER_DEFAULT="${INIT_USER:-root}"

mkdir -p "$PROFILE_DIR"

profile_name="${1:-}"
if [ -z "$profile_name" ]; then
  profile_name=$(prompt_default "Profile name" "my_profile")
fi
profile_name=$(sanitize_name "$profile_name")
profile_path="$PROFILE_DIR/${profile_name}.conf"

external_storage="${EXTERNAL_STORAGE:-/sdcard}"
TARGET_PATH_DEFAULT="${TARGET_PATH:-${external_storage}/${profile_name}.img}"

log "Creating profile: $profile_path"

# Basic config prompts
DISTRO_OPTIONS="ubuntu debian kali arch artix alpine fedora void"
DESKTOP_OPTIONS="xfce lxde mate xterm"
GRAPHICS_OPTIONS="vnc x11"
ARCH_OPTIONS="arm64 armhf amd64 i386"
FS_TYPE_OPTIONS="ext4 f2fs xfs"
TARGET_TYPE_OPTIONS="file dir"
DISTRIB=$(prompt_select "Distro" "" $DISTRO_OPTIONS)
case "$DISTRIB" in
  ubuntu)
    SUITE=$(prompt_select "Ubuntu suite" "$SUITE_DEFAULT" trusty xenial bionic focal jammy noble oracular plucky)
    ;;
  debian)
    SUITE=$(prompt_select "Debian rootfs" "" debian debian_bullseye debian_bookworm debian_trixie)
    ;;
  kali)
    SUITE=$(prompt_select "Kali rootfs" "$SUITE_DEFAULT" full minimal nano)
    ;;
  fedora)
    SUITE=$(prompt_select "Fedora rootfs" "$SUITE_DEFAULT" v4.24.0 v4.23.0 v4.17.3 v4.15.0)
    ;;
  chimera)
    SUITE=$(prompt_select "Chimera rootfs" "$SUITE_DEFAULT" full bootstrap)
    ;;
  adelie)
    SUITE=$(prompt_select "Adelie rootfs" "$SUITE_DEFAULT" full mini)
    ;;
  arch|artix|alpine|void)
    SUITE=""
    ;;
  *)
    SUITE=$(prompt_default "Suite" "$SUITE_DEFAULT")
    ;;
esac

TARGET_PATH=$(prompt_typed "Image path" "$TARGET_PATH_DEFAULT" nospace)
DISK_SIZE=$(prompt_typed "Image size (MB)" "$DISK_SIZE_DEFAULT" uint)
USER_NAME=$(prompt_typed "User name" "$USER_NAME_DEFAULT" username)
USER_PASSWORD="$USER_PASSWORD_DEFAULT"
log "User password is set to default: $USER_PASSWORD_DEFAULT"
log "Please change it after install."

GUI_ENABLE=$(prompt_yes_no "Enable GUI" "true")
if [ "$GUI_ENABLE" = "true" ]; then
  DESKTOP=$(prompt_select_or_custom "Desktop" "$DESKTOP_DEFAULT" $DESKTOP_OPTIONS)
  GRAPHICS=$(prompt_select_or_custom "Graphics" "$GRAPHICS_DEFAULT" $GRAPHICS_OPTIONS)
else
  DESKTOP="none"
  GRAPHICS="none"
fi

SSH_ENABLE=$(prompt_yes_no "Enable SSH" "true")
if [ "$SSH_ENABLE" = "true" ]; then
  SSH_PORT=$(prompt_typed "SSH port" "$SSH_PORT_DEFAULT" port)
  SSH_ARGS="${SSH_ARGS:-}"
else
  SSH_PORT="$SSH_PORT_DEFAULT"
  SSH_ARGS="${SSH_ARGS:-}"
fi

if [ "$GRAPHICS" = "vnc" ]; then
  VNC_ENABLE="true"
  VNC_DISPLAY=$(prompt_typed "VNC display" "$VNC_DISPLAY_DEFAULT" uint)
  VNC_WIDTH=$(prompt_typed "VNC width" "$VNC_WIDTH_DEFAULT" uint)
  VNC_HEIGHT=$(prompt_typed "VNC height" "$VNC_HEIGHT_DEFAULT" uint)
  VNC_DEPTH=$(prompt_typed "VNC depth" "$VNC_DEPTH_DEFAULT" uint)
  VNC_DPI=$(prompt_typed "VNC DPI" "$VNC_DPI_DEFAULT" uint)
  VNC_ARGS="${VNC_ARGS:-}"
else
  VNC_ENABLE="false"
  VNC_DISPLAY="$VNC_DISPLAY_DEFAULT"
  VNC_WIDTH="$VNC_WIDTH_DEFAULT"
  VNC_HEIGHT="$VNC_HEIGHT_DEFAULT"
  VNC_DEPTH="$VNC_DEPTH_DEFAULT"
  VNC_DPI="$VNC_DPI_DEFAULT"
  VNC_ARGS="${VNC_ARGS:-}"
fi

if [ "$GRAPHICS" = "x11" ]; then
  X11_HOST=$(prompt_default "X11 host" "$X11_HOST_DEFAULT")
  X11_DISPLAY=$(prompt_typed "X11 display" "$X11_DISPLAY_DEFAULT" uint)
  X11_SDL=$(prompt_yes_no "Enable X11 SDL" "$X11_SDL_DEFAULT")
  X11_SDL_DELAY=$(prompt_typed "X11 SDL delay" "$X11_SDL_DELAY_DEFAULT" uint)
else
  X11_HOST="$X11_HOST_DEFAULT"
  X11_DISPLAY="$X11_DISPLAY_DEFAULT"
  X11_SDL="$X11_SDL_DEFAULT"
  X11_SDL_DELAY="$X11_SDL_DELAY_DEFAULT"
fi

PULSE_ENABLE=$(prompt_yes_no "Enable PulseAudio" "true")
if [ "$PULSE_ENABLE" = "true" ]; then
  PULSE_HOST=$(prompt_default "Pulse host" "$PULSE_HOST_DEFAULT")
  PULSE_PORT=$(prompt_typed "Pulse port" "$PULSE_PORT_DEFAULT" port)
else
  PULSE_HOST="$PULSE_HOST_DEFAULT"
  PULSE_PORT="$PULSE_PORT_DEFAULT"
fi

ADVANCED_ENABLE=$(prompt_yes_no "Configure advanced options" "false")
if [ "$ADVANCED_ENABLE" = "true" ]; then
  ARCH=$(prompt_select_or_custom "Arch" "$ARCH_DEFAULT" $ARCH_OPTIONS)
  FS_TYPE=$(prompt_select_or_custom "Filesystem" "$FS_TYPE_DEFAULT" $FS_TYPE_OPTIONS)
  TARGET_TYPE=$(prompt_select_or_custom "Target type" "$TARGET_TYPE_DEFAULT" $TARGET_TYPE_OPTIONS)
  LOCALE=$(prompt_default "Locale" "$LOCALE_DEFAULT")
  SOURCE_PATH=$(prompt_default "Ubuntu mirror" "$SOURCE_PATH_DEFAULT")
  MOUNTS=$(prompt_default "Mounts" "$MOUNTS_DEFAULT")
  INIT_DEFAULT=$(prompt_default "Init" "$INIT_DEFAULT")
  INIT_ASYNC_DEFAULT=$(prompt_default "Init async" "$INIT_ASYNC_DEFAULT")
  INIT_LEVEL_DEFAULT=$(prompt_default "Init level" "$INIT_LEVEL_DEFAULT")
  INIT_PATH_DEFAULT=$(prompt_default "Init path" "$INIT_PATH_DEFAULT")
  INIT_USER_DEFAULT=$(prompt_default "Init user" "$INIT_USER_DEFAULT")
else
  ARCH="$ARCH_DEFAULT"
  FS_TYPE="$FS_TYPE_DEFAULT"
  TARGET_TYPE="$TARGET_TYPE_DEFAULT"
  LOCALE="$LOCALE_DEFAULT"
  SOURCE_PATH="$SOURCE_PATH_DEFAULT"
  MOUNTS="$MOUNTS_DEFAULT"
fi

INCLUDE="bootstrap desktop graphics init"
[ "$SSH_ENABLE" = "true" ] && INCLUDE="$INCLUDE extra/ssh"
[ "$PULSE_ENABLE" = "true" ] && INCLUDE="$INCLUDE extra/pulse"
[ "$GRAPHICS" = "vnc" ] && INCLUDE="$INCLUDE graphics/vnc"
[ "$GRAPHICS" = "x11" ] && INCLUDE="$INCLUDE graphics/x11"

cat > "$profile_path" <<EOF
ARCH="$ARCH"
DESKTOP="$DESKTOP"
DISK_SIZE="$DISK_SIZE"
DISTRIB="$DISTRIB"
DNS=""
FS_TYPE="$FS_TYPE"
GRAPHICS="$GRAPHICS"
INCLUDE="$INCLUDE"
INIT="$INIT_DEFAULT"
INIT_ASYNC="$INIT_ASYNC_DEFAULT"
INIT_LEVEL="$INIT_LEVEL_DEFAULT"
INIT_PATH="$INIT_PATH_DEFAULT"
INIT_USER="$INIT_USER_DEFAULT"
LOCALE="$LOCALE"
MOUNTS="$MOUNTS"
NET_TRIGGER=""
POWER_TRIGGER=""
PULSE_HOST="$PULSE_HOST"
PULSE_PORT="$PULSE_PORT"
SOURCE_PATH="$SOURCE_PATH"
SSH_ARGS="$SSH_ARGS"
SSH_PORT="$SSH_PORT"
SUITE="$SUITE"
TARGET_PATH="$TARGET_PATH"
TARGET_TYPE="$TARGET_TYPE"
USER_NAME="$USER_NAME"
USER_PASSWORD="$USER_PASSWORD"
VNC_ARGS="$VNC_ARGS"
VNC_DEPTH="$VNC_DEPTH"
VNC_DISPLAY="$VNC_DISPLAY"
VNC_DPI="$VNC_DPI"
VNC_HEIGHT="$VNC_HEIGHT"
VNC_WIDTH="$VNC_WIDTH"
X11_DISPLAY="$X11_DISPLAY"
X11_HOST="$X11_HOST"
X11_SDL="$X11_SDL"
X11_SDL_DELAY="$X11_SDL_DELAY"
EOF

log "Profile saved: $profile_path"
