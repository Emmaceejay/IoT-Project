#!/usr/bin/env python3
"""
DSGV Hub Firmware — Binary Size Verification

Enforces a hard size limit on a firmware binary so it never silently
outgrows the OTA partition it must fit into.

Usage:
    python3 scripts/check_binary_size.py <bin_path> <limit_bytes>

Arguments:
    bin_path      Path to the compiled application .bin file.
    limit_bytes   Maximum allowed size in bytes. Recommended values:
                    4 MB flash (partitions_4mb.csv):  1835008  (1.75 MB — 64 KB margin)
                    8 MB flash (partitions_8mb.csv):  3080192  (2.94 MB — 64 KB margin)

Exit codes:
    0  Binary is within limit (PASS)
    1  Binary exceeds limit, or file not found (FAIL)

Called automatically by scripts/build_device.ps1 after every successful
build. Also suitable for use in CI pipelines.
"""

import sys
import os


def main() -> None:
    if len(sys.argv) != 3:
        print(f"Usage: {os.path.basename(sys.argv[0])} <bin_path> <limit_bytes>")
        sys.exit(1)

    bin_path = sys.argv[1]
    try:
        limit = int(sys.argv[2])
    except ValueError:
        print(f"ERROR: limit_bytes must be an integer, got: {sys.argv[2]}")
        sys.exit(1)

    if not os.path.isfile(bin_path):
        print(f"ERROR: Binary not found: {bin_path}")
        sys.exit(1)

    size = os.path.getsize(bin_path)
    headroom = limit - size
    budget_pct = (size / limit) * 100

    print(f"  Binary  : {os.path.basename(bin_path)}")
    print(f"  Size    : {size:>10,} bytes  ({size / 1024:.1f} KB)")
    print(f"  Limit   : {limit:>10,} bytes  ({limit / 1024:.1f} KB)")
    print(f"  Budget  : {budget_pct:5.1f}%    Headroom: {headroom:,} bytes ({headroom / 1024:.1f} KB)")

    if size > limit:
        overage = size - limit
        print()
        print(f"  FAIL: Binary exceeds OTA slot limit by {overage:,} bytes ({overage / 1024:.1f} KB)")
        print("  Fix options:")
        print("    1. Add CONFIG_COMPILER_OPTIMIZATION_SIZE=y to sdkconfig.defaults")
        print("    2. Disable unused features (CONFIG_CHIP_OTA_REQUESTOR=n, etc.)")
        print("    3. Upgrade to 8 MB flash and switch to partitions_8mb.csv")
        sys.exit(1)

    if budget_pct >= 90:
        print()
        print(f"  WARN: Binary is {budget_pct:.1f}% of OTA slot — headroom is tight.")
        print("  Recommendation: upgrade to 8 MB flash (partitions_8mb.csv).")

    print("  PASS")


if __name__ == "__main__":
    main()
