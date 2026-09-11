#!/usr/bin/env python3
"""
Host-side client for the DSGV serial config protocol.

The firmware side cannot be exercised in CI — it needs a real chip on a real
port — so this exists to make Phase 2 verifiable by hand, and to serve as the
reference implementation the browser flasher's JS is ported from.

Usage:
    ./dsgv_serial_config.py /dev/ttyUSB0 info
    ./dsgv_serial_config.py /dev/ttyUSB0 get
    ./dsgv_serial_config.py /dev/ttyUSB0 set config.json
    ./dsgv_serial_config.py /dev/ttyUSB0 set - <<'EOF'
    {"device_type":"Switch","capabilities":["relay"],"relay_count":1,
     "pins":{"relay":[2],"switch":[9]}}
    EOF
    ./dsgv_serial_config.py /dev/ttyUSB0 restart

Requires pyserial:  pip install pyserial
"""

import argparse
import json
import sys
import time

try:
    import serial  # type: ignore
except ImportError:
    sys.exit("pyserial is required:  pip install pyserial")

MAGIC = b"DSGV"
VERSION = 1
HEADER_LEN = 8
MAX_PAYLOAD = 1024

REQUEST_INFO = 0x01
SET_CONFIG = 0x02
GET_CONFIG = 0x03
RESTART = 0x04
RESPONSE_OK = 0x81
RESPONSE_ERR = 0x82


def build_frame(msg_type: int, payload: bytes = b"") -> bytes:
    if len(payload) > MAX_PAYLOAD:
        raise ValueError(f"payload {len(payload)} exceeds {MAX_PAYLOAD}")
    header = MAGIC + bytes(
        [VERSION, msg_type, (len(payload) >> 8) & 0xFF, len(payload) & 0xFF]
    )
    checksum = (sum(header) + sum(payload)) & 0xFF
    return header + payload + bytes([checksum, 0x0A])


def read_frame(port: "serial.Serial", timeout: float = 5.0):
    """Scan for a valid frame, discarding interleaved log output."""
    deadline = time.time() + timeout
    window = bytearray()

    while time.time() < deadline:
        chunk = port.read(1)
        if not chunk:
            continue
        window += chunk

        # Keep only from the last plausible magic start onward.
        idx = window.find(MAGIC)
        if idx < 0:
            if len(window) > len(MAGIC):
                del window[: -len(MAGIC)]
            continue
        if idx > 0:
            del window[:idx]

        if len(window) < HEADER_LEN:
            continue

        plen = (window[6] << 8) | window[7]
        if plen > MAX_PAYLOAD:
            del window[:1]           # false magic inside log text; move on
            continue

        total = HEADER_LEN + plen + 2
        if len(window) < total:
            continue

        frame = bytes(window[:total])
        del window[:total]

        expected = sum(frame[: total - 2]) & 0xFF
        if frame[total - 2] != expected:
            raise IOError(
                f"checksum mismatch: got {frame[total - 2]:#04x}, "
                f"expected {expected:#04x}"
            )
        if frame[total - 1] != 0x0A:
            raise IOError("frame not newline-terminated")

        return frame[5], frame[HEADER_LEN : HEADER_LEN + plen]

    raise TimeoutError("no frame received — is the device running DSGV firmware?")


def transact(port, msg_type, payload=b""):
    port.reset_input_buffer()
    port.write(build_frame(msg_type, payload))
    port.flush()

    resp_type, body = read_frame(port)
    if resp_type == RESPONSE_ERR:
        sys.exit(f"device error: {body.decode('utf-8', 'replace')}")
    if resp_type != RESPONSE_OK:
        sys.exit(f"unexpected response type {resp_type:#04x}")
    return body


def show(body: bytes):
    if not body:
        print("ok")
        return
    try:
        print(json.dumps(json.loads(body), indent=2))
    except json.JSONDecodeError:
        print(body.decode("utf-8", "replace"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", help="serial device, e.g. /dev/ttyUSB0 or COM5")
    ap.add_argument("command", choices=["info", "get", "set", "restart"])
    ap.add_argument("file", nargs="?",
                    help="JSON file for 'set', or - to read stdin")
    ap.add_argument("--baud", type=int, default=115200)
    args = ap.parse_args()

    if args.command == "set" and not args.file:
        ap.error("'set' needs a JSON file (or - for stdin)")

    payload = b""
    if args.command == "set":
        raw = sys.stdin.read() if args.file == "-" else open(args.file).read()
        payload = json.dumps(json.loads(raw)).encode()   # validate before sending

    with serial.Serial(args.port, args.baud, timeout=0.2) as port:
        # The device may still be booting; its own log output is harmless here.
        time.sleep(0.3)

        if args.command == "info":
            show(transact(port, REQUEST_INFO))
        elif args.command == "get":
            show(transact(port, GET_CONFIG))
        elif args.command == "set":
            print("applied config:")
            show(transact(port, SET_CONFIG, payload))
        elif args.command == "restart":
            transact(port, RESTART)
            print("restarting")

    return 0


if __name__ == "__main__":
    sys.exit(main())
