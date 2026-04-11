#!/system/bin/sh

# X11 is not a daemon we can simply fork from CLI (Termux:X11 is an Android App Activity)
# Alternatively, Termux:X11 creates a socket in $TMPDIR/.X11-unix/X0

LOGFILE="$TMPDIR/chd_host_x11.log"
echo "--- Termux:X11 Host Check ---" | tee -a "$LOGFILE"
date | tee -a "$LOGFILE"

SOCKET_PATH="$TMPDIR/.X11-unix/X${X11_DISPLAY:-0}"

if [ -S "$SOCKET_PATH" ]; then
    echo "Termux:X11 socket found at $SOCKET_PATH" | tee -a "$LOGFILE"
    exit 0
else
    echo "Termux:X11 socket NOT found at $SOCKET_PATH, attempting to start Termux:X11..." | tee -a "$LOGFILE"
    # Kill any potentially hanging instances first
    pkill -9 -f "termux.x11" 2>/dev/null
    
    termux-x11 :${X11_DISPLAY:-0} -ac >/dev/null 2>&1 &
    
    # Wait for the socket to appear
    for i in 1 2 3 4 5; do
        if [ -S "$SOCKET_PATH" ]; then
            echo "Termux:X11 started successfully on :${X11_DISPLAY:-0}" | tee -a "$LOGFILE"
            exit 0
        fi
        sleep 1
    done
    
    echo "ERROR: Termux:X11 failed to start or socket not found after 5 seconds!" | tee -a "$LOGFILE"
    echo "Please ensure the Termux:X11 Android app is installed." | tee -a "$LOGFILE"
    exit 1
fi
