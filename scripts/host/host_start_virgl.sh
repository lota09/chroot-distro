#!/system/bin/sh
# host_start_virgl.sh - Start virgl_test_server (Zink/GPU mode) from Termux context
# Called via host_run_in_termux, so we already run as Termux user with correct TMPDIR.

TERMUX_PREFIX="/data/data/com.termux/files/usr"
TERMUX_TMP="$TERMUX_PREFIX/tmp"
VIRGL_SOCKET="$TERMUX_TMP/.virgl_test"
LOGFILE="$TERMUX_TMP/chd_host_virgl.log"
> "$LOGFILE"

# ─── 1. Already running? ──────────────────────────────────────────────────────
if [ -S "$VIRGL_SOCKET" ] && pgrep -x "virgl_test_server" > /dev/null 2>&1; then
    echo "[virgl] Already running with socket present. OK." >> "$LOGFILE"
    exit 0
fi

# Kill any stale process, remove stale socket
pkill -x "virgl_test_server" 2>/dev/null || true
rm -f "$VIRGL_SOCKET" 2>/dev/null || true
echo "[virgl] Previous instance cleaned up." >> "$LOGFILE"

# ─── 2. Auto-install required packages if missing ────────────────────────��───
# Package check: virgl_test_server must come from virglrenderer-mesa-zink (Zink build)
# NOT virglrenderer-android (software renderer build).
if ! command -v virgl_test_server >/dev/null 2>&1; then
    echo "[virgl] virgl_test_server not found. Installing Termux GPU packages..." >> "$LOGFILE"

    # Add repos first (idempotent)
    pkg install -y tur-repo </dev/null >> "$LOGFILE" 2>&1 || true
    pkg install -y x11-repo </dev/null >> "$LOGFILE" 2>&1 || true
    pkg update -y </dev/null >> "$LOGFILE" 2>&1 || true

    # Remove generic Vulkan loader that conflicts with Android-specific one
    if dpkg -l 2>/dev/null | grep -q "^ii.*vulkan-loader-generic"; then
        echo "[virgl] Removing conflicting vulkan-loader-generic..." >> "$LOGFILE"
        pkg uninstall -y vulkan-loader-generic </dev/null >> "$LOGFILE" 2>&1 || true
    fi

    # Core virgl + Zink stack
    pkg install -y \
        mesa-zink \
        virglrenderer-mesa-zink \
        virglrenderer-android \
        vulkan-loader-android \
        </dev/null >> "$LOGFILE" 2>&1 || true

    # Turnip (Adreno open-source Vulkan driver) — -dri3 variant required for kgsl
    apt install -y mesa-vulkan-icd-freedreno-dri3 </dev/null >> "$LOGFILE" 2>&1 || \
        apt install -y mesa-vulkan-icd-freedreno </dev/null >> "$LOGFILE" 2>&1 || true

    # Vulkan ICD loader — registers Turnip ICD so Mesa can find it
    apt install -y vulkan-icd </dev/null >> "$LOGFILE" 2>&1 || true

    # Fix any broken dep state
    dpkg --configure -a >> "$LOGFILE" 2>&1 || true
    apt -f install -y </dev/null >> "$LOGFILE" 2>&1 || true

    echo "[virgl] Package installation complete." >> "$LOGFILE"
fi

if ! command -v virgl_test_server >/dev/null 2>&1; then
    echo "[virgl] ERROR: virgl_test_server still not available after install." >> "$LOGFILE"
    echo "[virgl] Check Termux repo connectivity and tur-repo/x11-repo configuration." >> "$LOGFILE"
    exit 1
fi

# ─── 3. Start virgl_test_server in Zink/GPU mode ─────────────────────────────
# --use-egl-surfaceless : headless EGL (no display needed, uses GPU directly)
# --use-gles            : GLES backend
# GALLIUM_DRIVER=zink   : OpenGL → Vulkan(Zink) → Turnip → Adreno
# Socket is created at $TMPDIR/.virgl_test (TMPDIR set by host_run_in_termux)
echo "[virgl] Starting virgl_test_server (Zink mode)..." >> "$LOGFILE"
MESA_NO_ERROR=1 \
MESA_GL_VERSION_OVERRIDE=4.3COMPAT \
MESA_GLES_VERSION_OVERRIDE=3.2 \
GALLIUM_DRIVER=zink \
ZINK_DESCRIPTORS=lazy \
TMPDIR="$TERMUX_TMP" \
virgl_test_server --use-egl-surfaceless --use-gles \
    > "$TERMUX_TMP/virgl_output.log" 2>&1 &

VIRGL_PID=$!

i=0
# ─── 4. Wait for socket file (up to 30 s) ────────────────────────────────────
i=0
SOCKET_LINK="/tmp/.virgl_test"
mkdir -p "$TERMUX_TMP"
mkdir -p /tmp 2>/dev/null || true
echo "[virgl] Waiting for socket at $VIRGL_SOCKET (will also create symlink $SOCKET_LINK)" >> "$LOGFILE"
while [ "$i" -lt 30 ]; do
    if [ -S "$VIRGL_SOCKET" ]; then
        echo "[virgl] Socket ready after ${i}s (PID $VIRGL_PID)." >> "$LOGFILE"
        # Create a stable path guests may expect (/tmp/.virgl_test) pointing to the real socket
        if [ ! -L "$SOCKET_LINK" ]; then
            ln -sf "$VIRGL_SOCKET" "$SOCKET_LINK" 2>/dev/null || echo "[virgl] Could not create symlink $SOCKET_LINK" >> "$LOGFILE"
            echo "[virgl] Created symlink $SOCKET_LINK -> $VIRGL_SOCKET" >> "$LOGFILE"
        fi
        exit 0
    fi
    sleep 1
    # Bail early if the process already died
    if ! kill -0 "$VIRGL_PID" 2>/dev/null; then
        echo "[virgl] ERROR: virgl_test_server (PID $VIRGL_PID) exited prematurely." >> "$LOGFILE"
        break
    fi
    i=$((i + 1))
done

# ─── 5. Failure diagnostics ───────────────────────────────────────────────────
echo "[virgl] ERROR: socket not found at $VIRGL_SOCKET after ${i}s." >> "$LOGFILE"
echo "[virgl] Possible causes:" >> "$LOGFILE"
echo "  - /dev/kgsl-3d0 not accessible (check 'ls -la /dev/kgsl-3d0')" >> "$LOGFILE"
echo "  - Turnip ICD not loaded (run: VK_LOADER_DEBUG=all vulkaninfo 2>&1 | grep -iE 'turnip|error')" >> "$LOGFILE"
echo "  - mesa-vulkan-icd-freedreno-dri3 not installed" >> "$LOGFILE"
if [ -f "$TERMUX_TMP/virgl_output.log" ]; then
    echo "--- virgl_output.log ---" >> "$LOGFILE"
    cat "$TERMUX_TMP/virgl_output.log" >> "$LOGFILE"
fi
if [ -f /tmp/virgl_output.log ]; then
    echo "--- /tmp/virgl_output.log ---" >> "$LOGFILE"
    cat "/tmp/virgl_output.log" >> "$LOGFILE"
fi
exit 1
