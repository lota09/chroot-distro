# GPU Acceleration (Doc C)

How to get real GPU acceleration inside a chd guest on a **Qualcomm Adreno**
phone (e.g. Galaxy Note20 / SM-N986N, Adreno 650). This is the separate GPU
guide referenced by the profile wizard and by `chd-gpu-setup`.

TL;DR: install the **KGSL Turnip** Vulkan driver in the guest once, then run any
app with `gpuacc <app>`. `sudo chd-gpu-setup` does the install for you.

---

## Why this is needed

Adreno GPUs speak **Vulkan**, not OpenGL. Linux desktop apps are OpenGL, so the
stack is:

```
App (OpenGL) --> Zink (GL->Vulkan) --> Turnip (Vulkan driver) --> Adreno GPU
```

Two things must line up:

1. **The GPU device nodes must be visible in the guest.** chd bind-mounts
   `/dev`, so `/dev/kgsl-3d0` (the Adreno node) and `/dev/dri/*` are already
   present. Verify: `ls -l /dev/kgsl-3d0` → `crw-rw-rw-`.
2. **Turnip must support KGSL.** This phone uses Qualcomm's *downstream* kernel,
   where the GPU is reached through **KGSL** (`/dev/kgsl-3d0`), not the mainline
   DRM/MSM path. **Ubuntu's stock `mesa-vulkan-drivers` Turnip is DRM-only** —
   it has zero KGSL support, so it fails with `ZINK: failed to choose pdev`. You
   need a **KGSL-patched Turnip** built for glibc/arm64. That is the one extra
   package this guide installs.

> Note: the old **virgl / virpipe** path (guest → `virgl_test_server` on the
> host) does **not** work on this device: Termux's virglrenderer is capped at
> ~2023 and its vtest protocol no longer matches modern guest Mesa
> (`lost connection to rendering server ... read -1 22`). The Direct-Turnip path
> below replaces it and needs no host server at all.

---

## The driver

**`mesa-vulkan-kgsl_24.1.0-devel-20240120_arm64.deb`** — a DRI3-patched,
KGSL-capable Turnip built for glibc arm64 (from the Termux-Desktops / r/termux
community). It installs as `mesa-vulkan-drivers` (replacing the stock one) and
depends on `libllvm15` (packaged as `libllvm15t64` on Ubuntu 24.04).

Sources (keep a local backup — links rot):

- Google Drive: `https://drive.google.com/file/d/1f4pLvjDFcBPhViXGIFoRE3Xc8HWoiqG-/view`
  (file id `1f4pLvjDFcBPhViXGIFoRE3Xc8HWoiqG-`)
- Reddit thread: r/termux — "proot linux only dri3 patch mesa turnip driver"
  (`/r/termux/comments/19dpqas/`)
- Termux-Desktops docs: `HardwareAcceleration.md`
- Similar builds: GitHub `MatrixhKa/mesa-turnip` releases (Arch-format zip)

---

## Install

### Automatic — during `chd install` (default)

If you answer **yes** to GPU acceleration in the profile, chd installs this
driver for you during setup (the guest init downloads it via `gdown`, installs
it plus `libllvm15t64`, and pins it with `apt-mark hold`). Nothing else to do —
after install, `gpuacc <app>` uses the GPU. This step needs network at install
time; if it can't reach the download it is skipped (non-fatal) with a message
telling you to run the retry below.

### Retry (path B) — `chd-gpu-setup`

If the automatic step failed (no network at install time, etc.), run once in the
guest:

```sh
sudo chd-gpu-setup
```

Same actions as the automatic step. If the download still fails it prints this
document's location and stops — then use the manual steps below.

### Manual (path C) — if B can't reach the download

```sh
# 1) obtain the .deb (from a source above / your backup) into the guest, e.g.:
pip install --break-system-packages gdown
~/.local/bin/gdown 1f4pLvjDFcBPhViXGIFoRE3Xc8HWoiqG- -O mesa-vulkan-kgsl.deb

# 2) install the LLVM 15 runtime it needs, then the driver:
sudo apt-get update
sudo apt-get install -y libllvm15t64
sudo dpkg -i mesa-vulkan-kgsl.deb
sudo dpkg --configure -a         # do NOT run `apt -f install` - it can revert the driver

# 3) pin so `apt upgrade` never replaces it:
sudo apt-mark hold mesa-vulkan-drivers libllvm15t64
```

---

## Verify

```sh
export XDG_RUNTIME_DIR=/tmp/rt-$(id -u); mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"

# Vulkan sees Turnip?
MESA_LOADER_DRIVER_OVERRIDE=zink TU_DEBUG=noconform vulkaninfo 2>/dev/null \
  | grep -iE 'deviceName|driverID'
# expect: deviceName = Turnip Adreno (TM) 650   /   driverID = DRIVER_ID_MESA_TURNIP

# OpenGL on the GPU?
gpuacc glmark2 2>&1 | grep GL_RENDERER
# expect: GL_RENDERER: zink Vulkan 1.3 (Turnip Adreno (TM) 650 (MESA_TURNIP))
```

---

## Using it

Software rendering (softpipe) is the **default** for the shell and the desktop
session — it is stable and never black-screens. Turn on the GPU **per app**:

```sh
gpuacc glmark2
gpuacc blender
gpuacc <any-GL-app>
```

`gpuacc` is just a wrapper that exports:

```sh
MESA_LOADER_DRIVER_OVERRIDE=zink   # translate GL through Zink
TU_DEBUG=noconform                 # Turnip: skip conformance gating
# and unsets LIBGL_ALWAYS_SOFTWARE / GALLIUM_DRIVER
```

> Running the **entire** desktop session on the GPU is intentionally *not* the
> default: driving a whole DE (WM + panel + compositor) through Zink/Turnip is
> unstable on Android and often black-screens. Keep the session on softpipe and
> accelerate individual apps with `gpuacc`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `ZINK: failed to choose pdev` | KGSL Turnip not installed (stock Turnip is DRM-only). Run `chd-gpu-setup`. |
| `failed to load driver: zink` + `libLLVM...15` errors | `libllvm15t64` missing: `sudo apt-get install -y libllvm15t64` then `sudo dpkg --configure -a`. |
| renderer shows `llvmpipe`/`softpipe` | env not applied (e.g. ran under `sudo`, which strips it). Use `gpuacc <app>`; set `XDG_RUNTIME_DIR`. |
| `lost connection to rendering server ... read -1 22` | that's the old virgl/virpipe path — not used anymore; use Direct Turnip (`gpuacc`). |
| driver reverts after `apt upgrade` | you missed the hold: `sudo apt-mark hold mesa-vulkan-drivers libllvm15t64`. |
| `/dev/kgsl-3d0` missing in guest | chd mounts `/dev`; ensure the instance is mounted/logged-in and the node exists on the host. |

Remove the driver (back to stock software Turnip):

```sh
sudo apt-mark unhold mesa-vulkan-drivers
sudo apt-get install --reinstall mesa-vulkan-drivers   # stock Ubuntu version
```

---

## Notes

- Verified on-device: Note20 (SM-N986N, Adreno 650), Ubuntu 24.04 guest,
  `mesa-vulkan-kgsl 24.1.0-devel-20240120` + `libllvm15t64`, GL via Zink →
  `zink (Turnip Adreno (TM) 650)`.
- The Mesa GL/Zink side and the KGSL Turnip Vulkan side are decoupled through the
  Vulkan API, so they need not be the same Mesa version.
- Keep a **local backup of the .deb**. If every remote source disappears you can
  still reinstall from your own copy.
