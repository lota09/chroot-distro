#!/bin/sh
# chd_startup.sh - Chroot-Distro Service Orchestrator (Guest-side)
# This script is called by chroot-distro to initialize the environment and start services.

set -e

# 1. Environment Synchronization
# Ensure standard paths are available
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Sync to global profile for future logins
# These variables are passed from the host via 'env'
printf '#!/bin/sh\nexport PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH\nexport PULSE_SERVER="%s"\nexport DISPLAY="%s"\n' "$PULSE_SERVER" "$DISPLAY" > /etc/profile.d/chd_env.sh
chmod 644 /etc/profile.d/chd_env.sh

# 2. Start SSH (if requested)
if [ "$HAS_SSH" = "true" ]; then
    mkdir -p /run/sshd /var/run/sshd
    if [ -x /usr/sbin/sshd ]; then
        # SSH_ARGS is passed via env
        /usr/sbin/sshd $SSH_ARGS || echo "SSH failed to start"
    fi
fi

# 3. Graphical Session Initialization
if [ "$HAS_X11" = "true" ]; then
    # Look up user home
    [ -z "$USER_NAME" ] && USER_NAME="root"
    USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6 2>/dev/null || echo "")
    
    # Fallback to standard if getent fails or returns empty
    if [ -z "$USER_HOME" ]; then
        if [ "$USER_NAME" = "root" ]; then USER_HOME="/root"; else USER_HOME="/home/$USER_NAME"; fi
    fi

    # Ensure USER_HOME is not empty before mkdir to prevent [mkdir ""] error
    if [ -n "$USER_HOME" ]; then
        [ -d "$USER_HOME" ] || mkdir -p "$USER_HOME"
    else
        echo "[error] Could not determine USER_HOME for $USER_NAME" >&2
        exit 1
    fi
    
    XSTARTUP="$USER_HOME/.xstartup_native"
    
    # Generate the Native X11 startup script for this session
    # We use a heredoc to create it inside the guest
    cat <<XEOF > "$XSTARTUP"
#!/bin/sh
# This script starts the desktop environment with hardware acceleration
export PULSE_SERVER="$PULSE_SERVER"
export DISPLAY="$DISPLAY"
# HW_VARS contains export statements for MESA/ZINK/TURNIP
$HW_VARS
# DESKTOP_CMD starts the DE (e.g. startxfce4)
$DESKTOP_CMD
XEOF
    
    chmod +x "$XSTARTUP"
    # Ensure correct ownership
    G_GROUP=$(id -gn "$USER_NAME" 2>/dev/null || echo "$USER_NAME")
    chown -R "$USER_NAME":"$G_GROUP" "$USER_HOME" 2>/dev/null || true
    chown "$USER_NAME":"$G_GROUP" "$XSTARTUP"
    
    # Optional: x11vnc Mirroring if VNC requested
    # We always mirror :0 on the host
    if [ "$HAS_VNC" = "true" ]; then
        # Wait for the display to be ready
        i=0
        while [ ! -S /tmp/.X11-unix/X0 ] && [ "$i" -lt 10 ]; do
             sleep 1
             i=$((i + 1))
        done
        # Start mirroring session in background
        su - "$USER_NAME" -c "nohup x11vnc -display :0 -bg -nopw -listen 0.0.0.0 -xkb -ncache 10 -shared -forever > \"\$HOME/x11vnc_mirror.log\" 2>&1 &" \
            || echo "[warn] x11vnc failed to start (non-fatal)"
    fi
    
    # Start the Native X11 session in background
    su - "$USER_NAME" -c "nohup \$HOME/.xstartup_native > \"\$HOME/x11_native.log\" 2>&1 &" \
        || echo "[warn] .xstartup_native failed to start (non-fatal)"
fi

exit 0
