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
    # Signal the caller that packages changed, so it runs the (expensive) full
    # Termux SELinux relabel once. Steady-state starts skip it.
    : > "$PREFIX/tmp/.chd_relabel_needed" 2>/dev/null || true
fi

# Prefer the AAudio sink on Android 8+ (modern, low-latency). Idempotent; only
# rewrites if the old OpenSL ES sink is configured. Harmless if already aaudio.
if [ -f "$PREFIX/etc/pulse/default.pa" ] && grep -q 'module-sles-sink' "$PREFIX/etc/pulse/default.pa" 2>/dev/null; then
    echo "Patching pulse config: module-sles-sink -> module-aaudio-sink"
    sed -i 's/module-sles-sink/module-aaudio-sink/g' "$PREFIX/etc/pulse/default.pa"
fi

# CRITICAL (root cause of the "CANNOT LINK EXECUTABLE pulseaudio: cannot locate
# symbol eglDestroySyncKHR referenced by /system/lib64/libgui.so" crash):
# pulseaudio NEEDs libOpenSLES.so (system), which drags in the whole system
# audio chain libaudioclient -> libgui -> libEGL. With LD_LIBRARY_PATH=$PREFIX/lib
# first, system libgui binds against Termux/Mesa libEGL (installed for the GPU
# stack), which lacks eglDestroySyncKHR -> the binary fails to link and no sink
# (and no TCP port) ever comes up. Verified on-device: prepending /system/lib64
# so the system audio chain resolves consistently to system libs (system libEGL
# DOES export eglDestroySyncKHR) makes pulseaudio start and bind the port.
# pulseaudio's own libs (libpulsecore/common/pulse) aren't in /system, so they
# still load from $PREFIX/lib - only the system chain is affected.
_PA_LDPATH="/system/lib64:/system/lib:${LD_LIBRARY_PATH:-$PREFIX/lib}"

# Start the pulse daemon with TCP native protocol (using specified port or default 4713)
LD_LIBRARY_PATH="$_PA_LDPATH" pulseaudio --start --load="module-native-protocol-tcp auth-anonymous=1 port=${PULSE_PORT:-4713}" --exit-idle-time=-1 > "$TMPDIR/pulse_output.log" 2>&1

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
