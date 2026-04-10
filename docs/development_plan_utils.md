Runtime services: host/guest design and implementation plan

## 1) Planned features (new)

- Host-managed runtime scripts for GPU, audio and X: `host_start_virgl.sh`, `host_start_pulseaudio.sh`, `host_start_x11.sh`.
- Profile-driven runtime orchestration in `chroot-distro` (mount/login triggers host or guest action per profile).
- Profile fields to control behavior: `PULSE_MODE=host|chroot`, `GRAPHICS_BACKEND=virgl|x11|vnc`.

## 2) Background and goals

- Problem: chroot guests need access to host resources (GPU, audio, display) but running privileged host services from many guests is error-prone.
- Goal: centralize host resource management (start/verify GPU renderer, Pulse, host X), and provide simple, deterministic guest behavior via profile flags and exported env variables.

## 3) Focus areas

- Host-side scripts: idempotent wrappers that start and verify services and write status logs.
- Chroot orchestration: `chroot-distro` must detect profile flags and either start guest services inside the chroot or call host scripts when host-managed mode is configured.
- Stability: ensure DBus, X credentials, and Pulse auth are correctly handled before starting desktop sessions.

## 4) Deferred / pending

- Full automation for GPU device binding (some devices require manual host provisioning or root privileges).
- Integration tests for multiple simultaneous instances using host-managed virgl.

## 5) Commands and behaviors (how it works)

- Host-side scripts (examples placed under `Termux-Desktops/scripts/host/` or similar):
	- `host_start_virgl.sh` — start or verify `virgl_test_server`/turnip and ensure `/dev/dri`/socket visibility.
	- `host_start_pulseaudio.sh` — start PulseAudio with `module-native-protocol-tcp` (bind address, auth) and log the listening port.
	- `host_start_x11.sh` — start Termux X11 or helper that ensures the host X server is accepting client connections.

- chroot-distro behavior at mount/login:
	- Read instance profile (existing `INCLUDE` plus `PULSE_MODE`/`GRAPHICS_BACKEND`).
	- If `PULSE_MODE=host`, invoke `host_start_pulseaudio.sh` (host context) and export `PULSE_SERVER` to chroot env.
	- If `GRAPHICS_BACKEND=virgl`, invoke `host_start_virgl.sh` and ensure guest has necessary env or device bindings. If `vnc`, start guest `vncserver` inside the chroot.
	- Ensure `dbus-launch` env is present for desktop session startup, or write xstartup wrappers that include DBus initialization.

## 6) Implementation notes (practical)

- Host privileges: scripts may require root to bind loop devices, set up `/dev/dri` or adjust permissions — keep privileged operations in host scripts and document capability requirements.
- Pulse security: use `module-native-protocol-tcp` with an ACL or per-instance auth token to avoid exposing host audio to arbitrary clients.
- X auth: prefer exporting an appropriate `MIT-MAGIC-COOKIE` or call `xhost +SI:localuser:root` carefully; document risks.
- DBus: prefer `dbus-launch --exit-with-session` for xstartup or ensure `DBUS_SESSION_BUS_ADDRESS` is exported into the session environment.

## 7) Testing & debugging

- Host checks:
	- `ps aux | grep -E 'virgl|turnip'`
	- `ss -lntp | grep 4713` (Pulse)
	- `ls -l /dev/dri`
- Guest checks (run inside chroot):
	- `command -v pulseaudio || echo pulseaudio:missing`
	- `command -v vncserver || echo vncserver:missing`
	- Verify `DISPLAY` and `PULSE_SERVER` env vars are set when sessions start.
- Logging: write host script output to `/var/log/chroot-distro-runtime.log` with timestamps and per-instance prefixes for easier triage.

## 8) Next steps (proposed)

1. Create host script templates (A): `host_start_virgl.sh`, `host_start_pulseaudio.sh`, `host_start_x11.sh` (idempotent, minimal checks, logging).
2. Update `chroot_distro_start_runtime_services()` to consult `PULSE_MODE` and `GRAPHICS_BACKEND` and prefer host-managed scripts when configured; export required env vars into the chroot session.
3. Add `PULSE_MODE=host` default for Termux profiles and document profile fields in `docs/`.

If you want I can implement (1) and (2) now and run a quick smoke-check; tell me whether to proceed with implementing the host scripts and wiring them into `chroot-distro`.

