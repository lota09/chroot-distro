#!/system/bin/sh

LOGFILE="$TMPDIR/chd_host_pulse.log"
# Clear log for new run
> "$LOGFILE"

if pgrep -f "pulseaudio" > /dev/null; then
    exit 0
fi

# Auto-install if missing
if ! command -v pulseaudio >/dev/null 2>&1; then
    echo "pulseaudio not found. Attempting auto-installation (pkg install) in Termux..."
    pkg update -y && pkg install -y pulseaudio
    if [ $? -ne 0 ]; then
        echo "Auto-installation failed! Please check your internet connection."
        exit 1
    fi
    echo "Installation complete."
fi

# Start the pulse daemon with TCP native protocol listening on localhost
pulseaudio --start --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" --exit-idle-time=-1 > "$TMPDIR/pulse_output.log" 2>&1

sleep 1
if pgrep -f "pulseaudio" > /dev/null; then
    exit 0
else
    echo "Failed to start pulseaudio!"
    if [ -f "$TMPDIR/pulse_output.log" ]; then
        echo "--- pulse_output.log content ---"
        cat "$TMPDIR/pulse_output.log"
    fi
    exit 1
fi
