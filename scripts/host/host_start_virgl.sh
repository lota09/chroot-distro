#!/system/bin/sh

# Define log path
LOGFILE="$TMPDIR/chd_host_virgl.log"
# Clear log for new run
> "$LOGFILE"

# Check if already running
if pgrep -f "virgl_test_server" > /dev/null; then
    exit 0
fi

# Auto-install if missing
if ! command -v virgl_test_server >/dev/null 2>&1; then
    echo "Required Virgl packages not found. Attempting auto-installation from Termux mirrors..."
    # tur-repo is required for mesa-zink and virglrenderer-mesa-zink
    pkg update -y && pkg install -y x11-repo tur-repo && pkg update -y && pkg install -y mesa-zink virglrenderer-mesa-zink vulkan-loader-android virglrenderer-android
    if [ $? -ne 0 ]; then
        echo "Auto-installation failed! Please check your internet connection."
        exit 1
    fi
    echo "Installation complete."
fi

# Start Hardware Acceleration (ZINK/Vulkan) as per HardwareAcceleration.md
MESA_NO_ERROR=1 MESA_GL_VERSION_OVERRIDE=4.3COMPAT MESA_GLES_VERSION_OVERRIDE=3.2 GALLIUM_DRIVER=zink ZINK_DESCRIPTORS=lazy virgl_test_server --use-egl-surfaceless --use-gles > "$TMPDIR/virgl_output.log" 2>&1 &

sleep 1
if pgrep -f "virgl_test_server" > /dev/null; then
    exit 0
else
    echo "Failed to start virgl_test_server!"
    if [ -f "$TMPDIR/virgl_output.log" ]; then
        echo "--- virgl_output.log content ---"
        cat "$TMPDIR/virgl_output.log"
    fi
    exit 1
fi
