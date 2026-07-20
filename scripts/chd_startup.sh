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

# Start cron daemon if installed
if [ -x /usr/sbin/cron ]; then
    /usr/sbin/cron || echo "[warn] cron failed to start" >&2
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
    # VNC Standalone (no desktop/X11 surface) is no longer supported: without a
    # real display surface there is no reliable path to GPU acceleration on
    # Android, so this combination was removed from the installer wizard.
    # If you land here, this instance's profile.conf predates that change
    # (GRAPHICS="vnc"). Recreate the profile and choose "X11 + VNC" instead.
    echo "[error] VNC Standalone is no longer supported (no GPU-compatible display surface)." >&2
    echo "[error] Recreate this instance's profile and choose 'X11 + VNC' instead." >&2

elif [ "$HAS_X11" = "true" ]; then
    # Termux:X11 mode (standalone or with x11vnc mirror when HAS_VNC=true too)
    [ -z "$USER_NAME" ] && USER_NAME="root"
    USER_HOME=$(_get_user_home "$USER_NAME")

    echo "[info] X11 mode: USER_NAME=$USER_NAME, USER_HOME=$USER_HOME, DISPLAY=$DISPLAY" >&2

    if [ -n "$USER_HOME" ]; then
        [ -d "$USER_HOME" ] || mkdir -p "$USER_HOME"
    else
        echo "[error] Could not determine USER_HOME for $USER_NAME" >&2
        exit 1
    fi

    # Verify the virgl socket is actually usable before committing to GPU rendering.
    # host_start_virgl.sh / the host-side bind-mount step can silently fail or time
    # out (e.g. on first run while GPU packages are still installing) — HW_VARS is
    # computed on the host BEFORE that step's result is known, so it may still say
    # GALLIUM_DRIVER=virpipe even though no socket exists. Launching a desktop
    # session against a dangling virpipe target renders nothing (black screen,
    # X server cursor only). Re-check here, right before writing xstartup, and
    # fall back to software rendering if the socket isn't actually present.
    _effective_hw_vars="${HW_VARS:-}"
    if echo "${HW_VARS:-}" | grep -q "GALLIUM_DRIVER=virpipe"; then
        if [ -S /tmp/.virgl_test ]; then
            echo "[info] virgl socket present in guest — using GPU rendering (virpipe)" >&2
        else
            echo "[warn] virgl socket NOT present — falling back to software rendering (softpipe)" >&2
            echo "[warn] Check chd_startup.log / host_services.log on the host for virgl_test_server startup failures" >&2
            _effective_hw_vars="export MESA_NO_ERROR=1; export GALLIUM_DRIVER=softpipe; export LIBGL_ALWAYS_SOFTWARE=1; export MESA_GL_VERSION_OVERRIDE=4.3; export MESA_GLES_VERSION_OVERRIDE=3.2"
        fi
    fi

    XSTARTUP="$USER_HOME/.xstartup_native"

        # Generate the Native X11 startup script.
        # DESKTOP_CMD already contains 'exec dbus-launch --exit-with-session <de>'
        # so use it directly to avoid double-wrapping.
        cat <<XEOF > "$XSTARTUP"
#!/bin/sh
export PULSE_SERVER="$PULSE_SERVER"
export DISPLAY="$DISPLAY"
export XAUTHORITY="$USER_HOME/.Xauthority"
export XFWM4_DISABLE_COMPOSITOR=1
${_effective_hw_vars}
$DESKTOP_CMD
XEOF

    chmod +x "$XSTARTUP"
    G_GROUP=$(id -gn "$USER_NAME" 2>/dev/null || echo "$USER_NAME")
    chown "$USER_NAME":"$G_GROUP" "$XSTARTUP"

    # Disable xscreensaver: the system autostart includes it but it needs GL visuals
    # not available without a working virgl server.  A user-level autostart takes
    # precedence over /etc/xdg/lxsession/LXDE/autostart and omits xscreensaver.
    mkdir -p "$USER_HOME/.config/lxsession/LXDE"
    if [ ! -f "$USER_HOME/.config/lxsession/LXDE/autostart" ]; then
        printf '@lxpanel --profile LXDE\n@pcmanfm --desktop --profile LXDE\n' \
            > "$USER_HOME/.config/lxsession/LXDE/autostart"
        chown -R "$USER_NAME":"$G_GROUP" "$USER_HOME/.config" 2>/dev/null || true
    fi

    # Prevent duplicate sessions: skip if lxsession is already running.
    if pgrep -x lxsession > /dev/null 2>&1; then
        echo "[info] lxsession already running — skipping duplicate start" >&2
        exit 0
    fi

    # (virgl socket presence was already checked above, before xstartup was written)

    # Optional: x11vnc mirror if VNC also requested (X11+VNC mirror mode)
    if [ "$HAS_VNC" = "true" ]; then
        i=0
        while [ ! -S /tmp/.X11-unix/X0 ] && [ "$i" -lt 3 ]; do
            sleep 1
            i=$((i + 1))
        done
        _vnc_pass="${VNC_PASSWORD:-changeme}"
        su - "$USER_NAME" -c "mkdir -p \$HOME/.vnc && \
            x11vnc -storepasswd '${_vnc_pass}' \$HOME/.vnc/passwd && \
            chmod 600 \$HOME/.vnc/passwd; \
            nohup x11vnc -display :0 -noshm -noxdamage -nowf -nowcr -ncache 10 -bg \
            -passwdfile \$HOME/.vnc/passwd -listen 0.0.0.0 -xkb -shared -forever \
            > \"\$HOME/x11vnc_mirror.log\" 2>&1 &" \
            || echo "[warn] x11vnc failed to start (non-fatal)"
    fi

    # Start the Native X11 session in background
    echo "[info] Starting X11 session as $USER_NAME" >&2
    if su - "$USER_NAME" -c "nohup \$HOME/.xstartup_native > \"\$HOME/x11_native.log\" 2>&1 &"; then
        echo "[info] X11 session started successfully" >&2
    else
        echo "[warn] .xstartup_native failed to start (non-fatal), exit code: $?" >&2
    fi
fi

exit 0
