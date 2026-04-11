#!/system/bin/sh

# X11 is not a daemon we can simply fork from CLI (Termux:X11 is an Android App Activity)
# Termux:X11 creates a socket in its own tmp dir, NOT in /data/local/tmp

# Use explicit Termux prefix to avoid $TMPDIR being /data/local/tmp in root context
TERMUX_PREFIX="/data/data/com.termux/files/usr"
TERMUX_TMP="$TERMUX_PREFIX/tmp"

LOGFILE="$TERMUX_TMP/chd_host_x11.log"
echo "--- Termux:X11 Host Check ---" >> "$LOGFILE"
date >> "$LOGFILE"

SOCKET_PATH="$TERMUX_TMP/.X11-unix/X${X11_DISPLAY:-0}"

# 1. Check if the socket exists AND the process is alive
if [ -S "$SOCKET_PATH" ] && pkill -0 -f "termux.x11" 2>/dev/null; then
    echo "Termux:X11 is already running and responsive." >> "$LOGFILE"
    exit 0
else
    # Socket is stale or missing, or process is dead. Aggressive cleanup.
    echo "Termux:X11 is not running or socket is stale. Cleaning up..." >> "$LOGFILE"
    rm -f "$SOCKET_PATH" 2>/dev/null || true
    rm -f "$TERMUX_TMP/.X0-lock" 2>/dev/null || true
    
    echo "Checking binaries..." >> "$LOGFILE"

    
    # Auto-install if missing
    INSTALL_PERFORMED=0
    if ! command -v termux-x11 >/dev/null 2>&1; then
        echo "termux-x11 binary not found. Attempting auto-installation..." >> "$LOGFILE"
        pkg update -y && pkg install -y x11-repo && pkg install -y termux-x11-nightly
        if [ $? -ne 0 ]; then
            echo "Installation failed." >> "$LOGFILE"
            exit 1
        fi
        echo "Installation complete." >> "$LOGFILE"
        INSTALL_PERFORMED=1
    fi

    echo "Attempting to start Termux:X11..." >> "$LOGFILE"
    # Kill any potentially hanging instances first
    pkill -f "termux.x11" 2>/dev/null

    # Launch via am start to bring the activity to foreground (ensures socket creation)
    # Use -W (wait), --activity-clear-top and explicit component name for reliability
    am start --user 0 -W -n com.termux.x11/.MainActivity \
        --activity-clear-top >> "$LOGFILE" 2>&1 || true

    # Also try the termux-x11 CLI method as fallback
    "$TERMUX_PREFIX/bin/termux-x11" ":${X11_DISPLAY:-0}" -ac >> "$LOGFILE" 2>&1 &

    # Wait for the socket to appear
    # If installation was performed, wait up to 30 seconds, otherwise 15 seconds
    MAX_WAIT=15
    [ "$INSTALL_PERFORMED" -eq 1 ] && MAX_WAIT=30
    
    i=0
    while [ "$i" -lt "$MAX_WAIT" ]; do
        if [ -S "$SOCKET_PATH" ]; then
            echo "Termux:X11 started successfully on :${X11_DISPLAY:-0} (after ${i}s)" >> "$LOGFILE"
            exit 0
        fi
        sleep 1
        i=$((i + 1))
    done

    echo "ERROR: Termux:X11 socket not found at $SOCKET_PATH after ${MAX_WAIT}s" >> "$LOGFILE"
    echo "Check if Termux:X11 app is running and has necessary permissions." >> "$LOGFILE"
    exit 1
fi
