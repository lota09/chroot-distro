#!/data/data/com.termux/files/usr/bin/sh
# chroot-distro :: TERMUX-shell verification
# Run INSIDE the Termux app (as the Termux user):
#     sh verify_termux.sh
# Confirms the host daemons from Termux's own context and, in particular, that
# the PulseAudio audio-link fix (system libEGL vs Mesa libEGL) is doing its job.

PREFIX=/data/data/com.termux/files/usr
PORT=4713; HEX=1269

P=0; F=0; W=0
pass(){ echo "  [PASS] $*"; P=$((P+1)); }
fail(){ echo "  [FAIL] $*"; F=$((F+1)); }
warn(){ echo "  [WARN] $*"; W=$((W+1)); }
hdr(){ echo; echo "== $* =="; }
port_up(){ { cat /proc/net/tcp; cat /proc/net/tcp6; } 2>/dev/null | grep -qi ":$1 "; }

echo "### chroot-distro :: termux-shell check ###"
myuid=$(id -u 2>/dev/null)
appuid=$(stat -c %u /data/data/com.termux 2>/dev/null)
if [ "$myuid" = "$appuid" ]; then pass "running as the Termux user (uid=$myuid)"; else warn "uid=$myuid != Termux app uid=$appuid (run this INSIDE Termux)"; fi

hdr "PulseAudio (audio-link fix)"
if command -v pulseaudio >/dev/null 2>&1; then pass "pulseaudio installed"; else fail "pulseaudio not installed"; fi
# AUTHORITATIVE check: can we actually talk to the daemon on its TCP port?
# IMPORTANT: pgrep and /proc/net/tcp are UNRELIABLE from an unprivileged Termux
# app shell - Android hides other processes (hidepid) and filters /proc/net/tcp
# for app UIDs, so they report false negatives even when pulseaudio is up. A
# successful pactl connection is the real proof and needs no root; that is why
# the login-time check (which runs as root) can correctly see the port while a
# raw port scan in this shell cannot.
if command -v pactl >/dev/null 2>&1; then
  if PULSE_SERVER=tcp:127.0.0.1:$PORT pactl info >/dev/null 2>&1; then
    pass "PulseAudio is up and listening on $PORT (pactl connected)"
    PULSE_SERVER=tcp:127.0.0.1:$PORT pactl info 2>/dev/null | sed -n 's/^Server Name/  Server Name/p'
  else
    fail "cannot reach PulseAudio on $PORT (start it: chd login <instance>)"
  fi
else
  warn "pactl not available to verify (pkg install pulseaudio)"
fi
# Informational only - expected to say 'not visible' on Android; NOT a failure:
if pgrep -x pulseaudio >/dev/null 2>&1; then
  echo "  info: pulseaudio process is visible to this shell"
else
  echo "  info: process/port not visible from this app shell (normal - Android /proc restriction, see note above)"
fi

hdr "why the fix is needed (evidence)"
if [ -e "$PREFIX/lib/libEGL.so" ]; then
  warn "Mesa libEGL is in \$PREFIX/lib (installed for the GPU stack) - it shadows system libEGL; this is exactly why pulse must put /system/lib64 first"
else
  echo "  (no Mesa libEGL in \$PREFIX/lib - shadowing would not occur here)"
fi
if command -v readelf >/dev/null 2>&1; then
  c=$(readelf --dyn-syms /system/lib64/libEGL.so 2>/dev/null | grep -c eglDestroySyncKHR)
  if [ "${c:-0}" -ge 1 ]; then pass "system libEGL exports eglDestroySyncKHR (the missing symbol)"; else warn "system libEGL lacks the symbol (unexpected)"; fi
fi
# Loading the binary resolves its DT_NEEDED (libOpenSLES -> libgui -> libEGL),
# so `pulseaudio --version` links the whole system audio chain. With the fix it
# succeeds; without /system/lib64 first it hits the eglDestroySyncKHR crash.
if LD_LIBRARY_PATH=/system/lib64:/system/lib:$PREFIX/lib pulseaudio --version >/dev/null 2>&1; then
  pass "pulseaudio links cleanly WITH /system/lib64 first (fix works)"
else
  fail "pulseaudio still fails to link even with the fix - capture the error"
fi
if LD_LIBRARY_PATH=$PREFIX/lib pulseaudio --version >/dev/null 2>&1; then
  echo "  note: it also links WITHOUT the fix here (Mesa GL likely not installed on this device)"
else
  pass "confirmed: WITHOUT /system/lib64 the link fails - the fix is what makes audio work"
fi

hdr "GPU stack"
if command -v virgl_test_server >/dev/null 2>&1; then pass "virgl_test_server installed"; else warn "virgl_test_server missing"; fi
if pgrep -x virgl_test_server >/dev/null 2>&1; then pass "virgl_test_server running"; else warn "virgl not running (GPU off / not requested)"; fi
if [ -S "$PREFIX/tmp/.virgl_test" ]; then pass "virgl socket present"; else warn "no virgl socket"; fi
if ls "$PREFIX"/share/vulkan/icd.d/*freedreno*.json >/dev/null 2>&1; then pass "Turnip (freedreno) Vulkan ICD present"; else warn "no freedreno Vulkan ICD"; fi

hdr "Termux:X11"
if [ -S "$PREFIX/tmp/.X11-unix/X0" ]; then pass "Termux:X11 socket (:0) present"; else warn "no X11 socket (open the Termux:X11 app / headless)"; fi

echo
echo "### termux-shell result: PASS=$P  FAIL=$F  WARN=$W ###"
[ "$F" = 0 ] && echo "OK - Termux host side looks healthy." || echo "FAILURES above need attention."
