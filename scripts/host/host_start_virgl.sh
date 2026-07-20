#!/system/bin/sh
# host_start_virgl.sh - Start virgl_test_server (Zink/GPU mode) from Termux context.
# Called via host_run_in_termux, so we already run as Termux user with Termux env.
# The socket is created in Termux's own tmp (the only writable path for this UID
# on /data/local/).  The main chroot-distro script then bind-mounts Termux tmp
# into the chroot and creates /tmp/.virgl_test → /tmp/host_virgl/.virgl_test.

TERMUX_PREFIX="/data/data/com.termux/files/usr"
TERMUX_TMP="$TERMUX_PREFIX/tmp"
LOGFILE="$TERMUX_TMP/chd_host_virgl.log"
> "$LOGFILE"

VIRGL_SOCKET="$TERMUX_TMP/.virgl_test"

# ─── 1. Already running? ──────────────────────────────────────────────────────
if [ -S "$VIRGL_SOCKET" ] && pgrep -x "virgl_test_server" > /dev/null 2>&1; then
    echo "[virgl] Already running with socket present. OK." >> "$LOGFILE"
    exit 0
fi

# Kill any stale process and remove stale socket.
pkill -x "virgl_test_server" 2>/dev/null || true
rm -f "$VIRGL_SOCKET" 2>/dev/null || true
echo "[virgl] Previous instance cleaned up." >> "$LOGFILE"

# ─── 2. Auto-install required packages if missing ────────────────────────────
# NOTE: vulkan-loader-generic and vulkan-loader-android both ship
# $PREFIX/lib/libvulkan.so{,.1,.1.x.xxx}. Swapping between them with a plain
# `pkg uninstall` + `pkg install` can leave a stale symlink behind that a
# LATER, unrelated `pkg install`/`apt upgrade` can no longer safely
# dereference (observed in the wild as dpkg aborting with "failed to stat
# (dereference) existing symlink ... Permission denied" on libvulkan.so,
# then libvulkan.so.1, then even unrelated doc symlinks once the apt
# transaction was left half-applied). vulkan-loader-android points these
# links at a vendor/system path that only ITS OWN installer is set up to
# touch, so any other package unpacking over that path afterwards gets
# denied. We proactively clear the whole libvulkan.so* chain ourselves
# before switching packages so nothing is ever left for a future unpack
# to trip over, and we stop swallowing failures here so a broken install
# surfaces immediately instead of silently leaving a half-configured state.
# Guard: auto install/repair the GPU stack when the server binary OR the
# Turnip Vulkan ICD is missing. virgl renders GL via Zink -> Vulkan, so BOTH
# must be present; checking the binary alone misses a removed ICD (server
# starts but rendering dies with "failed to initialise renderer").
#
# This installs as root (script runs via su), which tags new files with an
# SELinux label the real Termux app cannot manage - a LATER manual apt/pkg
# inside Termux may then hit dpkg "Permission denied" (fix: chcon the prefix
# to $PREFIX/bin/bash's context). It does NOT touch OlliteRT/other apps:
# they use the SYSTEM Vulkan driver, which Termux packages cannot modify.
_need=0
command -v virgl_test_server >/dev/null 2>&1 || _need=1
ls "$TERMUX_PREFIX"/share/vulkan/icd.d/*freedreno*.json >/dev/null 2>&1 || _need=1
if [ "$_need" = 1 ]; then
    echo "[virgl] GPU stack incomplete - installing/repairing Termux GPU packages..." >> "$LOGFILE"
    pkg install -y tur-repo x11-repo </dev/null >> "$LOGFILE" 2>&1 || true
    pkg update -y </dev/null >> "$LOGFILE" 2>&1 || true
    # Preempt dpkg's "unable to securely remove libvulkan.so*" (symlinks into
    # read-only /system) by clearing them before the loader swap.
    rm -f "$TERMUX_PREFIX/lib/libvulkan.so" "$TERMUX_PREFIX"/lib/libvulkan.so.[0-9]* 2>/dev/null || true
    # Working Adreno stack for virgl: Zink + generic loader (reads ICD JSONs)
    # + freedreno Turnip ICD. (vulkan-loader-android points at the system
    # driver and does NOT load the Turnip ICD, so Zink gets no Vulkan device.)
    pkg install -y mesa-zink virglrenderer-mesa-zink virglrenderer-android \
        vulkan-loader-generic mesa-vulkan-icd-freedreno </dev/null >> "$LOGFILE" 2>&1 || true
    dpkg --configure -a >> "$LOGFILE" 2>&1 || true
    apt -f install -y </dev/null >> "$LOGFILE" 2>&1 || true
    echo "[virgl] Package install/repair complete." >> "$LOGFILE"
fi
if ! command -v virgl_test_server >/dev/null 2>&1; then
    echo "[virgl] ERROR: virgl_test_server still not available after install." >> "$LOGFILE"
    exit 1
fi

# ─── 3. Start virgl_test_server ──────────────────────────────────────────────
echo "[virgl] Starting virgl_test_server (Zink mode)..." >> "$LOGFILE"
MESA_NO_ERROR=1 \
MESA_GL_VERSION_OVERRIDE=4.3COMPAT \
MESA_GLES_VERSION_OVERRIDE=3.2 \
GALLIUM_DRIVER=zink \
ZINK_DESCRIPTORS=lazy \
virgl_test_server --use-egl-surfaceless --use-gles \
    > "$TERMUX_TMP/virgl_output.log" 2>&1 &

VIRGL_PID=$!

# ─── 4. Wait for socket (up to 15 s) ─────────────────────────────────────────
i=0
while [ "$i" -lt 15 ]; do
    if [ -S "$VIRGL_SOCKET" ]; then
        echo "[virgl] Socket ready after ${i}s (PID $VIRGL_PID)." >> "$LOGFILE"
        exit 0
    fi
    sleep 1
    if ! kill -0 "$VIRGL_PID" 2>/dev/null; then
        echo "[virgl] ERROR: virgl_test_server (PID $VIRGL_PID) exited prematurely." >> "$LOGFILE"
        break
    fi
    i=$((i + 1))
done

echo "[virgl] ERROR: socket not found at $VIRGL_SOCKET after ${i}s." >> "$LOGFILE"
if [ -s "$TERMUX_TMP/virgl_output.log" ]; then
    echo "--- virgl_output.log ---" >> "$LOGFILE"
    cat "$TERMUX_TMP/virgl_output.log" >> "$LOGFILE"
fi
exit 1
