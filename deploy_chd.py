#!/usr/bin/env python3
"""Deploy the chd (reborn) Magisk module to a connected Android device.

build zip (forward-slash entries) -> push to /sdcard/modules
  -> remove old install -> magisk --install-module (root)
  -> VERIFY the module actually landed -> optional reboot.

Python zipfile is used on purpose: it always writes forward-slash entry names,
so the "system\\bin\\chd" backslash breakage from PowerShell Compress-Archive /
old .NET ZipFile cannot happen. Magisk reports "success" even on a broken zip,
so we verify system/bin/chd is really present afterward.

Usage:
  python deploy_chd.py                 # build, push, install
  python deploy_chd.py --reboot        # ... then reboot (fully activates)
  python deploy_chd.py --no-install    # build + push only
  python deploy_chd.py --source-dir <dir> --adb <adb.exe>
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
import zipfile

MODULE_ID = "chroot-distro"
# NOTE: 'lib' IS required for the reborn build - customize.sh deploys lib/ + scripts/
# to $CHD_ROOT. Omitting it ships a module whose commands are all "not wired".
REQUIRED = ["module.prop", "customize.sh", "META-INF", "lib", "scripts", "system"]
OPTIONAL = ["config.sh", "update.json"]


def step(msg): print(f">> {msg}")
def info(msg): print(f"   {msg}")
def warn(msg): print(f"!! {msg}")
def die(msg):
    print(f"XX {msg}")
    sys.exit(1)


def run_adb(adb, args):
    try:
        r = subprocess.run([adb] + args, capture_output=True,
                           text=True, encoding="utf-8", errors="replace")
    except FileNotFoundError:
        die(f"adb not found: {adb} (install platform-tools or pass --adb)")
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def build_zip(source_dir, out_zip):
    items = []
    for item in REQUIRED:
        p = os.path.join(source_dir, item)
        if not os.path.exists(p):
            die(f"Required item is missing: {item} ({p})")
        items.append(item)
    for item in OPTIONAL:
        if os.path.exists(os.path.join(source_dir, item)):
            items.append(item)
        else:
            info(f"skipped (not found): {item}")

    if os.path.exists(out_zip):
        os.remove(out_zip)
    os.makedirs(os.path.dirname(out_zip) or ".", exist_ok=True)

    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED) as zf:
        for item in items:
            path = os.path.join(source_dir, item)
            if os.path.isdir(path):
                for root, _dirs, files in os.walk(path):
                    for f in files:
                        full = os.path.join(root, f)
                        arc = os.path.relpath(full, source_dir).replace(os.sep, "/")
                        zf.write(full, arc)
            else:
                zf.write(path, item)
            info(f"included: {item}")

    with zipfile.ZipFile(out_zip) as zf:
        names = zf.namelist()
    bad = [n for n in names if "\\" in n]
    if bad:
        die("zip has backslash entry names (would break Magisk): " + ", ".join(bad))
    # Sanity: the library modules must be in the zip.
    if not any(n.startswith("lib/") and n.endswith(".sh") for n in names):
        die("zip contains no lib/*.sh - the module would install with no logic.")
    return os.path.getsize(out_zip)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="Deploy the chd (reborn) Magisk module.")
    ap.add_argument("--source-dir", default=here, help="reborn repo root (default: this script's dir)")
    ap.add_argument("--out-zip",
                    default=os.path.join(tempfile.gettempdir(), "chd-rb2-module.zip"))
    ap.add_argument("--adb", default="adb", help="path to adb (default: adb on PATH)")
    ap.add_argument("--no-install", action="store_true", help="build+push only")
    ap.add_argument("--reboot", action="store_true", help="reboot after a verified install")
    args = ap.parse_args()

    if not os.path.isdir(args.source_dir):
        die(f"source-dir not found: {args.source_dir}")

    step("Building module zip (forward-slash entries, lib/ included)...")
    size = build_zip(args.source_dir, args.out_zip)
    info(f"done: {args.out_zip} ({round(size/1024, 1)} KB, entries verified)")

    step("Checking adb devices...")
    rc, out = run_adb(args.adb, ["devices"])
    for l in out.splitlines():
        if l.strip():
            print(f"     | {l.rstrip()}")
    devices = [l.strip() for l in out.splitlines() if re.match(r"^\S+\s+device$", l.strip())]
    if len(devices) == 0:
        warn("No device in 'device' state. Skipping install.")
        sys.exit(0)
    if len(devices) > 1:
        warn(f"{len(devices)} devices connected - ambiguous, skipping.")
        sys.exit(0)
    serial = devices[0].split()[0]
    info(f"exactly one device: {serial}")

    def sh(cmd):
        return run_adb(args.adb, ["-s", serial, "shell", cmd])

    step("Ensuring /sdcard/modules and pushing...")
    sh("mkdir -p /sdcard/modules")
    leaf = os.path.basename(args.out_zip)
    remote = f"/sdcard/modules/{leaf}"
    rc, out = run_adb(args.adb, ["-s", serial, "push", args.out_zip, "/sdcard/modules/"])
    for l in out.splitlines():
        if l.strip():
            print(f"     | {l.rstrip()}")
    if rc != 0:
        die(f"adb push exit={rc}")
    rc, out = sh(f"stat -c %s {remote} 2>/dev/null || wc -c < {remote} 2>/dev/null")
    nums = [l.strip() for l in out.splitlines() if l.strip().isdigit()]
    if not nums or int(nums[-1]) != size:
        die(f"size mismatch/absent on device (said: {out.strip()}) - re-run")
    info(f"verified on device: {remote} ({size} bytes)")

    if args.no_install:
        info(f"push only. Install manually: {args.adb} -s {serial} shell su -c \"magisk --install-module {remote}\"")
        return

    step("Removing any previous module install...")
    sh(f'su -c "rm -rf /data/adb/modules/{MODULE_ID} /data/adb/modules_update/{MODULE_ID}"')

    step("Installing via Magisk (root)...")
    rc, out = sh(f'su -c "magisk --install-module {remote}"')
    for l in out.splitlines():
        print(f"     | {l.rstrip()}")
    if rc != 0 or re.search(r"Installation failed|! Install", out, re.I):
        die(f"Magisk install FAILED (exit={rc}). See output above.")

    step("Verifying the module actually installed (Magisk lies about success)...")
    chk = (f"[ -f /data/adb/modules/{MODULE_ID}/system/bin/chd ] || "
           f"[ -f /data/adb/modules_update/{MODULE_ID}/system/bin/chd ]")
    rc, out = sh(f'su -c "{chk} && echo MOD_OK || echo MOD_BAD"')
    if "MOD_OK" not in out:
        die("module has NO system/bin/chd tree - install did NOT work.")
    # Also verify lib actually landed in the working dir (reborn-specific).
    rc, out = sh('su -c "ls /data/local/chroot-distro/lib/*.sh 2>/dev/null | wc -l"')
    n = next((l.strip() for l in out.splitlines() if l.strip().isdigit()), "0")
    if n == "0":
        warn("system/bin/chd is present but lib/ not yet deployed to /data/local/chroot-distro "
             "(customize.sh deploys it on install; a reboot install will populate it).")
    else:
        info(f"verified: {n} lib module(s) deployed to /data/local/chroot-distro/lib")
    info("verified: system/bin/chd present (staged; activates on reboot)")

    if args.reboot:
        step(f"Rebooting {serial} to activate...")
        run_adb(args.adb, ["-s", serial, "reboot"])
        info("Done: installed and rebooting. After boot: adb shell su -c 'chd list'")
    else:
        info("Done: module installed and verified. Reboot once if a fresh shell can't find chd.")


if __name__ == "__main__":
    main()
