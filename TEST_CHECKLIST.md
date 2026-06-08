# DSGV Hub — Test Checklist

> **Purpose:** Step-by-step verification for all firmware and app features.
> Work through each section after any firmware flash or app build.
> Check each box as you go — leave notes in the "Result" column.
>
> **Last updated:** 2026-06-08
> **Covers commits up to:** `f5b3b00` (feat: WiFi recovery, AP captive portal, provisioning fallbacks)

---

## How to Use

1. Flash the latest firmware (`idf.py -p COMx erase-flash flash monitor`)
2. Install the latest APK (`flutter build apk --release` → `adb install`)
3. Work through sections in order — earlier sections are prerequisites for later ones
4. Mark `[ ]` → `[x]` as each item passes, or `[!]` if it fails with a note

---

## Section 1 — First Boot (Fresh Device)

> **Setup:** Full erase + flash. No Wi-Fi credentials in NVS.

- [ ] Device powers on — serial monitor shows `=== DSGV Hub Firmware vX.Y.Z Booting ===`
- [ ] BLE advertising starts — monitor shows `BLE advertising started: DSGVHub_XXXXXX`
- [ ] Pair code printed in monitor matches last 3 bytes of BT MAC
- [ ] Auth token printed (64 hex chars, 2 lines of 32)
- [ ] Device visible in phone Bluetooth scanner as `DSGVHub_XXXXXX`
- [ ] Device visible in nRF Connect or similar BLE scanner with the provisioning service UUID

**Result:**

---

## Section 2 — Standard QR Provisioning

> **Setup:** Fresh device in BLE advertising mode. QR code with `dsgv://provision?name=DSGVHub_XXXXXX` ready.

- [ ] App "Add Device" screen opens camera scanner
- [ ] QR code scans correctly — device name shown in scanner preview
- [ ] App connects to device via BLE automatically (no manual pairing in phone settings)
- [ ] Wi-Fi network list appears (populated from device scan) — shows nearby networks with signal bars
- [ ] Correct device type shown on the auto-detect card (e.g. "1-Gang Switch") with verified badge
- [ ] Enter device name → select Wi-Fi network → enter password → tap "Provision Device"
- [ ] Progress bar advances through all steps
- [ ] Status notification received: `success:<token>:<mac>` — app shows "Provisioned successfully!"
- [ ] Device reboots and reconnects to Wi-Fi — serial monitor shows `Got IP: 192.168.x.x`
- [ ] Device appears on dashboard within 30 seconds
- [ ] Device shows as "Online" with correct name and capabilities
- [ ] Relay toggle from app turns relay ON/OFF — confirmed physically
- [ ] Status LED mirrors relay state

**Result:**

---

## Section 3 — Provisioning Fallback: Manual Pair Code (Option 1)

> **Setup:** Fresh device in BLE advertising mode. Do NOT scan QR code.

- [ ] App "Add Device" screen shows "Can't scan the QR code?" section below scanner
- [ ] Tap "Enter pair code manually" — text field appears with `DSGVHub_` prefix
- [ ] Field only accepts hex characters (A-F, 0-9) — letters and numbers only
- [ ] Field rejects non-hex characters
- [ ] Type the 6-char code from the device label
- [ ] "Find" button is disabled with fewer than 6 characters, enabled at exactly 6
- [ ] Tap "Find" — app connects to the device via BLE (same flow as QR scan)
- [ ] Wi-Fi network list loads, device type auto-detected
- [ ] Complete provisioning — device appears on dashboard

**Result:**

---

## Section 4 — Provisioning Fallback: BLE Device Picker (Option 2)

> **Setup:** Fresh device in BLE advertising mode. Do NOT scan QR code or enter pair code.

- [ ] "Scan for nearby DSGV devices" button visible below the QR scanner
- [ ] Tap it — spinner appears while scanning
- [ ] After scan completes, device `DSGVHub_XXXXXX` appears in list
- [ ] If multiple DSGV devices nearby, all appear in the list
- [ ] Tap a device — app connects via BLE
- [ ] Provisioning flow proceeds identically to QR scan

**Result:**

---

## Section 5 — Wi-Fi Change (Device Online)

> **Setup:** Device is provisioned and shows as "Online" in the app.

- [ ] Open Device Settings for the provisioned device
- [ ] "Wi-Fi Network" section visible between "Power Restore" and "Device Info"
- [ ] SSID field and password field are present
- [ ] "Change Wi-Fi" button is disabled when SSID field is empty
- [ ] Enter a **valid** new SSID and password → tap "Change Wi-Fi"
- [ ] Button shows loading spinner
- [ ] Success message appears: "Change sent. Device will reboot and reconnect…"
- [ ] Device reboots — goes offline briefly (~10-30 s)
- [ ] Device comes back online on the new network
- [ ] Relay state is preserved after reconnect
- [ ] Power restore mode is preserved after reconnect

> **Negative test:** Enter an **invalid** password for a real network.
- [ ] Device goes offline and enters AP mode (`DSGV_Setup_*` visible in Wi-Fi scanner)
- [ ] Reconnect phone to the device AP, correct the credentials via browser form

**Result:**

---

## Section 6 — Wi-Fi Change (Device Offline, BLE re-provisioning)

> **Setup:** Device is provisioned but taken offline (disconnect from router, or power-cycle after changing router SSID).
> The device must have been provisioned with the current app version so the BLE name is stored.

- [ ] Device shows as "Offline" in the app dashboard
- [ ] Open Device Settings → "Wi-Fi Network" section
- [ ] Button shows "Reconnect via Bluetooth" (not "Change Wi-Fi")
- [ ] Description text mentions Bluetooth reconnection
- [ ] Enter new SSID + password → tap "Reconnect via Bluetooth"
- [ ] App shows BLE scanning/connecting progress
- [ ] Credentials are sent — device reboots
- [ ] Success message shown
- [ ] Reconnect phone to home Wi-Fi (if it disconnected)
- [ ] Device reappears as online on dashboard within 30 seconds
- [ ] All device config preserved (relay state, power restore, device name)

**Result:**

---

## Section 7 — AP Captive Portal Recovery (No App Required)

> **Setup:** Provision a device, then corrupt its Wi-Fi credentials by flashing a different SSID via the portal or typing a wrong password via Change Wi-Fi.

- [ ] Device fails to connect to Wi-Fi → serial monitor shows "Wi-Fi failed — Starting setup AP + captive portal"
- [ ] Wi-Fi scanner on phone shows `DSGV_Setup_XXXXXX` (open, no password)
- [ ] Connect phone to `DSGV_Setup_XXXXXX`

**Android:**
- [ ] "Sign in to network" notification appears automatically
- [ ] Tapping it opens the DSGV setup page in the browser

**iOS:**
- [ ] Browser or captive portal mini-window opens automatically
- [ ] OR navigate manually to `http://192.168.4.1`

**Windows/laptop:**
- [ ] Browser opens captive portal automatically OR navigate to `http://192.168.4.1`

**Form submission:**
- [ ] Setup page loads correctly — DSGV dark theme, SSID + password fields
- [ ] Enter correct Wi-Fi credentials → tap "Connect Device"
- [ ] Success page appears: "Credentials saved!"
- [ ] Device reboots and connects to the correct network
- [ ] Device appears online in app
- [ ] All config preserved (relay state, etc.)

**Result:**

---

## Section 8 — Factory Reset (Wall Switch)

> **Setup:** Provisioned device connected to Wi-Fi.

- [ ] Flip the wall switch rapidly 5 times within 3 seconds
- [ ] Serial monitor shows: `Factory reset triggered (5 toggles in 3000 ms)`
- [ ] Device reboots and enters BLE provisioning mode
- [ ] Device no longer appears online in app (offline or disappears)

**Accidental reset prevention:**
- [ ] Flip the switch 5 times, but spread over 5-6 seconds (slower than 3 s) → **no** reset
- [ ] Flip the switch 3-4 times rapidly → **no** reset (not enough count)

**Result:**

---

## Section 9 — Power Restore Mode

> **Setup:** Provisioned device online. Test each mode in sequence.

### Mode: Always OFF (default)
- [ ] Set power restore to "Always OFF" in Device Settings
- [ ] Turn relay ON via app
- [ ] Power-cycle the device (unplug + replug)
- [ ] Relay stays OFF after boot — confirmed physically

### Mode: Restore last state
- [ ] Set power restore to "Restore last state"
- [ ] Turn relay ON via app → power-cycle
- [ ] Relay turns ON after boot
- [ ] Turn relay OFF via app → power-cycle
- [ ] Relay stays OFF after boot

### Mode: Always ON
- [ ] Set power restore to "Always ON"
- [ ] Turn relay OFF via app → power-cycle
- [ ] Relay turns ON automatically after boot

**Result:**

---

## Section 10 — MQTT Telemetry and Commands

> **Setup:** Device online. Use MQTT Explorer to inspect raw traffic.

- [ ] Subscribe to `devices/#` in MQTT Explorer
- [ ] `devices/{id}/announce` received on device boot — contains `device_id`, `name`, `capabilities`, `local_ip`, `firmware`, `status`
- [ ] `devices/{id}/status` = `"online"` retained on broker
- [ ] `devices/{id}/telemetry` published every 30 seconds
- [ ] Telemetry contains: `power`, `power_2` (if multi-gang), `current_temp`, `humidity`, `power_restore`
- [ ] Publish `{"power":true}` to `devices/{id}/command` → relay turns ON
- [ ] Publish `{"power":false}` → relay turns OFF
- [ ] Power toggle from app is reflected in telemetry within 1 second
- [ ] When device is disconnected, `devices/{id}/status` = `"offline"` within ~22 seconds (1.5× keepalive)

**Result:**

---

## Section 11 — Local HTTP Control (Same LAN)

> **Setup:** Phone on same Wi-Fi as device. Device IP visible in Device Settings.

- [ ] `GET http://{device_ip}/api/status` returns JSON with current state
- [ ] `POST http://{device_ip}/api/cmd` with `{"capability":"power","value":true}` turns relay ON
- [ ] App uses local HTTP automatically when on same LAN (faster than MQTT)
- [ ] Tasmota compatibility: `GET http://{ip}/cm?cmnd=Power%20ON` turns relay ON
- [ ] Tasmota `Power OFF` turns relay OFF
- [ ] Tasmota `Dimmer 50` sets brightness (dimmer device only)

**Result:**

---

## Section 12 — OTA Firmware Update

> **Setup:** Device online. A valid firmware `.bin` hosted at a known HTTPS URL.

- [ ] App → Device Settings → OTA section (or MQTT trigger)
- [ ] Publish OTA trigger to `devices/{id}/ota-trigger`:
  ```json
  {"url":"https://your-server.com/firmware.bin","hash":"sha256-of-binary"}
  ```
- [ ] Device downloads firmware — serial monitor shows download progress percentage
- [ ] SHA-256 hash verification passes
- [ ] Device reboots into new firmware
- [ ] New version shown in announce payload
- [ ] All config preserved after OTA

**Result:**

---

## Section 13 — Multi-Gang Switch (2/3/4-Gang)

> **Setup:** Flash 2/3/4-gang switch firmware variant.

- [ ] All gangs appear as separate toggles in the app UI
- [ ] Each gang toggles independently
- [ ] Each gang's physical switch works independently
- [ ] Telemetry contains `power`, `power_2`, `power_3`, `power_4` fields correctly
- [ ] Power restore mode applies to all gangs (bitmask preserved in NVS)

**Result:**

---

## Section 14 — Device Rename

> **Setup:** Any provisioned device.

- [ ] Open Device Settings → enter a custom name → tap Save
- [ ] Dashboard shows the custom name
- [ ] MQTT announce message with firmware-generated name does NOT overwrite the custom name
- [ ] Custom name persists across app restarts
- [ ] Clear the name field → tap Save → auto-generated name is restored

**Result:**

---

## Section 15 — App Connectivity (MQTT)

> **Setup:** App installed, no devices provisioned yet.

- [ ] App opens → Settings tab → connection status shows "Connecting…" then "Connected · Manufacturer Server"
- [ ] Disconnect from internet → status shows "Disconnected" with friendly error message
- [ ] Reconnect → app auto-reconnects without user action
- [ ] Switch to custom broker → enter valid host/port/TLS → Save & Connect → status updates
- [ ] Switch back to Manufacturer → status shows manufacturer server

**Result:**

---

## Section 16 — Regression: Normal Usage Not Triggering Reset

> **Setup:** Provisioned device in normal use.

- [ ] Toggle switch ON and OFF 10 times slowly (2+ seconds between each flip) → no reset
- [ ] Toggle switch 5 times with 1+ second between each flip → no reset
- [ ] Use the switch normally for 5 minutes — no unexpected reboots

**Result:**

---

## Known Limitations (Do Not Mark as Failures)

| Limitation | Notes |
|---|---|
| iOS captive portal sometimes requires manual navigation to 192.168.4.1 | iOS behaviour varies by version; not a firmware bug |
| BLE device picker may miss devices with weak signal | Move the phone closer to the device |
| Change Wi-Fi offline path requires BLE name to be stored from first provisioning | Devices provisioned before app v2.x will fall back to AP mode instructions |
| MQTT wifi_ssid command requires device to currently be connected | By definition — if offline use BLE or AP portal instead |
| OTA requires a reachable HTTPS server with a valid certificate | Self-signed certs not supported in the current TLS config |

---

## Sign-Off

| Tester | Date | Firmware version | App version | Notes |
|---|---|---|---|---|
| | | | | |
| | | | | |

---

*Generated: 2026-06-08 — covers all changes through commit f5b3b00*
