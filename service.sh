#!/system/bin/sh
# chd (reborn) autoboot — Magisk late_start service (runs as root after boot).
#
# For every instance whose profile has AUTOBOOT="true", bring it up
# automatically after the phone reboots: mount the rootfs + start its services
# (supervisord: sshd/cron/desktop/x11vnc). That means you can `ssh user@device`
# straight into the chroot without ever running `chd login` by hand.
#
# Enable per-instance in the profile wizard ("Auto-start on boot"), or set
# AUTOBOOT="true" in $CHD_ROOT/.config/<name>.conf. Disabled instances are
# skipped, so this file is a no-op until at least one profile opts in.
#
# `chd command <name> true` is the non-interactive equivalent of `chd login`:
# it runs the exact same bring-up + chd_services_up, then executes `true`
# inside the chroot and exits (no shell). See lib/instance.sh:chd_cmd_command.

CHD_ROOT="${CHROOT_DISTRO_PATH:-/data/local/chroot-distro}"
CHD_BIN=/system/bin/chroot-distro
LOG="$CHD_ROOT/log/autoboot.log"

mkdir -p "$CHD_ROOT/log" 2>/dev/null
exec >>"$LOG" 2>&1

echo "==== chd autoboot $(date 2>/dev/null || echo) ===="

# The magic-mounted binary and the deployed runtime tree must both be present.
if [ ! -x "$CHD_BIN" ]; then
	echo "chroot-distro not on PATH yet (module not mounted?) — abort"
	exit 0
fi
if [ ! -d "$CHD_ROOT/.config" ]; then
	echo "no instances configured ($CHD_ROOT/.config missing) — nothing to autoboot"
	exit 0
fi

# Fast opt-in gate: if no conf sets AUTOBOOT=true, don't even wait for boot.
# NOTE: ERE (grep -E), not BRE '\?' — toybox/busybox grep treat BRE '\?' as a
# literal '?', so the gate silently never matched (verified on-device).
if ! grep -Eq '^AUTOBOOT="?true' "$CHD_ROOT"/.config/*.conf 2>/dev/null; then
	echo "no instance has AUTOBOOT=true — nothing to do"
	exit 0
fi

# Wait for boot to complete: /data decrypted, mounts settled, network up.
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 120 ]; do
	sleep 2
	i=$((i + 1))
done
echo "boot_completed=$(getprop sys.boot_completed) after ${i}x2s"

for conf in "$CHD_ROOT"/.config/*.conf; do
	[ -f "$conf" ] || continue
	name="$(basename "$conf" .conf)"
	# Read AUTOBOOT in a subshell so the conf's other vars don't leak here.
	ab="$(. "$conf" 2>/dev/null; echo "${AUTOBOOT:-false}")"
	if [ "$ab" != "true" ]; then
		echo "skip '$name' (AUTOBOOT=$ab)"
		continue
	fi
	echo "autoboot: bringing up '$name' ..."
	# mount + services + exit (no interactive shell). Same path as chd login.
	if "$CHD_BIN" command "$name" true; then
		echo "  [OK] '$name' up (services started)"
	else
		echo "  [FAIL] '$name' bring-up returned non-zero — see $CHD_ROOT/log/"
	fi
done

echo "==== chd autoboot done ===="
