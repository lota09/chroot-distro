#!/bin/sh
# chd_startup.sh - Chroot-Distro Service Orchestrator (Guest-side)
# This script is called by chroot-distro to initialize the environment and start services.

set -e

# Provide sensible defaults when the host doesn't pass these env vars
[ -z "$DISPLAY" ] && DISPLAY=":0"
[ -z "$PULSE_SERVER" ] && PULSE_SERVER="tcp:127.0.0.1:4713"

# 1. Environment Synchronization
# Ensure standard paths are available
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Sync to global profile for future logins
# These variables are passed from the host via 'env'
printf '#!/bin/sh\nexport PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH\nexport PULSE_SERVER="%s"\nexport DISPLAY="%s"\n%s\n' \
    "$PULSE_SERVER" "$DISPLAY" "${HW_VARS:-}" > /etc/profile.d/chd_env.sh
chmod 644 /etc/profile.d/chd_env.sh

# 2. Start SSH (if requested)
if [ "$HAS_SSH" = "true" ]; then
    mkdir -p /run/sshd /var/run/sshd
    if [ -x /usr/sbin/sshd ]; then
        /usr/sbin/sshd $SSH_ARGS || echo "SSH failed to start"
    fi
fi

# 3. Graphical Session Initialization

_get_user_home() {
    local uname="$1"
    local home
    home=$(getent passwd "$uname" | cut -d: -f6 2>/dev/null || echo "")
    if [ -z "$home" ]; then
        if [ "$uname" = "root" ]; then home="/root"; else home="/home/$uname"; fi
    fi
    printf "%s" "$home"
}

if [ "$HAS_VNC" = "true" ] && [ "$HAS_X11" = "false" ]; then
    # Standalone TigerVNC mode — no Termux:X11 required.
    # The host has already bound the virgl socket before calling this script.
    [ -z "$USER_NAME" ] && USER_NAME="root"
    VNC_DISP="${VNC_DISPLAY:-1}"
    VNC_GEOM="${VNC_WIDTH:-1280}x${VNC_HEIGHT:-720}"

    USER_HOME=$(_get_user_home "$USER_NAME")
    if [ -n "$USER_HOME" ]; then
        [ -d "$USER_HOME" ] || mkdir -p "$USER_HOME"
    else
        echo "[error] Could not determine USER_HOME for $USER_NAME" >&2
        exit 1
    fi

    mkdir -p "$USER_HOME/.vnc"

    # Write xstartup with hardware acceleration and audio environment.
    # DESKTOP_CMD already starts with 'exec' (e.g. 'exec dbus-launch --exit-with-session startlxde')
    # so we call it directly without an extra 'exec' prefix.
    XSTARTUP="$USER_HOME/.vnc/xstartup"
    cat <<VNCEOF > "$XSTARTUP"
#!/bin/sh
export PULSE_SERVER="$PULSE_SERVER"
export DISPLAY=":$VNC_DISP"
${HW_VARS:-}
$DESKTOP_CMD
VNCEOF
    chmod +x "$XSTARTUP"

    # Create VNC password file if missing (init script sets it; this is a safety net)
    if [ ! -f "$USER_HOME/.vnc/passwd" ]; then
        VNC_PASS="${VNC_PASSWORD:-changeme}"
        printf "%s" "$VNC_PASS" | vncpasswd -f > "$USER_HOME/.vnc/passwd"
        chmod 600 "$USER_HOME/.vnc/passwd"
    fi

    G_GROUP=$(id -gn "$USER_NAME" 2>/dev/null || echo "$USER_NAME")
    chown -R "$USER_NAME":"$G_GROUP" "$USER_HOME/.vnc"

    # Kill any stale VNC server on this display, then start fresh
    su - "$USER_NAME" -c "vncserver -kill :$VNC_DISP 2>/dev/null; true"
    su - "$USER_NAME" -c "nohup vncserver :$VNC_DISP -geometry $VNC_GEOM -depth 24 -localhost no > \"$USER_HOME/vnc.log\" 2>&1 &"

elif [ "$HAS_X11" = "true" ]; then
    # Termux:X11 mode (standalone or with x11vnc mirror when HAS_VNC=true too)
    [ -z "$USER_NAME" ] && USER_NAME="root"
    USER_HOME=$(_get_user_home "$USER_NAME")

    if [ -n "$USER_HOME" ]; then
        [ -d "$USER_HOME" ] || mkdir -p "$USER_HOME"
    else
        echo "[error] Could not determine USER_HOME for $USER_NAME" >&2
        exit 1
    fi

    XSTARTUP="$USER_HOME/.xstartup_native"

        # Generate the Native X11 startup script.
        cat <<XEOF > "$XSTARTUP"
#!/bin/sh
export PULSE_SERVER="$PULSE_SERVER"
export DISPLAY="$DISPLAY"
USER_HOME="$USER_HOME"
export XAUTHORITY="$USER_HOME/.Xauthority"
export XFWM4_DISABLE_COMPOSITOR=1
# Resolve DESKTOP_CMD at runtime and strip a leading 'exec ' if present
DESKTOP_CMD="\${DESKTOP_CMD:-startlxde}"
case "$DESKTOP_CMD" in
    exec\ *) DESKTOP_CMD="${DESKTOP_CMD#exec }" ;;
esac
exec dbus-launch --exit-with-session $DESKTOP_CMD
XEOF

    chmod +x "$XSTARTUP"
    G_GROUP=$(id -gn "$USER_NAME" 2>/dev/null || echo "$USER_NAME")
    chown -R "$USER_NAME":"$G_GROUP" "$USER_HOME" 2>/dev/null || true
    chown "$USER_NAME":"$G_GROUP" "$XSTARTUP"

    # virgl socket should already be present (host_start_virgl.sh waits for it).
    # Quick log only — no blocking wait needed here.
    [ -S /tmp/.virgl_test ] && \
        echo "[info] virgl socket present in guest" || \
        echo "[warn] virgl socket not present — GPU accel may be unavailable"

    # Optional: x11vnc mirror if VNC also requested (X11+VNC mirror mode)
    if [ "$HAS_VNC" = "true" ]; then
        i=0
        while [ ! -S /tmp/.X11-unix/X0 ] && [ "$i" -lt 10 ]; do
            sleep 1
            i=$((i + 1))
        done
        su - "$USER_NAME" -c "mkdir -p \$HOME/.vnc && \
            [ -f \$HOME/.vnc/passwd ] || x11vnc -storepasswd changeme \$HOME/.vnc/passwd && \
            chmod 600 \$HOME/.vnc/passwd; \
            nohup x11vnc -display :0 -noshm -noxdamage -nowf -nowcr -ncache 10 -bg \
            -passwdfile \$HOME/.vnc/passwd -listen 0.0.0.0 -xkb -shared -forever \
            > \"\$HOME/x11vnc_mirror.log\" 2>&1 &" \
            || echo "[warn] x11vnc failed to start (non-fatal)"
    fi

    # Start the Native X11 session in background
    su - "$USER_NAME" -c "nohup \$HOME/.xstartup_native > \"\$HOME/x11_native.log\" 2>&1 &" \
        || echo "[warn] .xstartup_native failed to start (non-fatal)"
fi

exit 0
