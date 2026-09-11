#!/usr/bin/env python3
"""
Emit an ESP Web Tools build entry from an ESP-IDF build directory.

Offsets are read from the build's own flash_args rather than hardcoded. They
are not the same across chips — the bootloader sits at 0x1000 on ESP32 but
0x0 on C3, C6 and S3 — and getting one wrong produces a device that flashes
successfully and then does not boot, which is an expensive thing to debug
through a browser.

Usage:
    gen_manifest.py --build-dir devices/universal/build \\
                    --chip esp32c3 \\
                    --out build-esp32c3.json

    gen_manifest.py --merge build-*.json \\
                    --name "DSGV Universal" --version 1.0.0 \\
                    --out manifest.json
"""

import argparse
import json
import sys
from pathlib import Path

# ESP Web Tools chipFamily spellings. Its manifest schema matches on these
# exactly, and they are not the IDF target names.
CHIP_FAMILY = {
    "esp32":   "ESP32",
    "esp32c2": "ESP32-C2",
    "esp32c3": "ESP32-C3",
    "esp32c6": "ESP32-C6",
    "esp32h2": "ESP32-H2",
    "esp32s2": "ESP32-S2",
    "esp32s3": "ESP32-S3",
    "esp8266": "ESP8266",
}


def parse_flash_args(build_dir: Path):
    """Return [(offset:int, filename:str)] from flash_args.

    Format is a leading options line, then 'offset path' pairs:

        --flash_mode dio --flash_freq 80m --flash_size 4MB
        0x0 bootloader/bootloader.bin
        0x20000 dsgv_universal.bin
    """
    path = build_dir / "flash_args"
    if not path.is_file():
        sys.exit(f"no flash_args in {build_dir} — was the project built?")

    parts = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("--"):
            continue
        fields = line.split()
        if len(fields) != 2:
            continue
        offset_str, filename = fields
        try:
            parts.append((int(offset_str, 0), filename))
        except ValueError:
            continue

    if not parts:
        sys.exit(f"flash_args in {build_dir} contained no offset/file pairs")

    parts.sort(key=lambda p: p[0])
    return parts


def build_entry(build_dir: Path, chip: str):
    family = CHIP_FAMILY.get(chip)
    if not family:
        sys.exit(f"unknown chip '{chip}'; known: {', '.join(sorted(CHIP_FAMILY))}")

    parts = []
    for offset, filename in parse_flash_args(build_dir):
        src = build_dir / filename
        if not src.is_file():
            sys.exit(f"flash_args names {filename} but it is missing from {build_dir}")
        # Flatten: bootloader/bootloader.bin is published beside the others.
        parts.append({"path": Path(filename).name, "offset": offset})

    return {"chipFamily": family, "parts": parts}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build-dir", type=Path)
    ap.add_argument("--chip")
    ap.add_argument("--merge", nargs="*", type=Path,
                    help="per-chip build entry files to combine")
    ap.add_argument("--name", default="DSGV Universal Firmware")
    ap.add_argument("--version", default="0.0.0")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    if args.merge:
        builds = []
        for f in args.merge:
            builds.append(json.loads(f.read_text()))
        builds.sort(key=lambda b: b["chipFamily"])
        manifest = {
            "name": args.name,
            "version": args.version,
            # A device reflashed from another firmware may carry an
            # incompatible partition table; offering the erase avoids a
            # confusing half-working result.
            "new_install_prompt_erase": True,
            "builds": builds,
        }
        args.out.write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"{args.out}: {len(builds)} chip families "
              f"({', '.join(b['chipFamily'] for b in builds)})")
        return 0

    if not args.build_dir or not args.chip:
        ap.error("--build-dir and --chip are required unless --merge is used")

    entry = build_entry(args.build_dir, args.chip)
    args.out.write_text(json.dumps(entry, indent=2) + "\n")
    print(f"{args.out}: {entry['chipFamily']} — " +
          ", ".join(f"{p['path']}@{p['offset']:#x}" for p in entry["parts"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
