#!/system/bin/sh
# chroot-distro :: ROOT-shell verification
# Run in the Android ROOT shell (adb shell su, or a rooted terminal):
#     sh verify_root.sh [instance]
# Confirms: module integrity, our code changes (log prefix / parallel bring-up /
# gated relabel), the installed instance, and the host-side services.

INST="${1:-}"
CHD_ROOT=/data/local/chroot-distro
MODDIR=/data/adb/modules/chroot-distro
TERMUX=/data/data/com.termux
TP="$TERMUX/files/usr"
PORT=4713; HEX=1269               # 4713 == 0x1269 (for /proc/net/tcp scan)

P=0; F=0; W=0
pass(){ echo "  [PASS] $*"; P=$((P+1)); }
fail(){ echo "  [FAIL] $*"; F=$((F+1)); }
warn(){ echo "  [WARN] $*"; W=$((W+1)); }
hdr(){ echo; echo "== $* =="; }
port_up(){ { cat /proc/net/tcp; cat /proc/net/tcp6; } 2>/dev/null | grep -qi ":$1 "; }
is_mnt(){ awk -v p="$1" '$2==p{f=1} END{exit !f}' /proc/mounts 2>/dev/null; }

echo "### chroot-distro :: root-shell check ###"
if [ "$(id -u 2>/dev/null)" = 0 ]; then pass "running as root"; else fail "NOT root - run via su"; fi

hdr "module / working dir"
# The module can live in modules/ (active) OR modules_update/ (staged until the
# next reboot); either is fine, and being on PATH proves it resolves.
if [ -f "$MODDIR/system/bin/chd" ] || [ -f "/data/adb/modules_update/chroot-distro/system/bin/chd" ] || command -v chd >/dev/null 2>&1; then
  pass "chd command present"
else
  fail "chd command missing (not in modules/, modules_update/, or PATH)"
fi
if command -v chd >/dev/null 2>&1; then pass "chd on PATH"; else warn "chd not on PATH (reboot once after install)"; fi
if [ -d "$CHD_ROOT/lib" ]; then pass "lib/ deployed to $CHD_ROOT"; else fail "lib/ missing at $CHD_ROOT/lib"; fi
n=$(ls "$CHD_ROOT"/lib/*.sh 2>/dev/null | wc -l)
if [ "${n:-0}" -gt 0 ]; then pass "$n lib module(s) present"; else fail "no lib modules in $CHD_ROOT/lib"; fi
ver=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)
cver=$(sed -n 's/^CHD_VERSION="\(.*\)"/\1/p' "$CHD_ROOT/lib/util.sh" 2>/dev/null)
echo "  module.prop version : ${ver:-?}"
echo "  lib CHD_VERSION     : ${cver:-?}"
if [ -n "$ver" ] && [ "$ver" = "$cver" ]; then pass "versions match ($ver)"; else warn "version mismatch (prop=$ver lib=$cver) - redeploy"; fi

hdr "our changes are actually live"
if grep -q "chroot-distro" "$CHD_ROOT/lib/util.sh" 2>/dev/null && ! grep -q "\[chd\]" "$CHD_ROOT/lib/util.sh" 2>/dev/null; then
  pass "log prefix migrated to [chroot-distro] (no [chd] left)"
else
  fail "old [chd] log prefix still present"
fi
if grep -q "CHD_SVC_TAG" "$CHD_ROOT/lib/services.sh" 2>/dev/null; then pass "per-service log tags present"; else warn "CHD_SVC_TAG not found"; fi
if grep -q "_chd_termux_relabel" "$CHD_ROOT/lib/services.sh" 2>/dev/null; then pass "SELinux relabel hoisted to one call"; else warn "relabel helper missing"; fi
if grep -q "chd_relabel_needed" "$CHD_ROOT/lib/services.sh" 2>/dev/null; then pass "relabel gated by pkg-install marker (no 56s sweep on normal login)"; else warn "relabel not gated"; fi
if grep -q "system/lib64" "$CHD_ROOT/scripts/host/host_start_pulseaudio.sh" 2>/dev/null; then pass "pulse audio-link fix (/system/lib64 first) present"; else fail "pulse LD_LIBRARY_PATH fix missing"; fi
if [ -f "$TP/tmp/.chd_relabel_needed" ]; then warn "relabel marker present -> a one-time ~56s sweep runs next login"; else pass "no stale relabel marker (steady state)"; fi

hdr "instance"
if [ -z "$INST" ]; then
  for d in "$CHD_ROOT"/*/; do
    [ -d "$d" ] || continue
    b=$(basename "$d")
    case " lib scripts log .config .profile .rootfs .backup .cache _to_delete " in *" $b "*) continue ;; esac
    [ -d "$d/etc" ] && { INST="$b"; break; }
  done
fi
if [ -n "$INST" ]; then pass "instance: $INST"; else fail "no installed instance found"; fi
if [ -n "$INST" ] && [ -d "$CHD_ROOT/$INST/etc" ]; then pass "$INST rootfs valid (/etc present)"; else [ -n "$INST" ] && warn "$INST rootfs incomplete"; fi

hdr "host services"
if port_up "$HEX"; then pass "PulseAudio listening on 127.0.0.1:$PORT"; else fail "PulseAudio NOT listening on $PORT"; fi
if [ -S "$TP/tmp/.X11-unix/X0" ]; then pass "Termux:X11 socket (:0) present"; else warn "no X11 socket (headless profile?)"; fi
if [ -S "$TP/tmp/.virgl_test" ]; then pass "virgl socket present"; else warn "no virgl socket (GPU off / softpipe)"; fi

hdr "chroot mounts for ${INST:-<none>}"
if [ -n "$INST" ]; then
  R="$CHD_ROOT/$INST"
  any=0
  for m in proc sys dev dev/pts tmp dev/shm; do
    if is_mnt "$R/$m"; then pass "mounted: /$m"; any=1; else warn "not mounted: /$m"; fi
  done
  [ "$any" = 0 ] && echo "  (all unmounted is normal if you are not logged into the guest right now)"
fi

hdr "termux"
tu=$(stat -c %u "$TERMUX" 2>/dev/null)
if [ -n "$tu" ] && [ "$tu" != 0 ]; then pass "Termux app uid=$tu"; else fail "Termux not found"; fi

echo
echo "### root-shell result: PASS=$P  FAIL=$F  WARN=$W ###"
[ "$F" = 0 ] && echo "OK - host side looks healthy." || echo "FAILURES above need attention."
