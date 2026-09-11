#!/usr/bin/env python3
"""
Validate catalog/devices.json against the firmware's real constraints.

The catalogue is meant to be extended by editing JSON, with no rebuild. That
only stays safe if something checks the JSON, because a bad entry does not
fail to compile — it reaches a user's board and misconfigures it. This runs in
CI on every change.

Checks:
  - ids unique, required fields present and well typed
  - relay_count within DSGV_MAX_RELAY_COUNT, and consistent with the number of
    relay pin roles and with the relay_N capability names
  - every pin role is one the firmware actually parses
  - per-gang roles index within relay_count and without gaps or duplicates
  - every capability is one the firmware gates on
  - each device is satisfiable on at least one chip, given chips.json
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
DEVICES = ROOT / "catalog/devices.json"
CHIPS = ROOT / "catalog/chips.json"

# Must match the k_pin_fields table and the array handling in
# components/dsgv_common/config/dsgv_config_json.c.
SCALAR_ROLES = {"dimmer", "warm", "cool", "red", "green", "blue",
                "status_led", "motion", "contact", "button", "adc_temp"}
ARRAY_ROLES = {"relay", "switch"}
ALL_ROLES = SCALAR_ROLES | ARRAY_ROLES

# Must match DSGV_capabilities_refresh() in dsgv_device_config.c. relay_2..4
# are accepted because the app uses them as per-gang command names, even though
# the firmware derives gang count from relay_count.
CAPABILITIES = {"relay", "relay_2", "relay_3", "relay_4", "brightness",
                "color_temp", "rgb", "temperature", "humidity", "motion",
                "contact", "hvac_mode"}

# DSGV_MAX_RELAY_COUNT in dsgv_device_config.h.
MAX_RELAYS = 4

DIRECTIONS = {"output", "input", "adc"}

errors: list[str] = []
warnings: list[str] = []


def err(dev, msg):
    errors.append(f"{dev}: {msg}")


def warn(dev, msg):
    warnings.append(f"{dev}: {msg}")


def check_device(d, chips):
    did = d.get("id", "<no id>")

    for field in ("id", "name", "device_type", "capabilities",
                  "relay_count", "pin_roles"):
        if field not in d:
            err(did, f"missing required field '{field}'")
            return

    rc = d["relay_count"]
    if not isinstance(rc, int) or not 0 <= rc <= MAX_RELAYS:
        err(did, f"relay_count {rc!r} outside 0..{MAX_RELAYS}")
        return

    for cap in d["capabilities"]:
        if cap not in CAPABILITIES:
            err(did, f"capability '{cap}' is not one the firmware recognises")

    # relay_N capability names must line up with relay_count, or the app will
    # render controls for gangs the firmware will not drive.
    for n in range(2, MAX_RELAYS + 1):
        named = f"relay_{n}" in d["capabilities"]
        if named and rc < n:
            err(did, f"declares '{relay_n}' but relay_count is {rc}"
                     .replace("relay_n", f"relay_{n}"))
        if not named and rc >= n:
            warn(did, f"relay_count is {rc} but 'relay_{n}' is not declared; "
                      f"the app will not show a control for gang {n}")
    if rc >= 1 and "relay" not in d["capabilities"]:
        err(did, f"relay_count is {rc} but 'relay' is not declared")

    seen = {}
    for role_def in d["pin_roles"]:
        role = role_def.get("role")
        if role not in ALL_ROLES:
            err(did, f"pin role '{role}' is not parsed by the firmware")
            continue

        direction = role_def.get("direction")
        if direction not in DIRECTIONS:
            err(did, f"role '{role}' has direction {direction!r}, "
                     f"expected one of {sorted(DIRECTIONS)}")

        if role in ARRAY_ROLES:
            idx = role_def.get("index")
            if not isinstance(idx, int):
                err(did, f"role '{role}' needs an integer index")
                continue
            if idx >= rc:
                err(did, f"role '{role}' index {idx} but relay_count is {rc}")
            key = (role, idx)
        else:
            if "index" in role_def:
                err(did, f"role '{role}' is scalar and must not carry an index")
            key = (role, None)

        if key in seen:
            err(did, f"role '{role}' declared more than once")
        seen[key] = role_def

    # Per-gang roles must be contiguous from 0, else gang 2 silently has no pin.
    for arr_role in ARRAY_ROLES:
        idxs = sorted(i for (r, i) in seen if r == arr_role and i is not None)
        if idxs and idxs != list(range(len(idxs))):
            err(did, f"'{arr_role}' indices {idxs} are not contiguous from 0")
    relay_idxs = [i for (r, i) in seen if r == "relay"]
    if len(relay_idxs) != rc:
        err(did, f"relay_count is {rc} but {len(relay_idxs)} relay pin role(s) declared")

    # Satisfiability: enough distinct pins of the right kind on some chip.
    need_out = sum(1 for rd in d["pin_roles"] if rd.get("direction") == "output")
    need_in = sum(1 for rd in d["pin_roles"] if rd.get("direction") == "input")
    need_adc = sum(1 for rd in d["pin_roles"] if rd.get("direction") == "adc")

    ok_on = []
    for family, c in chips["chips"].items():
        if len(c["output_capable"]) < need_out:
            continue
        if len(c["usable"]) < need_out + need_in + need_adc:
            continue
        if need_adc > len(c["adc1"]):
            continue
        ok_on.append(family)

    if not ok_on:
        err(did, f"needs {need_out} output, {need_in} input, {need_adc} ADC "
                 f"pins — no supported chip has that many")
    elif len(ok_on) < len(chips["chips"]):
        missing = sorted(set(chips["chips"]) - set(ok_on))
        warn(did, f"not placeable on {', '.join(missing)}")


def main() -> int:
    for path in (DEVICES, CHIPS):
        if not path.is_file():
            sys.exit(f"missing {path.relative_to(ROOT)}")

    devices = json.loads(DEVICES.read_text())
    chips = json.loads(CHIPS.read_text())

    ids = [d.get("id") for d in devices["devices"]]
    for dup in {i for i in ids if ids.count(i) > 1}:
        errors.append(f"duplicate device id '{dup}'")

    for d in devices["devices"]:
        check_device(d, chips)

    for w in warnings:
        print(f"warning: {w}")
    for e in errors:
        print(f"ERROR:   {e}", file=sys.stderr)

    n = len(devices["devices"])
    families = ", ".join(sorted(chips["chips"]))
    if errors:
        print(f"\n{len(errors)} error(s) in {n} device(s)", file=sys.stderr)
        return 1

    print(f"\ncatalogue ok: {n} devices, chips: {families}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
