#!/usr/bin/env python3
"""
Assert the JS and Python framing implementations produce identical bytes.

Three implementations speak this protocol: the firmware
(components/dsgv_common/serial/dsgv_serial_config.c), the Python host tool,
and the browser flasher. The firmware is the one that matters, but it cannot
run in CI — so the next best guarantee is that the two host implementations
never drift from each other, since they were both written against it.

A mismatch here means one of them is sending frames the device will reject,
which on the browser side surfaces as an inexplicable "bad checksum" during
setup.
"""

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PY_TOOL = ROOT / "dsgv_firmware/tools/dsgv_serial_config.py"
JS_LIB = ROOT / "webflasher/lib/dsgv-frame.js"


def load_py_tool():
    # The tool imports pyserial at module scope for its CLI; stub it so the
    # pure framing functions can be imported without the dependency.
    sys.modules.setdefault("serial", type(sys)("serial"))
    spec = importlib.util.spec_from_file_location("dsgv_tool", PY_TOOL)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    for path in (PY_TOOL, JS_LIB):
        if not path.is_file():
            sys.exit(f"missing {path.relative_to(ROOT)}")

    m = load_py_tool()

    big_config = json.dumps({
        "device_type": "Switch",
        "capabilities": ["relay", "relay_2", "relay_3", "relay_4"],
        "relay_count": 4,
        "pins": {
            "relay": [2, 3, 4, 5],
            "switch": [9, 18, 19, 21],
            "dimmer": -1, "warm": -1, "cool": -1,
            "red": -1, "green": -1, "blue": -1,
            "status_led": 8, "motion": -1, "contact": -1,
            "button": 9, "adc_temp": 1,
        },
    }).encode()

    cases = [
        (m.REQUEST_INFO, b""),
        (m.GET_CONFIG,   b""),
        (m.RESTART,      b""),
        (m.SET_CONFIG,   b'{"relay_count":0}'),
        (m.SET_CONFIG,   big_config),
        (m.SET_CONFIG,   b"\x00\x01\xfe\xff"),          # non-UTF8 bytes
        (m.SET_CONFIG,   b"x" * m.MAX_PAYLOAD),         # exactly at the limit
    ]

    expected = [
        {"type": t, "payload": list(p), "frame": list(m.build_frame(t, p))}
        for t, p in cases
    ]

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(expected, fh)
        fixture = fh.name

    script = f"""
    import {{ readFileSync }} from 'node:fs';
    const {{ encodeFrame }} = await import({str(JS_LIB)!r});
    const cases = JSON.parse(readFileSync({fixture!r}, 'utf8'));
    let bad = 0;
    for (const c of cases) {{
      const js = [...encodeFrame(c.type, Uint8Array.from(c.payload))];
      const same = js.length === c.frame.length && js.every((b, i) => b === c.frame[i]);
      if (!same) {{
        bad++;
        console.error(`MISMATCH type=0x${{c.type.toString(16)}} len=${{c.payload.length}}`);
        console.error(`  python: ${{c.frame.slice(0, 12).join(',')}}…`);
        console.error(`  js:     ${{js.slice(0, 12).join(',')}}…`);
      }}
    }}
    console.log(`${{cases.length - bad}}/${{cases.length}} frames identical`);
    process.exit(bad ? 1 : 0);
    """

    result = subprocess.run(
        ["node", "--input-type=module", "-e", script],
        capture_output=True, text=True,
    )
    Path(fixture).unlink(missing_ok=True)

    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
