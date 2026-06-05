# DSGV Hub — BLE Provisioning Protocol & Firmware Fix Reference

> **Scope:** Documents the BLE provisioning implementation, all reliability fixes applied
> during hardware testing on the ESP32 WROOM, and the flash/build command reference.
>
> **Firmware:** ESP-IDF v6.0.1 · NimBLE BLE stack · Target: `esp32`
> **App:** Flutter · `flutter_blue_plus v1.35.5`

---

## Table of Contents

1. [Hardware Note — ESP32 WROOM vs C3](#1-hardware-note--esp32-wroom-vs-c3)
2. [BLE GATT Service Layout](#2-ble-gatt-service-layout)
3. [Advertisement Structure](#3-advertisement-structure)
4. [Provisioning Flow — Step by Step](#4-provisioning-flow--step-by-step)
5. [Device Identity — Auto-Detection Design](#5-device-identity--auto-detection-design)
6. [Wi-Fi Network Scan — How It Works](#6-wi-fi-network-scan--how-it-works)
7. [Firmware Fixes Applied](#7-firmware-fixes-applied)
8. [App Changes Applied](#8-app-changes-applied)
9. [Build & Flash Reference](#9-build--flash-reference)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Hardware Note — ESP32 WROOM vs C3

The DSGV Hub uses an **ESP32 WROOM** module (classic dual-core Xtensa, 4 MB flash).
This is **not** the same chip as the ESP32-C3 (single-core RISC-V).

| | ESP32 WROOM | ESP32-C3 |
|---|---|---|
| `IDF_TARGET` | `esp32` | `esp32c3` |
| Bluetooth controller | Dual-mode (BT Classic + BLE) | BLE-only |
| NimBLE config required | `CONFIG_BTDM_CTRL_MODE_BLE_ONLY=y` | Not needed |
| Cores | 2 × Xtensa LX6 | 1 × RISC-V |

**Why this matters:** Setting the wrong `IDF_TARGET` produces a broken binary that will not
boot. Setting it correctly but omitting `BTDM_CTRL_MODE_BLE_ONLY` means NimBLE cannot claim
the dual-mode controller and BLE advertising never starts.

Both settings are locked in:
- `dsgv_firmware/devices/1gang_switch/CMakeLists.txt` → `set(IDF_TARGET "esp32")`
- `dsgv_firmware/sdkconfig.defaults` → `CONFIG_BTDM_CTRL_MODE_BLE_ONLY=y`

---

## 2. BLE GATT Service Layout

All provisioning happens over a single custom GATT service.

**Service UUID:** `4fafc201-1fb5-459e-8fcc-c5c9c331914b`

| Characteristic | UUID | Properties | Payload |
|---|---|---|---|
| **Credentials** | `beb5483e-36e1-4688-b7f5-ea07361b26a8` | Write | `{"ssid":"MyNetwork","password":"secret"}` |
| **Status** | `beb5483f-36e1-4688-b7f5-ea07361b26a8` | Read + Notify | `success:<32-hex-token>:<12-hex-mac>` or `failed:<reason>` |
| **Wi-Fi Scan** | `beb5483d-36e1-4688-b7f5-ea07361b26a8` | Read | `[{"ssid":"Network","rssi":-45},...]` |
| **Device Info** | `beb5483c-36e1-4688-b7f5-ea07361b26a8` | Read | `{"device_type":"Switch","capabilities":["relay"],"relay_count":1}` |

### UUID byte ordering (NimBLE)

NimBLE stores 128-bit UUIDs in **little-endian** order — the bytes are reversed when
written in `BLE_UUID128_INIT(...)`. For example, `beb5483d-36e1-4688-b7f5-ea07361b26a8`
is declared as:

```c
static const ble_uuid128_t s_wifi_scan_uuid = BLE_UUID128_INIT(
    0xa8, 0x26, 0x1b, 0x36, 0x07, 0xea, 0xf5, 0xb7,
    0x88, 0x46, 0xe1, 0x36, 0x3d, 0x48, 0xb5, 0xbe
);
```

The Flutter app uses the standard human-readable form (big-endian) — these resolve to the
same characteristic.

---

## 3. Advertisement Structure

```
Primary advertisement (31-byte limit):
  ├── Flags: LE General Discoverable + BR/EDR Unsupported
  └── Complete 128-bit Service UUID: 4fafc201-...

Scan response:
  └── Complete Local Name: "DSGVHub_6B4442"   ← last 3 bytes of BT MAC
```

**Why service UUID must be in the primary advertisement (not scan response):**

Flutter's `FlutterBluePlus.startScan(withServices: [...])` and iOS CoreBluetooth both
filter scan results by checking the **primary advertisement packet** only. If the service
UUID is only in the scan response, the phone never includes the device in filtered scan
results — the app shows "Device not found" even though the device is advertising correctly.

The device name is moved to the scan response because it is only used for display purposes,
and scan responses are retrieved when the app explicitly connects.

---

## 4. Provisioning Flow — Step by Step

```
ESP32 (no NVS credentials)                Flutter App
        |                                       |
        |── Boot → GPIO init ─────────────────▶|
        |── Wi-Fi scan (blocking ~2 s) ────────▶|   networks cached in RAM
        |── BLE advertising starts ────────────▶|
        |                                       |
        |                        User scans QR  |
        |                   dsgv://provision?   |
        |                   name=DSGVHub_6B4442 |
        |                                       |── _loadProvisioningData()
        |◀─────────────────── BLE connect ──────|
        |◀─────────────── requestMtu(512) ──────|   allows large JSON reads
        |◀──────────── discoverServices() ──────|
        |                                       |── Future.wait([
        |◀──── read Wi-Fi Scan char ────────────|     wifiChar.read(),
        |◀──── read Device Info char ───────────|     infoChar.read()
        |                                       |   ])
        |──────────────── disconnect ──────────▶|
        |                                       |
        |                        App displays:  |
        |                        • Device type (read-only, from firmware)
        |                        • Wi-Fi network picker (from scan results)
        |                        • Password field
        |                                       |
        |                        User taps "Provision"
        |                                       |── _runBleProvisioning()
        |◀─────────────────── BLE connect ──────|
        |◀────────── subscribe to Status ───────|   before writing creds!
        |◀──── write Credentials char ──────────|   {"ssid":"...","password":"..."}
        |                                       |
        |── Connect to Wi-Fi ──────────────────▶|
        |── Notify Status: "success:<token>:<mac>"
        |──────────────────────────────────────▶|── registerDevice(mac, token)
        |                                       |── Navigator.pop()
        |── Reboot ─────────────────────────────|
        |── HTTP server starts ─────────────────|
        |── MQTT connect (background task) ─────|
```

### Status notification format

```
success:<32-hex-token>:<12-hex-wifi-mac>
  └── token: 32-char hex auth token for MQTT broker config commands
  └── mac:   Wi-Fi MAC (becomes the permanent device_id for MQTT topics)

failed:<reason>
  └── reason: human-readable string shown in app error message
```

---

## 5. Device Identity — Auto-Detection Design

### Why the app no longer has a device type dropdown

In early versions the app showed a dropdown letting the user pick from 11 device types
(1-gang switch, dimmer, RGB light, thermostat, etc.) before provisioning.

**This was wrong for a commercial product for three reasons:**

1. **Error source** — if the user picks the wrong type, the device registers with incorrect
   capabilities. The real type is already baked into the firmware at the factory.

2. **User confusion** — end users should not need to know the internal capability model.
   They scan a box, name it, enter a password. That is all.

3. **Unnecessary round-trip** — the device already knows what it is. Reading that back over
   BLE is free.

### How it works now

The device exposes a **Device Info** GATT characteristic (read-only) that returns:

```json
{
  "device_type": "Switch",
  "capabilities": ["relay"],
  "relay_count": 1
}
```

The app reads this before the provisioning form is shown and derives a human-readable label
and icon automatically:

| Capabilities | Label shown in app | Icon |
|---|---|---|
| `["relay"]` | 1-Gang Switch | power plug |
| `["relay","relay_2"]` | 2-Gang Switch | power plug |
| `["relay","brightness"]` | Dimmable Light | light mode |
| `["relay","brightness","color_temp"]` | Colour Temp Light | light mode |
| `["relay","brightness","rgb"]` | RGB Light | light mode |
| `["temperature","hvac_mode"]` | Thermostat | thermostat |
| `["motion"]` | Motion Sensor | sensors |
| `["contact"]` | Contact Sensor | sensor door |

The app shows this as a read-only card with a verified badge — the user sees exactly what
device they are provisioning, with no opportunity to set it incorrectly.

---

## 6. Wi-Fi Network Scan — How It Works

### On the device (firmware)

`wifi_manager_scan_networks()` is called in `DSGV_provisioning_start()` **before** NimBLE
starts. The scan is blocking (~2 seconds) and runs while the BLE stack is not yet active,
avoiding coexistence issues.

Results are cached in `s_wifi_scan_json[]` (static buffer, 1024 bytes). When the app reads
the Wi-Fi Scan characteristic, the cached JSON is returned instantly — no scan on demand,
no waiting.

Output format (sorted by RSSI, hidden SSIDs omitted, duplicates removed, SSID JSON-escaped):

```json
[
  {"ssid": "HomeNetwork", "rssi": -45},
  {"ssid": "Office WiFi", "rssi": -67},
  {"ssid": "Neighbour_5G", "rssi": -81}
]
```

### On the app side

The app reads the Wi-Fi Scan characteristic during `fetchProvisioningData()` alongside the
Device Info read (`Future.wait` — both happen in parallel in the same BLE connection).

The provisioning screen shows a dropdown of available networks. Signal strength is indicated
by the Wi-Fi icon colour:

| RSSI | Signal Level | Colour |
|---|---|---|
| ≥ −55 dBm | Excellent (3) | Green |
| ≥ −67 dBm | Good (2) | Light green |
| ≥ −78 dBm | Fair (1) | Orange |
| < −78 dBm | Weak (0) | Red |

If the scan returned no results (scan failed or all networks hidden), the app falls back to
a plain text field. The user can also tap "Type manually" at any time to override the picker.

---

## 7. Firmware Fixes Applied

### Fix 1 — Boot crash: `assert failed: xQueueSemaphoreTake` on NULL mutex

**Root cause:** `g_state_mutex` was created inside `DSGV_mqtt_start()` (step 6 of boot).
`DSGV_gpio_init()` (step 3) spawned `sensor_task`, which immediately called `STATE_LOCK()`
— before the mutex existed.

**Fix:** Create `g_state_mutex` in `dsgv_app_main.c` before `DSGV_gpio_init()`:

```c
if (g_state_mutex == NULL) {
    g_state_mutex = xSemaphoreCreateMutex();
    configASSERT(g_state_mutex != NULL);
}
DSGV_gpio_init();
```

---

### Fix 2 — WPA3-SAE connection timeout (device halts before Wi-Fi connects)

**Root cause:** Wi-Fi connection wait was a fixed 3-second delay. The router uses WPA3-SAE
(Dragonfly handshake) which takes 4–5 seconds. The device logged "Wi-Fi failed to connect
within 3 s. Halting." and stopped — even though the connection completed 1.5 seconds later.

**Fix:** Replace fixed delay with a 1-second polling loop, up to 15 attempts:

```c
for (int i = 0; i < 15 && !wifi_manager_is_connected(); i++) {
    vTaskDelay(pdMS_TO_TICKS(1000));
}
if (!wifi_manager_is_connected()) {
    ESP_LOGE(TAG, "Wi-Fi failed to connect within 15 s. Halting.");
    return;
}
```

---

### Fix 3 — MQTT failure aborts HTTP server and physical button control

**Root cause:** `ESP_ERROR_CHECK(DSGV_mqtt_start())` — if the cloud broker is unreachable
or the MQTT client fails to initialise (heap, TLS), this macro calls `abort()`, killing
the HTTP server and GPIO state machine that were already running.

**Fix:** Treat MQTT as best-effort:

```c
esp_err_t mqtt_err = DSGV_mqtt_start();
if (mqtt_err != ESP_OK) {
    ESP_LOGW(TAG, "MQTT start failed (%s) — device operable via HTTP and local control",
             esp_err_to_name(mqtt_err));
}
```

The device is **fully functional locally** (HTTP REST API + physical buttons) regardless of
cloud connectivity.

---

### Fix 4 — MQTT broker fallback deadlocks the MQTT task

**Root cause:** `MQTT_EVENT_ERROR` handler called `esp_mqtt_client_destroy()` directly
inside the MQTT event callback. IDF's MQTT client holds an internal mutex while dispatching
events — calling `destroy` from within the callback tries to acquire the same mutex and
deadlocks. This could starve the HTTP server and GPIO interrupt tasks.

**Fix:** Use the existing `_schedule_broker_switch()` helper, which defers the
destroy/reconnect to a fresh FreeRTOS task:

```c
case MQTT_EVENT_ERROR:
    if (!s_using_local_broker) {
        s_using_local_broker = true;
        _schedule_broker_switch(MQTT_LOCAL_HOST, MQTT_LOCAL_PORT,
                                /*tls=*/false, /*is_rollback=*/false);
    }
    break;
```

---

### Fix 5 — BLE service UUID in scan response (app cannot find device)

**Root cause:** The service UUID was placed only in the scan response packet. Flutter's
`FlutterBluePlus` and iOS CoreBluetooth filter BLE scan results by checking the primary
advertisement packet only — they never retrieve the scan response unless they have already
decided to connect. The app returned "Device not found."

**Fix:** Move service UUID to the primary advertisement, device name to scan response:

```c
// Primary ad: flags + service UUID (required for filtered scan discovery)
fields.uuids128             = &s_svc_uuid;
fields.num_uuids128         = 1;
fields.uuids128_is_complete = 1;
ble_gap_adv_set_fields(&fields);

// Scan response: device name only
rsp.name             = (const uint8_t *)s_dev_name;
rsp.name_len         = (uint8_t)strlen(s_dev_name);
ble_gap_adv_rsp_set_fields(&rsp);
```

---

## 8. App Changes Applied

### `lib/domain/services/ble_provisioning_service.dart`

**New model: `WifiNetwork`**
```dart
class WifiNetwork {
  final String ssid;
  final int rssi;
  int get signalLevel { /* 0–3 based on rssi */ }
}
```

**New model: `ProvisioningDeviceInfo`**
```dart
class ProvisioningDeviceInfo {
  final List<WifiNetwork> networks;
  final String deviceType;
  final List<String> capabilities;
  final int relayCount;
  String get label { /* human-readable from capabilities */ }
  IconData get icon { /* Material icon from capabilities  */ }
}
```

**New method: `fetchProvisioningData(String deviceName)`**

Opens one BLE connection, reads Wi-Fi Scan and Device Info characteristics in parallel,
disconnects, returns a `ProvisioningDeviceInfo`. Never throws — returns empty defaults
on any failure so the screen always falls back to manual entry.

```dart
final results = await Future.wait([
  wifiChar.read(),
  infoChar.read(),
]);
```

### `lib/presentation/screens/matter_pairing_screen.dart`

| Removed | Replaced with |
|---|---|
| `_DevicePreset` class + `_kDevicePresets` list | — (deleted entirely) |
| `_selectedPreset` state field | `_deviceInfo` (`ProvisioningDeviceInfo?`) |
| `_buildPresetDropdown()` dropdown widget | `_buildDeviceInfoCard()` read-only card |
| `_isLoadingNetworks` / `_availableNetworks` | `_isLoadingDeviceInfo` / `_deviceInfo?.networks` |
| Manual SSID text field (always shown) | `_buildSsidSection()` — picker or text field |

The `_runBleProvisioning()` method no longer sends `device_type`, `capabilities`, or
`relay_count` to the service — those are already baked into the firmware. Only `ssid` and
`password` are sent.

---

## 9. Build & Flash Reference

### Prerequisites (Windows)

1. ESP-IDF v6.0.1 installed via the Espressif Windows installer
2. IDF environment activated in every new terminal:

```powershell
. "C:\Espressif\tools\Microsoft.v6.0.1.PowerShell_profile.ps1"
```

### Navigate to the device

```powershell
cd "C:\Users\Chijioke\Documents\IoT-Project\dsgv_firmware\devices\1gang_switch"
```

### Build only

```powershell
idf.py build
```

### Normal flash (NVS survives — Wi-Fi credentials kept)

```powershell
idf.py -p COM3 flash
```

### Full erase + flash (wipes all NVS — use for clean provisioning tests)

```powershell
# Using the saved script (recommended):
.\flash_clean.ps1              # COM3 default
.\flash_clean.ps1 -Port COM5   # override port

# Or manually:
idf.py -p COM3 erase-flash flash
```

**When to use full erase:**
- Testing the provisioning flow from scratch
- Switching Wi-Fi networks
- After changing the NVS partition layout
- Before shipping a device to a customer

### Flash + open serial monitor

```powershell
idf.py -p COM3 flash monitor
```

### Full erase + flash + monitor (most useful during development)

```powershell
idf.py -p COM3 erase-flash flash monitor
```

Exit the serial monitor: **Ctrl + ]**

### Find the COM port

Open **Device Manager → Ports (COM & LPT)**. Look for "Silicon Labs CP210x USB to UART"
or "USB Serial Device". Common ports on this machine: COM3, COM5, COM7.

### Build the Flutter APK

```powershell
cd "C:\Users\Chijioke\Documents\IoT-Project\dsgv_hub_app"
flutter build apk --release
# Output: build\app\outputs\flutter-apk\app-release.apk
```

### Install APK to connected Android device

```powershell
adb install build\app\outputs\flutter-apk\app-release.apk
```

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `assert failed: xQueueSemaphoreTake` on boot | Mutex used before creation | Fixed in firmware (see Fix 1) |
| `Wi-Fi failed to connect within 3 s` | WPA3-SAE too slow for old timeout | Fixed: timeout now 15 s (see Fix 2) |
| BLE advertising visible in phone Settings but can't pair | Wrong BLE stack config | Add `CONFIG_BTDM_CTRL_MODE_BLE_ONLY=y` |
| App shows "Device not found" | Service UUID in scan response, not primary ad | Fixed in firmware (see Fix 5) |
| HTTP / buttons stop working when MQTT fails | `ESP_ERROR_CHECK` on MQTT start | Fixed: MQTT is now best-effort (see Fix 3) |
| Device connects to old Wi-Fi after reflash | NVS not erased | Use `erase-flash flash` or `flash_clean.ps1` |
| Build error: "Failed to set target esp32" | Stale build directory after target change | Delete `devices/1gang_switch/build/` and rebuild |
| `idf.py: command not found` in PowerShell | IDF environment not activated | Run the `export.ps1` line at the top of this section |
| App "Device not found" after fixing UUID | Old APK still installed | Rebuild and reinstall APK |

---

*Document last updated: 2026-06-05*
*Firmware: ESP-IDF v6.0.1 · Target: esp32 · App: Flutter with flutter_blue_plus v1.35.5*
