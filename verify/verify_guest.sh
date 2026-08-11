#!/bin/sh
# chroot-distro :: GUEST-shell verification
# Run INSIDE the chd instance (after `chd login <instance>`, at root@localhost):
#     sh verify_guest.sh
# Confirms the things the guest actually depends on: network, apt groups, audio
# to the host, GPU passthrough, X11, the supervisord service manager and mounts.

PORT=4713
P=0; F=0; W=0
pass(){ echo "  [PASS] $*"; P=$((P+1)); }
fail(){ echo "  [FAIL] $*"; F=$((F+1)); }
warn(){ echo "  [WARN] $*"; W=$((W+1)); }
hdr(){ echo; echo "== $* =="; }
have(){ command -v "$1" >/dev/null 2>&1; }

echo "### chroot-distro :: guest check ($(cat /etc/hostname 2>/dev/null)) ###"
echo "  distro: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"

hdr "network"
if [ -s /etc/resolv.conf ]; then pass "resolv.conf present"; else fail "no /etc/resolv.conf"; fi
if have getent; then
  if getent hosts deb.debian.org >/dev/null 2>&1 || getent hosts archive.ubuntu.com >/dev/null 2>&1; then pass "DNS resolves"; else warn "DNS resolve failed"; fi
fi
if have apt-get; then
  if timeout 25 apt-get -o Acquire::http::Timeout=8 update -qq >/dev/null 2>&1; then pass "apt update reaches mirrors"; else warn "apt update failed/slow (ok if offline)"; fi
fi

hdr "groups (network + apt inside chroot)"
if getent group aid_inet >/dev/null 2>&1 || getent group 3003 >/dev/null 2>&1; then pass "aid_inet(3003) group present"; else fail "no aid_inet group -> chroot has no network"; fi
aptgid=$(id -g _apt 2>/dev/null)
if [ "$aptgid" = 3003 ]; then pass "_apt primary gid = 3003 (apt keeps network in its sandbox)"; else warn "_apt gid=${aptgid:-none} (expected 3003)"; fi

hdr "audio -> host PulseAudio"
export PULSE_SERVER="tcp:127.0.0.1:$PORT"
echo "  PULSE_SERVER=$PULSE_SERVER"
if have pactl; then
  if pactl info >/dev/null 2>&1; then
    pass "pactl connects to host PulseAudio"
    pactl info 2>/dev/null | sed -n 's/^Server Name/  Server Name/p'
  else
    fail "cannot reach host PulseAudio (is the host daemon up?)"
  fi
else
  warn "pactl not installed (apt install -y pulseaudio-utils)"
fi
echo "  sound test (should beep on the phone speaker):"
echo "    PULSE_SERVER=$PULSE_SERVER speaker-test -t sine -f 440 -l 1 -c 2"

hdr "GPU"
# IMPORTANT: the desktop session and the gpuacc helper select the GPU by
# EXPORTING GALLIUM_DRIVER=virpipe (+ MESA_* overrides). A bare `glxinfo` - or
# ANY glxinfo run under sudo, which strips the environment - has no GALLIUM_DRIVER
# and silently falls back to llvmpipe, which is why a plain check misreports the
# renderer as software. We therefore set the real GPU env explicitly and probe
# the actual accelerated path, exactly like the desktop does.
if [ -S /tmp/.virgl_test ]; then pass "virgl socket present at /tmp/.virgl_test (GPU path available)"; else warn "no virgl socket - desktop falls back to softpipe (CPU)"; fi
if have gpuacc; then pass "gpuacc helper present (force GPU for one app: gpuacc <app>)"; else warn "gpuacc helper missing"; fi

if ! have glxinfo; then
  warn "glxinfo missing (apt install -y mesa-utils) - cannot read renderer"
elif [ -z "$DISPLAY" ]; then
  warn "DISPLAY unset - cannot query GL renderer (needs the X session)"
else
  # what a naive/sudo check would report (software) - shown for contrast
  sw=$(GALLIUM_DRIVER=softpipe glxinfo 2>/dev/null | sed -n 's/^OpenGL renderer string: //p')
  [ -n "$sw" ] && echo "  software path (softpipe) : $sw"
  if [ -S /tmp/.virgl_test ]; then
    gpu=$(MESA_NO_ERROR=1 MESA_GL_VERSION_OVERRIDE=4.3 MESA_GLES_VERSION_OVERRIDE=3.2 GALLIUM_DRIVER=virpipe \
          glxinfo 2>/dev/null | sed -n 's/^OpenGL renderer string: //p')
    if echo "$gpu" | grep -qiE 'virgl|zink|turnip|adreno'; then
      pass "GPU path (virpipe) renderer: $gpu"
    elif [ -n "$gpu" ]; then
      warn "virpipe selected but renderer='$gpu' (GPU not actually engaged)"
    else
      warn "virpipe glxinfo returned nothing (GPU path broken)"
    fi
    echo "  (the desktop uses this GPU path only when DESKTOP_BACKEND=virpipe;"
    echo "   with softpipe the desktop stays on the software renderer above)"
  fi
fi

# Vulkan (guest Turnip) is OPTIONAL and tangential: the desktop's GL-on-GPU goes
# guest virpipe -> HOST virgl_test_server (Zink) -> Turnip, so guest-side Vulkan
# is not what draws the desktop. vulkaninfo is also known to crash on some Turnip
# builds, so we guard it and never let it abort this script.
if have vulkaninfo; then
  vk=$( { vulkaninfo --summary 2>/dev/null || true; } | sed -n 's/.*deviceName[^=]*= *//p' | head -n1)
  if [ -n "$vk" ]; then pass "guest Vulkan device: $vk"; else warn "guest vulkaninfo reported no device (Turnip/Zink quirk - not needed for the desktop GL path)"; fi
fi

hdr "X11"
if [ -n "$DISPLAY" ]; then pass "DISPLAY=$DISPLAY"; else warn "DISPLAY unset (headless profile)"; fi
if have xdpyinfo && [ -n "$DISPLAY" ]; then
  if xdpyinfo >/dev/null 2>&1; then pass "X server reachable"; else warn "cannot reach X server on $DISPLAY"; fi
fi

hdr "service manager (supervisord)"
if have supervisorctl; then
  echo "  supervisorctl status:"
  supervisorctl status 2>/dev/null | sed 's/^/    /'
  if supervisorctl status >/dev/null 2>&1; then pass "supervisord reachable"; else warn "supervisord not reachable"; fi
else
  warn "supervisorctl missing (guest services not managed)"
fi

hdr "mounts (ram / storage)"
for d in /tmp /run /dev/shm; do
  t=$(mktemp "$d/chd.XXXXXX" 2>/dev/null) && { rm -f "$t"; pass "$d writable"; } || warn "$d not writable/mounted"
done
if [ -d /sdcard ] && ls /sdcard >/dev/null 2>&1; then pass "/sdcard visible"; else warn "/sdcard not mounted"; fi

echo
echo "### guest result: PASS=$P  FAIL=$F  WARN=$W ###"
[ "$F" = 0 ] && echo "OK - guest looks healthy." || echo "FAILURES above need attention."
