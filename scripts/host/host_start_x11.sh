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

if [ -S "$SOCKET_PATH" ]; then
    echo "Termux:X11 socket found at $SOCKET_PATH" >> "$LOGFILE"
    exit 0
else
    echo "Termux:X11 socket NOT found at $SOCKET_PATH, attempting to start..." >> "$LOGFILE"
    # Kill any potentially hanging instances first
    pkill -f "termux.x11" 2>/dev/null

    # Launch via am start to bring the activity to foreground (ensures socket creation)
    am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity \
        >> "$LOGFILE" 2>&1 || true

    # Also try the termux-x11 CLI method as fallback
    "$TERMUX_PREFIX/bin/termux-x11" ":${X11_DISPLAY:-0}" -ac >> "$LOGFILE" 2>&1 &

    # Wait up to 15 seconds for the socket to appear
    # Termux:X11 as an Android Activity can take several seconds to initialize
    i=0
    while [ "$i" -lt 15 ]; do
        if [ -S "$SOCKET_PATH" ]; then
            echo "Termux:X11 started successfully on :${X11_DISPLAY:-0} (after ${i}s)" >> "$LOGFILE"
            exit 0
        fi
        sleep 1
        i=$((i + 1))
    done

    echo "ERROR: Termux:X11 socket not found after 15 seconds at $SOCKET_PATH" >> "$LOGFILE"
    echo "Please open the Termux:X11 app manually." >> "$LOGFILE"
    exit 1
fi
