# DSGV Web Flasher

Flash and configure an ESP32 from a browser. No toolchain, no compilation —
the firmware is prebuilt per chip and your choices are written to the device
as settings.

## How it works

Nothing is compiled per user, because nothing needs to be. The firmware is one
universal image per chip; device type, capabilities and every GPIO are runtime
configuration held in NVS. Choosing "3-gang switch with relays on 2, 3, 4" is a
JSON payload, not a build.

```
  browser                                   device
  ───────                                   ──────
  1. Web Serial: pick port
  2. esptool-js: identify chip      ──────▶  (download mode)
  3. fetch manifest + binaries
  4. write flash at manifest offsets ─────▶  (written, reset)
  5. reopen port at 115200
  6. SET_CONFIG frame                ─────▶  parsed, validated, saved to NVS
  7. compare echo against request    ◀─────  config that actually took effect
```

Step 7 is the part that matters: the device echoes what it stored, and the
flasher diffs it against what was asked for. A pin the firmware refused shows
up as a warning rather than as a board that quietly does the wrong thing.

## Running it

A static site — no build step, no bundler.

### Hosted

Pushes to `main` publish the site to GitHub Pages automatically. The deploy
job assembles `catalog/`, the flasher, and the firmware for all four chips,
then checks that every path named in the manifest actually exists before
publishing — a missing binary would otherwise appear as a 404 partway through
a flash, with the board already erased.

This needs Pages enabled once, by hand: **Settings → Pages → Source →
GitHub Actions**. Until that is done the deploy job fails with a permissions
error; nothing else in the workflow is affected.

### Locally

Serve the repository root so `catalog/` and `webflasher/` are both reachable:

```bash
python3 -m http.server 8000
# http://localhost:8000/webflasher/
```

Web Serial needs a secure context, which `localhost` satisfies. Any other host
needs HTTPS.

Local runs have no firmware — the binaries are build artifacts, not
repository contents. Download the `universal-*` and `manifest` artifacts from
a green **Firmware Build** run and unpack them to match the manifest's
per-chip paths:

```
webflasher/firmware/
├── manifest.json
├── esp32/{bootloader,partition-table,ota_data_initial,dsgv_universal}.bin
├── esp32c3/…
├── esp32s3/…
└── esp32c6/…
```

The per-chip directories are not cosmetic: every target emits files with the
same names, so a flat layout silently leaves all four chips pointing at
whichever was copied last.

## Browser support

Web Serial, so:

| Browser | Status |
| --- | --- |
| Chrome / Edge, desktop | Supported |
| Firefox 151+, desktop | Supported |
| Chrome, Android | Partial, depends on version — treat as best effort |
| **Safari, and everything on iOS/iPadOS** | **Not supported, and cannot be** |

iOS has no Web Serial and no WebUSB in any browser, including Chrome and
Firefox for iOS, which are Safari underneath. There is no polyfill. The page
detects this and says so rather than failing at connect time.

## What is tested, and what is not

Verified in CI on every push:

- Frame encoding and decoding, including recovery from interleaved boot-log
  output and rejection of a log line that merely contains the magic
- Pin validation against every chip: flash pins, input-only pins, absent pins,
  ADC-capable pins
- Payload construction, including that unfitted relay gangs keep their index
  position
- That the JS and Python framing implementations produce identical bytes

Not verified automatically, because it needs a board:

- Web Serial connection and port handover between esptool-js and the config
  session
- Actual flashing at the manifest offsets
- The firmware's serial listener responding to a real frame

The firmware half of the serial protocol has never run on hardware. Before
trusting the flasher end to end, check it with the host tool, which speaks the
same protocol:

```bash
pip install pyserial
dsgv_firmware/tools/dsgv_serial_config.py /dev/ttyUSB0 info
dsgv_firmware/tools/dsgv_serial_config.py /dev/ttyUSB0 get
```

If `info` answers, the device side works and the browser path is the only
remaining unknown.

## Layout

```
webflasher/
├── index.html              markup and styling
├── app.js                  UI orchestration; holds no rules of its own
├── lib/
│   ├── dsgv-frame.js       serial framing — tested
│   ├── config-builder.js   pin validation and payload shape — tested
│   └── flasher.js          Web Serial + esptool-js glue — not unit-testable
└── test/
    ├── frame.test.mjs
    ├── config.test.mjs
    └── cross_check_frames.py
```

Pin rules come from `catalog/chips.json`, generated from
`dsgv_firmware/components/dsgv_common/gpio/dsgv_pin_rules.c`. Device shapes
come from `catalog/devices.json`. Flash offsets come from `manifest.json`,
generated from each build's `flash_args`. None of the three is duplicated here,
so the browser cannot disagree with the firmware about what is valid.

## Adding a device

Add an entry to `catalog/devices.json` and it appears in the dropdown. No
firmware change, no rebuild — `validate_catalog.py` checks it against the
firmware's real constraints in CI.
