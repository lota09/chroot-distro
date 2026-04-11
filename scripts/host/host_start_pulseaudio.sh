#!/system/bin/sh

LOGFILE="$TMPDIR/chd_host_pulse.log"
# Clear log for new run
> "$LOGFILE"

if ss -tlpn | grep -q ":${PULSE_PORT:-4713} "; then
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

# Start the pulse daemon with TCP native protocol (using specified port or default 4713)
pulseaudio --start --load="module-native-protocol-tcp auth-anonymous=1 port=${PULSE_PORT:-4713}" --exit-idle-time=-1 > "$TMPDIR/pulse_output.log" 2>&1

sleep 1
if ss -tlpn | grep -q ":${PULSE_PORT:-4713} "; then
    exit 0
else
    echo "Failed to start pulseaudio!"
    if [ -f "$TMPDIR/pulse_output.log" ]; then
        echo "--- pulse_output.log content ---"
        cat "$TMPDIR/pulse_output.log"
    fi
    exit 1
fi
