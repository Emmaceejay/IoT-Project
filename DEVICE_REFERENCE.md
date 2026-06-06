# DSGV Hub — Device Reference

Complete reference for all device SKUs: MQTT topics, telemetry payloads, commands,
HTTP API, BLE provisioning UUIDs, and GPIO pin maps.

**Broker (test phase):** `broker.hivemq.com:1883` (plain TCP, no auth)
**Broker (production):** replace in `dsgv_config.h` + `mqtt_config.dart` together

---

## Device SKU Catalog

| SKU folder | Device type | Capabilities | Relay count |
|---|---|---|---|
| `1gang_switch` | Switch | `relay` | 1 |
| `2gang_switch` | Switch | `relay`, `relay_2` | 2 |
| `3gang_switch` | Switch | `relay`, `relay_2`, `relay_3` | 3 |
| `4gang_switch` | Switch | `relay`, `relay_2`, `relay_3`, `relay_4` | 4 |
| `dimmer` | Dimmer | `relay`, `brightness` | 1 |
| `colour_temp` | Light | `relay`, `brightness`, `color_temp` | 1 |
| `rgb_light` | Light | `relay`, `brightness`, `rgb` | 1 |
| `temp_sensor` | Sensor | `temperature`, `humidity` | 0 |
| `motion_sensor` | Sensor | `motion` | 0 |
| `contact_sensor` | Sensor | `contact` | 0 |
| `thermostat` | Thermostat | `temperature`, `hvac_mode` | 0 |

---

## MQTT Topics

All topics use the device's Wi-Fi MAC address as `{id}` (12 uppercase hex chars, e.g. `A1B2C3D4E5F6`).

| Topic | Direction | Retained | Purpose |
|---|---|---|---|
| `devices/{id}/announce` | Device → Broker | **Yes** | Device discovery on connect. App subscribes to populate dashboard. |
| `devices/{id}/status` | Device → Broker | Yes | `"online"` on connect; `"offline"` via LWT when connection drops. |
| `devices/{id}/telemetry` | Device → Broker | No | Full state snapshot after any change, and every 30 s. |
| `devices/{id}/command` | App → Device | No | Control commands. Device acts immediately on receipt. |
| `devices/{id}/ota-trigger` | App → Device | No | OTA firmware update trigger. |
| `devices/{id}/config` | App → Device | No | Authenticated broker reconfiguration. |

### Announce payload (published retained on every MQTT connect)

```json
{
  "device_id":    "A1B2C3D4E5F6",
  "name":         "Switch_D4E5F6",
  "capabilities": ["relay"],
  "local_ip":     "192.168.1.42",
  "firmware":     "1.0.0",
  "status":       "online"
}
```

The `name` is auto-generated: `{DeviceType}_{last3MACbytes}`, e.g. `Dimmer_A1B2C3`.
The app reads `capabilities` to decide which UI controls to render — no manual configuration.

---

## Per-Device: Topics, Telemetry & Commands

### 1-Gang Switch

**Topics**
- Subscribe: `devices/{id}/command`
- Publish: `devices/{id}/telemetry`, `devices/{id}/announce`, `devices/{id}/status`

**Telemetry payload**
```json
{ "power": false }
```

**Command payload**
```json
{ "power": true }
```

---

### 2-Gang Switch

**Telemetry**
```json
{ "power": false, "power_2": true }
```

**Commands** — send any or all keys
```json
{ "power": true }
{ "power_2": false }
{ "power": true, "power_2": true }
```

---

### 3-Gang Switch

**Telemetry**
```json
{ "power": false, "power_2": true, "power_3": false }
```

**Commands** — any subset of keys
```json
{ "power_3": true }
```

---

### 4-Gang Switch

**Telemetry**
```json
{ "power": false, "power_2": false, "power_3": true, "power_4": false }
```

**Commands** — any subset of keys
```json
{ "power": true, "power_4": false }
```

---

### Dimmer

**Telemetry**
```json
{ "power": true, "brightness": 75 }
```
`brightness`: 0–100 (percent)

**Commands**
```json
{ "power": true }
{ "brightness": 50 }
{ "power": true, "brightness": 80 }
```

---

### Colour Temperature Light

**Telemetry**
```json
{ "power": true, "brightness": 80, "color_temp": 3000 }
```
`brightness`: 0–100  
`color_temp`: 1000–10000 Kelvin (warm = low, cool = high)

**Commands**
```json
{ "brightness": 60, "color_temp": 4000 }
```

---

### RGB Light

**Telemetry**
```json
{ "power": true, "brightness": 100, "red": 255, "green": 128, "blue": 0 }
```
`brightness`: 0–100  
`red`, `green`, `blue`: 0–255

**Commands**
```json
{ "red": 255, "green": 0, "blue": 255 }
{ "brightness": 50 }
{ "power": false }
```

---

### Temperature & Humidity Sensor

**Telemetry** (published every 30 s, read-only)
```json
{ "current_temp": 23.5, "humidity": 61.2 }
```
No commands accepted.

---

### Motion Sensor

**Telemetry** (published on state change + every 30 s)
```json
{ "motion": true }
```
No commands accepted.

---

### Contact / Door Sensor

**Telemetry** (published on state change + every 30 s)
```json
{ "contact": true }
```
`contact: true` = closed (reed switch made), `false` = open.  
No commands accepted.

---

### Thermostat

**Telemetry**
```json
{ "current_temp": 21.0, "target_temp": 22.0, "mode": "heat" }
```
`mode`: `"heat"` | `"cool"` | `"auto"` | `"off"`

**Commands**
```json
{ "target_temp": 23.5 }
{ "mode": "cool" }
{ "target_temp": 20.0, "mode": "heat" }
```

---

## HTTP Local API

Active on port `80` whenever the device is on Wi-Fi.
The app uses this as the **primary transport** when on the same network (lower latency than MQTT).

### GET `/api/status`

Returns the full current device state. Response is the same structure as the telemetry payload for that device type.

```
GET http://192.168.1.42/api/status
```

Example response (1-gang switch):
```json
{ "power": false }
```

### POST `/api/cmd`

Sends a single capability command.

```
POST http://192.168.1.42/api/cmd
Content-Type: application/json

{ "capability": "power", "value": true }
```

Supported `capability` strings: `power`, `power_2`, `power_3`, `power_4`, `brightness`, `color_temp`, `target_temp`, `mode`, `red`, `green`, `blue`

### GET `/cm` — Tasmota Compatibility

Works with any Tasmota-compatible tool or integration.

| Command | Example |
|---|---|
| `Power ON` | `GET /cm?cmnd=Power%20ON` |
| `Power OFF` | `GET /cm?cmnd=Power%20OFF` |
| `Power Toggle` | `GET /cm?cmnd=Power%20Toggle` |
| `Dimmer N` (0–100) | `GET /cm?cmnd=Dimmer%2075` |
| `CT N` (mired 153–500) | `GET /cm?cmnd=CT%20200` |

---

## BLE Provisioning

All devices advertise under the name `DSGVHub_{last3MAC}` (e.g. `DSGVHub_A1B2C3`) when unconfigured.

**QR URL format:** `dsgv://provision?name=DSGVHub_A1B2C3`

### GATT Service

**Service UUID:** `4fafc201-1fb5-459e-8fcc-c5c9c331914b`

| Characteristic | UUID | Access | Purpose |
|---|---|---|---|
| Credentials | `beb5483e-36e1-4688-b7f5-ea07361b26a8` | Write | App writes `{"ssid":"...","password":"..."}` |
| Status | `beb5483f-36e1-4688-b7f5-ea07361b26a8` | Read + Notify | `success:<token>:<mac>` or `failed:<reason>` |
| Wi-Fi Scan | `beb5483d-36e1-4688-b7f5-ea07361b26a8` | Read | JSON array of nearby networks `[{"ssid":"...","rssi":-45}]` |
| Device Info | `beb5483c-36e1-4688-b7f5-ea07361b26a8` | Read | `{"device_type":"Switch","capabilities":["relay"],"relay_count":1}` |

### Provisioning Flow

```
App scans QR  →  BLE connect  →  read Device Info + Wi-Fi Scan (parallel)
→  user picks network + enters password
→  app writes credentials to Credentials char
→  device connects to Wi-Fi
→  device notifies Status char: "success:<32hexToken>:<MAC>"
→  device reboots  →  starts HTTP + MQTT
→  MQTT announce published (retained)  →  app adds device to dashboard
```

---

## GPIO Pin Map

Pins are selected automatically at compile time by `IDF_TARGET`. Only edit `sdkconfig.defaults` to change a device's identity — never hardcode pins.

### ESP32 Classic (WROOM, WROVER)

| Function | GPIO | Notes |
|---|---|---|
| Relay 1 | 26 | Digital out, active-high |
| Relay 2 | 27 | |
| Relay 3 | 25 | |
| Relay 4 | 32 | |
| Wall switch 1 | 13 | Digital in, internal pull-up, switch to GND |
| Wall switch 2 | 16 | |
| Wall switch 3 | 17 | |
| Wall switch 4 | 18 | |
| Dimmer PWM | 27 | LEDC ch 0, 5 kHz |
| CCT warm PWM | 14 | LEDC ch 1 |
| CCT cool PWM | 12 | LEDC ch 2 |
| RGB red PWM | 25 | LEDC ch 3 |
| RGB green PWM | 32 | LEDC ch 4 |
| RGB blue PWM | 33 | LEDC ch 5 |
| NTC temp ADC | 34 | ADC1 ch6, input-only, needs external pull-down |
| PIR motion in | 35 | Input-only, external pull-down |
| Reed contact in | 36 (SENSOR_VP) | Input-only, external pull-up |
| Status LED | 2 | |
| Factory reset btn | 0 | Hold 5 s to erase Wi-Fi creds + reboot |

> **Input-only GPIOs 34–39:** no internal pull resistors. Always add external 10 kΩ resistors on the PCB.

### ESP32-C3 / C6

| Function | GPIO | Notes |
|---|---|---|
| Relay 1 | 2 | |
| Relay 2 | 3 | Shared with dimmer — don't combine |
| Relay 3 | 4 | Shared with CCT warm |
| Relay 4 | 5 | Shared with CCT cool |
| Wall switch 1 | 18 | USB D– on dev kits; safe on production PCBs |
| Wall switch 2 | 19 | USB D+ on dev kits |
| Wall switch 3 | 20 | |
| Wall switch 4 | 21 | |
| Dimmer PWM | 3 | LEDC ch 0 |
| CCT warm PWM | 4 | LEDC ch 1 |
| CCT cool PWM | 5 | LEDC ch 2 |
| RGB red PWM | 6 | LEDC ch 3 |
| RGB green PWM | 7 | LEDC ch 4 |
| RGB blue PWM | 10 | LEDC ch 5 |
| NTC temp ADC | 1 | ADC1 ch1 |
| PIR motion in | 11 | |
| Reed contact in | 20 | |
| Status LED | 8 | |
| Factory reset btn | 9 | Hold 5 s |

### ESP32-S3

| Function | GPIO | Notes |
|---|---|---|
| Relay 1 | 4 | |
| Relay 2 | 21 | |
| Relay 3 | 47 | |
| Relay 4 | 48 | |
| Wall switch 1 | 36 | |
| Wall switch 2 | 37 | |
| Wall switch 3 | 38 | |
| Wall switch 4 | 39 | |
| Dimmer PWM | 5 | LEDC ch 0 |
| CCT warm PWM | 6 | LEDC ch 1 |
| CCT cool PWM | 7 | LEDC ch 2 |
| RGB red PWM | 15 | LEDC ch 3 |
| RGB green PWM | 16 | LEDC ch 4 |
| RGB blue PWM | 17 | LEDC ch 5 |
| NTC temp ADC | 1 | ADC1 ch0 |
| PIR motion in | 18 | |
| Reed contact in | 19 | |
| Status LED | 2 | |
| Factory reset btn | 0 | Hold 5 s |

---

## Factory Reset

Toggle the wall switch for **gang 1** exactly **5 times within 10 seconds**.  
The device will erase all Wi-Fi credentials from NVS and reboot into BLE provisioning mode.

Defined in `dsgv_config.h`:
```c
#define DSGV_RESET_TOGGLE_COUNT  5
#define DSGV_RESET_WINDOW_MS     10000
```

---

## Building & Flashing

All devices share the `components/dsgv_common/` source. The only file you change per device is `devices/<sku>/sdkconfig.defaults`.

```powershell
# Build
cd devices/1gang_switch
idf.py build

# Flash with full NVS erase (clean slate) — recommended
.\flash_clean.ps1 -Port COM3

# Flash keeping existing Wi-Fi credentials
.\flash_clean.ps1 -Port COM3 -NoErase

# Or from VSCode: Ctrl+Shift+B runs the clean flash task automatically
```

Flash script is at [devices/1gang_switch/flash_clean.ps1](dsgv_firmware/devices/1gang_switch/flash_clean.ps1).  
VSCode task is at [devices/1gang_switch/.vscode/tasks.json](dsgv_firmware/devices/1gang_switch/.vscode/tasks.json).

---

## Production Checklist

Before shipping:

- [ ] Replace `broker.hivemq.com` with a private authenticated broker in `dsgv_config.h` (`MQTT_CLOUD_HOST`, `MQTT_CLOUD_PORT`, `MQTT_CLOUD_TLS`)
- [ ] Mirror the same broker in `mqtt_config.dart` (`factoryDefault`)
- [ ] Set `MQTT_CLOUD_TLS = true` and provision TLS CA certificate
- [ ] Set a strong, unique `auth_token` seed per device (used to authenticate broker-config changes)
- [ ] Remove `onBadCertificate` callback in `mqtt_service.dart` (currently accepts all certs)
- [ ] Replace `YOUR_PROJECT_ID` in `dsgv_config.h` `FIREBASE_GET_CONFIG_URL`
- [ ] Set correct `IDF_TARGET` per hardware revision in each device `CMakeLists.txt`
