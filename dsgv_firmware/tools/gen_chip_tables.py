#!/usr/bin/env python3
"""
Generate the flasher's per-chip pin tables from the firmware's own rules.

The browser UI has to know which GPIOs are selectable on each chip. Writing
that table a second time in JavaScript guarantees it eventually disagrees with
the firmware — and a disagreement in the permissive direction means the UI
happily offers a user the SPI flash pins, which bricks the board.

So this parses the masks out of components/dsgv_common/gpio/dsgv_pin_rules.c
and emits them as JSON. CI regenerates and diffs, so editing the C without
refreshing the JSON fails the build.

Usage:
    gen_chip_tables.py --out catalog/chips.json
    gen_chip_tables.py --out catalog/chips.json --check    # verify, do not write
"""

import argparse
import json
import re
import sys
from pathlib import Path

RULES_C = Path(__file__).resolve().parent.parent / \
    "components/dsgv_common/gpio/dsgv_pin_rules.c"

# ESP Web Tools chipFamily spellings, so the catalogue keys match the manifest.
CHIP_FAMILY = {
    "ESP32":   "ESP32",
    "ESP32C3": "ESP32-C3",
    "ESP32C6": "ESP32-C6",
    "ESP32S3": "ESP32-S3",
}

MASK_KEYS = ["M_NOT_EXIST", "M_RESERVED", "M_INPUT_ONLY",
             "M_STRAPPING", "M_CONSOLE", "M_USB"]


def eval_mask(expr: str) -> int:
    """Evaluate a C integer-constant expression from the mask table.

    The grammar used in that file is deliberately tiny: hex/decimal literals,
    ULL suffixes, <<, | and parentheses. Anything outside that is a sign the
    file changed shape and the caller should be told rather than guessing.
    """
    cleaned = re.sub(r"//.*", "", expr)
    cleaned = cleaned.replace("ULL", "").replace("UL", "").strip()

    if not re.fullmatch(r"[0-9a-fA-FxX()\s<|+]*", cleaned):
        raise ValueError(f"unexpected syntax in mask expression: {expr!r}")

    try:
        return int(eval(cleaned, {"__builtins__": {}}, {}))  # noqa: S307
    except Exception as exc:  # pragma: no cover
        raise ValueError(f"could not evaluate {expr!r}: {exc}") from exc


def mask_to_pins(mask: int, limit: int):
    return [p for p in range(limit) if (mask >> p) & 1]


def read_source(path: Path) -> str:
    """Read the rules file with C line-continuations joined.

    Several masks span lines with a trailing backslash, so every #define has to
    be collapsed onto one line before the per-key regexes can see all of it.
    """
    return re.sub(r"\\\s*\n\s*", " ", path.read_text())


def parse_rules(path: Path):
    # Only the mask table at the top. DSGV_pin_to_adc1_channel() further down
    # has its own per-target #if branches, which match the same pattern but
    # contain no PIN_LIMIT; parse_adc() handles those separately.
    src = read_source(path).split("int DSGV_pin_to_adc1_channel", 1)[0]

    # Each chip is one preprocessor branch keyed on CONFIG_IDF_TARGET_*.
    # Capture from a branch header up to the next one (or the #else).
    pattern = re.compile(
        r"#(?:el)?if\s+defined\(CONFIG_IDF_TARGET_(\w+)\)(.*?)(?=^#(?:el)?if\s|^#else)",
        re.DOTALL | re.MULTILINE,
    )

    chips = {}
    for target, body in pattern.findall(src):
        if target not in CHIP_FAMILY:
            continue

        limit_m = re.search(r"#\s*define\s+PIN_LIMIT\s+(\d+)", body)
        if not limit_m:
            raise ValueError(f"{target}: no PIN_LIMIT")
        limit = int(limit_m.group(1))

        masks = {}
        for key in MASK_KEYS:
            m = re.search(rf"#\s*define\s+{key}\s+(.+)", body)
            if not m:
                raise ValueError(f"{target}: no {key}")
            masks[key] = eval_mask(m.group(1))

        # ADC1 mapping lives in DSGV_pin_to_adc1_channel(), a separate switch
        # per chip. Extracted below rather than from the masks.
        chips[target] = {"pin_limit": limit, "masks": masks}

    missing = set(CHIP_FAMILY) - set(chips)
    if missing:
        raise ValueError(f"no rule block found for: {', '.join(sorted(missing))}")
    return chips


def parse_adc(path: Path):
    """Extract the GPIO -> ADC1 channel map for each chip."""
    src = read_source(path)
    fn = src.split("int DSGV_pin_to_adc1_channel", 1)
    if len(fn) < 2:
        raise ValueError("DSGV_pin_to_adc1_channel not found")
    body = fn[1]

    adc = {}
    for target in CHIP_FAMILY:
        # The branch for this chip, up to the next preprocessor directive.
        m = re.search(
            rf"#(?:el)?if\s+defined\(CONFIG_IDF_TARGET_{target}\)(.*?)(?=^#(?:el)?if\s|^#else)",
            body, re.DOTALL | re.MULTILINE)
        if not m:
            adc[target] = {}
            continue
        branch = m.group(1)

        mapping = {}
        # Explicit switch form, as used for ESP32.
        for pin, ch in re.findall(r"case\s+(\d+):\s*return\s+(\d+);", branch):
            mapping[int(pin)] = int(ch)
        # Range form: "if (pin >= A && pin <= B) return pin - C;"  / "return pin;"
        rng = re.search(
            r"if\s*\(pin\s*>=\s*(\d+)\s*&&\s*pin\s*<=\s*(\d+)\)\s*return\s+pin(?:\s*-\s*(\d+))?;",
            branch)
        if rng:
            lo, hi = int(rng.group(1)), int(rng.group(2))
            off = int(rng.group(3) or 0)
            for pin in range(lo, hi + 1):
                mapping[pin] = pin - off
        adc[target] = mapping

    return adc


def build(path: Path):
    chips = parse_rules(path)
    adc = parse_adc(path)

    out = {
        "_generated_by": "dsgv_firmware/tools/gen_chip_tables.py",
        "_source": "components/dsgv_common/gpio/dsgv_pin_rules.c",
        "_note": "Do not edit. Regenerate after changing the firmware pin rules.",
        "chips": {},
    }

    for target, data in sorted(chips.items()):
        limit = data["pin_limit"]
        m = data["masks"]

        unusable = m["M_NOT_EXIST"] | m["M_RESERVED"]
        usable = [p for p in range(limit) if not ((unusable >> p) & 1)]
        input_only = mask_to_pins(m["M_INPUT_ONLY"], limit)

        out["chips"][CHIP_FAMILY[target]] = {
            "idf_target": target.lower(),
            "pin_limit": limit,
            # Everything the UI may offer at all.
            "usable": usable,
            # Offerable for outputs: usable minus input-only.
            "output_capable": [p for p in usable if p not in input_only],
            "input_only": input_only,
            "not_exist": mask_to_pins(m["M_NOT_EXIST"], limit),
            "reserved": mask_to_pins(m["M_RESERVED"], limit),
            # Selectable, but the UI should warn.
            "strapping": mask_to_pins(m["M_STRAPPING"], limit),
            "console": mask_to_pins(m["M_CONSOLE"], limit),
            "usb": mask_to_pins(m["M_USB"], limit),
            "adc1": {str(p): c for p, c in sorted(adc.get(target, {}).items())},
        }

    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--rules", type=Path, default=RULES_C)
    ap.add_argument("--check", action="store_true",
                    help="fail if --out differs from freshly generated output")
    args = ap.parse_args()

    if not args.rules.is_file():
        sys.exit(f"pin rules not found: {args.rules}")

    generated = json.dumps(build(args.rules), indent=2) + "\n"

    if args.check:
        if not args.out.is_file():
            sys.exit(f"{args.out} does not exist; run without --check to create it")
        if args.out.read_text() != generated:
            sys.exit(
                f"{args.out} is out of date with {args.rules.name}.\n"
                f"Regenerate:  python3 dsgv_firmware/tools/gen_chip_tables.py "
                f"--out {args.out}"
            )
        print(f"{args.out}: up to date")
        return 0

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(generated)

    data = json.loads(generated)
    for family, c in data["chips"].items():
        print(f"{family:10s} {len(c['usable']):3d} usable, "
              f"{len(c['output_capable']):3d} output-capable, "
              f"{len(c['reserved']):2d} reserved, "
              f"{len(c['adc1']):2d} ADC1")
    return 0


if __name__ == "__main__":
    sys.exit(main())
