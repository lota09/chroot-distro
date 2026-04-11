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
    echo "ERROR: Termux:X11 socket NOT found at $SOCKET_PATH" | tee -a "$LOGFILE"
    echo "Please ensure the Termux:X11 Android app is running if you want accelerated display!" | tee -a "$LOGFILE"
    exit 1
fi
