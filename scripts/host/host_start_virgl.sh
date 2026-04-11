#!/system/bin/sh

# Use explicit Termux prefix to avoid $TMPDIR being /data/local/tmp in root context
TERMUX_PREFIX="/data/data/com.termux/files/usr"
TERMUX_TMP="$TERMUX_PREFIX/tmp"

LOGFILE="$TERMUX_TMP/chd_host_virgl.log"
# Clear log for new run
> "$LOGFILE"


# Check if already running
# 1. Check if the socket exists AND the process is alive
if [ -S "$TERMUX_TMP/.virgl_test" ] && pgrep -x "virgl_test_server" > /dev/null; then
    echo "Virgl server is already running." >> "$LOGFILE"
    exit 0
else
    # Socket is stale or missing, or process is dead. Aggressive cleanup.
    echo "Virgl server is not running or socket is stale. Cleaning up..." >> "$LOGFILE"
    rm -f "$TERMUX_TMP/.virgl_test" 2>/dev/null || true
fi

# Auto-install if missing
INSTALL_PERFORMED=0
if ! command -v virgl_test_server >/dev/null 2>&1; then
    echo "Required Virgl packages not found. Attempting auto-installation from Termux mirrors..." >> "$LOGFILE"
    # tur-repo is required for mesa-zink and virglrenderer-mesa-zink
    pkg update -y && pkg install -y x11-repo tur-repo && pkg update -y && pkg install -y mesa-zink virglrenderer-mesa-zink vulkan-loader-android virglrenderer-android
    if [ $? -ne 0 ]; then
        echo "Auto-installation failed!" >> "$LOGFILE"
        exit 1
    fi
    echo "Installation complete." >> "$LOGFILE"
    INSTALL_PERFORMED=1
fi

# Start Hardware Acceleration (ZINK/Vulkan) as per HardwareAcceleration.md
MESA_NO_ERROR=1 MESA_GL_VERSION_OVERRIDE=4.3COMPAT MESA_GLES_VERSION_OVERRIDE=3.2 GALLIUM_DRIVER=zink ZINK_DESCRIPTORS=lazy virgl_test_server --use-egl-surfaceless --use-gles > "$TERMUX_TMP/virgl_output.log" 2>&1 &

# Give it a moment to create the socket file
sleep 0.5

# Wait for the server to start

# If installation was performed, wait up to 10 seconds, otherwise 2 seconds
MAX_WAIT=2
[ "$INSTALL_PERFORMED" -eq 1 ] && MAX_WAIT=10

i=0
while [ "$i" -lt "$MAX_WAIT" ]; do
    if pgrep -x "virgl_test_server" > /dev/null; then
        exit 0
    fi
    sleep 1
    i=$((i + 1))
done

if ! pgrep -x "virgl_test_server" > /dev/null; then
    echo "ERROR: Failed to start virgl_test_server after ${MAX_WAIT}s" >> "$LOGFILE"
    if [ -f "$TERMUX_TMP/virgl_output.log" ]; then
        echo "--- virgl_output.log content ---" >> "$LOGFILE"
        cat "$TERMUX_TMP/virgl_output.log" >> "$LOGFILE"
    fi
    exit 1
fi

echo "virgl_test_server started successfully (after ${i}s)" >> "$LOGFILE"
exit 0

