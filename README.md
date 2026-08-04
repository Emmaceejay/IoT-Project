<div align="center">
  <h1>DSGV Hub IoT Platform</h1>
  <p><strong>Full-stack commercial IoT platform — Flutter mobile app · ESP-IDF firmware · Cloudflare Workers gateway</strong></p>
  <p>
    Offline-first &nbsp;·&nbsp;
    BLE provisioning &nbsp;·&nbsp;
    Token-secured config &nbsp;·&nbsp;
    Schema-driven UI &nbsp;·&nbsp;
    OTA updates &nbsp;·&nbsp;
    Multi-chip ESP32
  </p>
</div>

---

## Table of Contents

1. [What Is This?](#1-what-is-this)
2. [How It Works — Architecture](#2-how-it-works--architecture)
3. [Repository Structure](#3-repository-structure)
4. [Prerequisites](#4-prerequisites)
5. [Part A — Cloudflare Gateway Setup](#5-part-a--cloudflare-gateway-setup)
6. [Part B — Firmware Setup](#6-part-b--firmware-setup)
7. [Part C — Mobile App Setup](#7-part-c--mobile-app-setup)
8. [Provisioning a New Device](#8-provisioning-a-new-device)
9. [Supported Hardware](#9-supported-hardware)
10. [Supported Device Types](#10-supported-device-types)
11. [Protocol Reference — MQTT Topics](#11-protocol-reference--mqtt-topics)
12. [Gateway Data Structure](#12-gateway-data-structure)
13. [Security Model](#13-security-model)
14. [Configuration Reference](#14-configuration-reference)
15. [Adding a New Device Type](#15-adding-a-new-device-type)
16. [Debugging and Monitoring](#16-debugging-and-monitoring)
17. [Project Files at a Glance](#17-project-files-at-a-glance)
18. [Recent Updates](#18-recent-updates)

---

## 1. What Is This?

DSGV Hub is a **production-ready, end-to-end IoT platform** built by De Socko Global Ventures. It consists of three parts that work together:

| Part | Technology | Purpose |
|------|-----------|---------|
| **Mobile App** | Flutter / Dart | Control devices, provision new ones, manage broker settings |
| **Firmware** | C / ESP-IDF 5.x | Runs on ESP32 devices — handles WiFi, MQTT, sensors, relays, OTA |
| **Cloud Gateway** | Cloudflare Workers + Workers KV | Securely stores and delivers broker configuration to each device |

**The core idea is simple:**
- Flash the same firmware binary to any ESP32 device
- Scan a QR code in the app to provision it over Bluetooth
- The device appears on the dashboard automatically — no computer needed after flashing
- Change the MQTT broker at any time from the app — the change is written to the gateway and every device picks it up silently on its next boot

---

## 2. How It Works — Architecture

### The Three Communication Channels

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          MOBILE APP (Flutter)                           │
└───────────────┬─────────────────────────┬───────────────────────────────┘
                │                         │
   BLE (once,   │                         │  HTTPS (Cloudflare Workers gateway)
   provisioning)│                         │  Register device
                │                         │  Push broker config
                │                         │  Restore factory broker
                ▼                         ▼
┌──────────────────────┐    ┌──────────────────────────────┐
│   ESP32 Device       │    │  cloudflare_gateway/          │
│                      │    │  (Cloudflare Workers,          │
│  On boot:            │    │   free tier)                   │
│  1. WiFi connect     │    │                                │
│  2. HTTPS fetch ─────┼────┼─►                               │
│     broker config    │◄───┼───┐                            │
│  3. MQTT connect     │    │   ▼                            │
│                      │    │  Workers KV                    │
└──────────┬───────────┘    │   ┌──────────────────────┐     │
           │                │   │ device_registry:{id}  │     │
           │                │   │  auth_token (private)│     │
           │                │   │ device_configs:{id}    │     │
           │                │   │  broker settings      │     │
           │                │   └──────────────────────┘     │
           │                └──────────────────────────────┘
           │  MQTT (ongoing)
           │  telemetry, commands, status
           ▼
┌──────────────────────┐
│   MQTT Broker        │
│  (your server or     │
│   cloud broker)      │
└──────────────────────┘
```

### MQTT is for Control. The Gateway is for Configuration.

| Channel | Used for | Security |
|---------|---------|---------|
| **MQTT** | Live telemetry, relay commands, device status | Auth token in every config command |
| **Gateway HTTPS** | Broker hostname, port, TLS flag, credentials | auth_token validated by the Cloudflare Worker against Workers KV |
| **BLE** | First-time WiFi credentials, device type, auth token exchange | Physical proximity required |

Credentials (broker username/password) **never travel over MQTT**. They live in
Workers KV — Cloudflare's own key-value store, read/written directly by the
Worker via a zero-config binding, no external auth needed — and are fetched by
the device directly over HTTPS. This is not Firebase: the gateway used to be
Firebase Cloud Functions + Realtime Database, but deploying *any* Cloud Function
requires the Blaze (pay-as-you-go) plan, so the whole gateway — compute and
storage — now runs on Cloudflare's free tier instead. No Firebase project is
part of this architecture anymore. See [§5](#5-part-a--cloudflare-gateway-setup).

### Command Routing in the App

When the user taps a switch, the app routes the command in priority order:

```
1. Local HTTP (same LAN, sub-10 ms latency)   — if device IP is known
2. MQTT cloud broker                           — primary remote path
3. ObjectBox local cache update               — always applied first (optimistic UI)
```

The UI updates **instantly** before any network confirmation — the app never feels slow.

### Settings — Factory Mode vs Custom Mode

On first install, the app connects to the **manufacturer's MQTT broker** automatically. The broker address is never shown to the user.

If a user (or installer) wants to use their own broker:
- Settings → **Use custom broker** → unlocks the form
- Enter host, port, TLS settings → **Save & Connect**
- Tap **Push broker to all devices** → the gateway updates Workers KV → devices pick it up on next reboot

To revert: Settings → **↩ Manufacturer** → devices reconnect to the factory broker.

---

## 3. Repository Structure

```
IoT-Project/
│
├── dsgv_hub_app/                    ← Flutter mobile application
│   ├── lib/
│   │   ├── core/                    # ObjectBox store initialisation
│   │   ├── data/
│   │   │   ├── datasources/         # ObjectBox implementation (devices + groups)
│   │   │   ├── models/              # DeviceEntity, DeviceGroupEntity (database schema)
│   │   │   └── repositories/        # DeviceRepository, DeviceGroupRepository
│   │   ├── domain/
│   │   │   ├── models/              # MatterDevice, MqttConfig, DeviceGroup, Room,
│   │   │   │                        # DeviceSchedule, DeviceTypeDefinition
│   │   │   └── services/
│   │   │       ├── device_manager.dart          # Central state engine (AsyncNotifier)
│   │   │       ├── device_type_registry.dart    # Single source of truth for capabilities
│   │   │       │                                #   → labels, icons, ranges, telemetry/command keys
│   │   │       ├── device_group_notifier.dart   # Group state + batch commands
│   │   │       ├── room_service.dart            # Room assignment
│   │   │       ├── schedule_service.dart        # Timed on/off schedules
│   │   │       ├── mqtt_service.dart            # MQTT client + factory/custom mode
│   │   │       ├── gateway_config_service.dart  # Client for cloudflare_gateway/'s HTTP endpoints
│   │   │       ├── ble_provisioning_service.dart
│   │   │       ├── local_http_service.dart
│   │   │       ├── ota_service.dart
│   │   │       └── telemetry_service.dart
│   │   └── presentation/
│   │       ├── screens/             # Dashboard, Pairing, Settings, Device Detail, Groups
│   │       └── widgets/
│   │           ├── app_shell.dart              # Root nav shell (3 tabs)
│   │           ├── device_card.dart            # Expandable device card
│   │           ├── schedule_sheet.dart         # Schedule create/edit sheet
│   │           └── schema_driven_ui_builder.dart # Renders controls from device_type_registry
│   └── (no backend project files here — the gateway lives in cloudflare_gateway/,
│        not inside the Flutter project)
│
├── dsgv_firmware/                   ← ESP32 firmware (C / ESP-IDF 5.x)
│   ├── components/
│   │   └── dsgv_common/             # Shared firmware logic, linked into every device build
│   │       ├── dsgv_app_main.c      # Boot sequence: NVS → config → event bus → GPIO → WiFi → HTTP → MQTT
│   │       ├── include/
│   │       │   ├── dsgv_config.h          # GPIO maps, MQTT endpoints, gateway URL
│   │       │   ├── dsgv_device_config.h   # Runtime config struct
│   │       │   ├── dsgv_events.h          # GPIO ↔ MQTT event bus API
│   │       │   └── dsgv_gateway.h         # Gateway config-fetch API
│   │       ├── config/
│   │       │   └── dsgv_device_config.c   # NVS load/save with bounds validation
│   │       ├── events/
│   │       │   └── dsgv_events.c          # Decouples GPIO from MQTT via a FreeRTOS queue
│   │       ├── gateway/
│   │       │   └── dsgv_gateway.c         # HTTPS fetch broker config from cloudflare_gateway/
│   │       ├── gpio/
│   │       │   └── dsgv_gpio.c            # LEDC PWM, relay, ISR sensors
│   │       ├── mqtt/
│   │       │   └── dsgv_mqtt.c            # MQTT connect, announce, telemetry, commands
│   │       ├── http/
│   │       │   ├── dsgv_http_server.c     # LAN REST API (/status, /command, /ota)
│   │       │   └── dsgv_captive_portal.c  # AP mode setup portal (192.168.4.1)
│   │       ├── provisioning/
│   │       │   └── dsgv_provisioning.c    # NimBLE GATT WiFi provisioning
│   │       └── ota/
│   │           └── dsgv_ota.c             # HTTPS OTA, manifest-based version/URL/hash
│   └── devices/                     # One ESP-IDF project per SKU — each main.c is a
│       │                            # thin stub that just calls dsgv_app_main()
│       ├── 1gang_switch/ … 4gang_switch/  # 1–4 gang relay switches
│       ├── dimmer/                  # LEDC PWM dimmer
│       ├── colour_temp/             # Warm/cool colour-temperature light
│       ├── rgb_light/               # RGB + CCT light
│       ├── temp_sensor/             # Temperature / humidity sensor
│       ├── motion_sensor/           # PIR motion sensor
│       ├── contact_sensor/          # Reed switch contact sensor
│       └── thermostat/              # HVAC controller
│
├── cloudflare_gateway/               ← Device-config gateway (Cloudflare Workers + KV)
│   ├── wrangler.toml                # Worker name, entry point, DSGV_KV binding
│   ├── package.json                 # zero runtime dependencies
│   ├── SETUP_GUIDE.md               # Full deploy walkthrough (CLI + dashboard)
│   └── src/
│       ├── index.js                 # Router: registerDevice, getDeviceConfig,
│       │                            #   updateDeviceConfig, revertDeviceToFactory
│       ├── store.js                 # Workers KV read/write wrapper
│       └── safeEqual.js             # Constant-time auth_token comparison
│
├── IoT_APP_Design/                  ← Architecture whitepaper + engineering review docs
│   ├── IoT_Architecture_Whitepaper.md
│   ├── Critical_Review.md           # Principal-engineer pass over architecture + in-flight changes
│   ├── Security_Review.md           # Static security review (firmware, app, cloud gateway)
│   └── Production_Readiness_GoNoGo.md # Go/No-Go checklist ahead of shipping
│
├── FLASHING_GUIDE.md               ← Wiring diagrams + flash commands for every device type
├── QUICKSTART_GUIDE.md             ← 5-minute setup for experienced developers
├── PRE_PRODUCTION_GUIDE.md         ← Checklist before shipping to customers
└── README.md                       ← This file
```

---

## 4. Prerequisites

### All Developers

| Tool | Version | Install |
|------|---------|---------|
| Git | Any | https://git-scm.com |
| Node.js | 20+ | https://nodejs.org |
| Wrangler CLI (Cloudflare) | Latest | `npm install -g wrangler` |

### For App Development

| Tool | Version | Install |
|------|---------|---------|
| Flutter SDK | 3.x | https://docs.flutter.dev/get-started/install |
| Android SDK | API 21+ | Via Android Studio |
| `ANDROID_HOME` env var | — | Set to your Android SDK path |

Verify Flutter is ready:
```bash
flutter doctor
```
All items should show a checkmark. If `Android toolchain` shows `[!]`, install Android Studio and run its SDK setup wizard.

### For Firmware Development

| Tool | Version | Install |
|------|---------|---------|
| ESP-IDF | 5.x | https://docs.espressif.com/projects/esp-idf/en/stable/esp32/get-started/ |
| VS Code ESP-IDF Extension | Latest | VS Code → Extensions → "Espressif IDF" |

Verify IDF is ready:
```bash
idf.py --version
# Should print: ESP-IDF v5.x.x
```

---

## 5. Part A — Cloudflare Gateway Setup

> **Do this first.** The app and firmware both need a working device-config gateway.

The gateway (`cloudflare_gateway/`) runs entirely on **Cloudflare Workers +
Workers KV** — no Firebase, no other cloud provider, no paid plan of any kind.
Workers hosts the four HTTP endpoints (`registerDevice`, `getDeviceConfig`,
`updateDeviceConfig`, `revertDeviceToFactory`); Workers KV stores
`device_registry` (auth tokens) and `device_configs` (broker settings per
device), read and written directly via a zero-config binding — no external
auth step needed. Free tier: 100k requests/day, no credit card required to
sign up or deploy.

This is a condensed version — for the full walkthrough (including the current
Cloudflare dashboard UI as an alternative to each CLI step, plus
troubleshooting) see **[cloudflare_gateway/SETUP_GUIDE.md](./cloudflare_gateway/SETUP_GUIDE.md)**.

### Step 1 — Cloudflare Account and Wrangler

```bash
npm install -g wrangler
wrangler login
```

### Step 2 — Create the KV Namespace

```bash
cd cloudflare_gateway
wrangler kv namespace create DSGV_KV
```

Paste the `id` it prints into `wrangler.toml`'s `[[kv_namespaces]]` block.

### Step 3 — Set Secrets and Deploy

```bash
npm install
wrangler secret put MQTT_BROKER_USERNAME
wrangler secret put MQTT_BROKER_PASSWORD
wrangler deploy
```

First deploy prints your Worker's URL:
`https://dsgv-hub-gateway.<your-subdomain>.workers.dev`

### Step 4 — Point the App and Firmware at the Gateway

Replace the base URL in these two files with the URL from Step 3:

```
dsgv_hub_app/lib/domain/services/gateway_config_service.dart   _kGatewayBase
dsgv_firmware/components/dsgv_common/include/dsgv_config.h     GATEWAY_GET_CONFIG_URL (append /getDeviceConfig)
```

Also replace the HiveMQ broker hostname with your own in these three locations —
they must all match, or "Restore factory broker" will send devices to a
different address than the firmware factory default:
```
dsgv_hub_app/lib/domain/models/mqtt_config.dart              factoryDefault.host
dsgv_firmware/components/dsgv_common/include/dsgv_config.h   MQTT_CLOUD_HOST
cloudflare_gateway/src/index.js                               FACTORY_CONFIG_BASE.broker_host
```

---

## 6. Part B — Firmware Setup

### Step 1 — Clone and Enter the Firmware Directory

```bash
cd IoT-Project/dsgv_firmware
```

### Step 2 — Set the Target Chip

```bash
# For ESP32-C3 (recommended)
idf.py set-target esp32c3

# For other chips:
# idf.py set-target esp32s3
# idf.py set-target esp32c6
# idf.py set-target esp32
```

### Step 3 — Configure Your Device Type

Open `components/dsgv_common/include/dsgv_config.h` and set the device type and GPIO pins for your hardware. Most values are already set correctly per chip — the main things to verify are relay GPIO pins and device type.

See **[FLASHING_GUIDE.md](./FLASHING_GUIDE.md)** for exact wiring diagrams and per-SKU config values.

### Step 4 — Enable HTTPS in sdkconfig

Add to your device's `sdkconfig.defaults`:

```
CONFIG_ESP_HTTP_CLIENT_ENABLE_HTTPS=y
CONFIG_MBEDTLS_CERTIFICATE_BUNDLE=y
```

### Step 5 — Boot Sequence (already wired — nothing to edit)

Every device's `main.c` is a thin stub:

```c
#include "dsgv_common.h"

void app_main(void) { dsgv_app_main(); }
```

`dsgv_app_main()` (in `components/dsgv_common/dsgv_app_main.c`) runs the full boot
sequence shared by every SKU — you don't add per-device wiring:

```
1. NVS init + device config load (compile-time defaults → NVS overlay)
2. TCP/IP stack + default event loop
3. Event bus init (dsgv_events — must come before GPIO)
4. GPIO init (relays, LEDC PWM, ADC, sensors)
5. WiFi connect — falls back to BLE provisioning or captive-portal AP if it fails
6. Local HTTP server (Tasmota-compatible REST API, port 80) — live before anything below
7. Gateway config fetch (dsgv_gateway.c, best-effort) — pulls broker host/port/tls/
   credentials from cloudflare_gateway/ into NVS; failure just means MQTT uses
   whatever's cached from a previous successful fetch
8. MQTT client (best-effort — a failed connect does not block local control)
```

### Step 6 — Build and Flash

```bash
idf.py build
idf.py -p COM5 flash monitor    # Replace COM5 with your port (COMx on Windows, /dev/tty... on Mac/Linux)
```

On first boot you should see:
```
I (xxxx) DSGV_Gateway: Broker config updated: mqtt.yourdomain.com:8883 (TLS=1)
I (xxxx) DSGV_MQTT: Connected to mqtt.yourdomain.com:8883
```

---

## 7. Part C — Mobile App Setup

### Step 1 — Install Dependencies

```bash
cd IoT-Project/dsgv_hub_app
flutter pub get
```

### Step 2 — Android SDK Environment Variable

If you haven't already, set `ANDROID_HOME`:

**Windows (PowerShell — run once):**
```powershell
[System.Environment]::SetEnvironmentVariable(
  "ANDROID_HOME",
  "$env:LOCALAPPDATA\Android\Sdk",
  "User"
)
```

Then restart your terminal.

### Step 3 — Accept Android Licenses

```bash
flutter doctor --android-licenses
```

Accept all prompts.

### Step 4 — Run the App

```bash
flutter run
```

Connect an Android device (or start an emulator) before running.
The app targets **Android API 21+** (Android 5.0 and above).

On first launch the app silently connects to the manufacturer's MQTT broker.
Go to **Settings** to verify the connection status shows "Connected · Manufacturer Server".

---

## 8. Provisioning a New Device

Provisioning gives a fresh ESP32 its WiFi credentials, registers it with the
gateway, and makes it appear on the dashboard. Three entry methods are supported — all
lead to the same BLE provisioning flow.

### Method A — QR Code (standard)
```
Step 1 — Flash firmware to the ESP32 (one time)
Step 2 — Print or generate a QR code:
          dsgv://provision?name=DSGVHub_XXXXXX
          (XXXXXX = last 3 bytes of WiFi MAC, uppercase hex)
Step 3 — App → "Add Device" tab → point camera at QR
Step 4 — Enter a device name, select your Wi-Fi network, enter password
Step 5 — Tap "Provision Device"
```

### Method B — Manual pair code (QR damaged, label still readable)
```
Step 1 — App → "Add Device" → tap "Enter pair code manually"
Step 2 — Type the 6-character code from the device label (e.g. A1B2C3)
Step 3 — App connects to the device via BLE automatically
Step 4 — Continue as above
```

### Method C — Device picker (label fully destroyed)
```
Step 1 — App → "Add Device" → tap "Scan for nearby DSGV devices"
Step 2 — A list of all nearby DSGV devices appears — tap the right one
Step 3 — Continue as above
```

**What happens during provisioning:**

```
App ──(BLE)──► Device: { ssid, password, device_type, capabilities, relay_count }
Device connects to WiFi
Device ──(BLE)──► App: "success:<auth_token>:<wifi_mac>"
App ──(HTTPS)──► Gateway registerDevice: { device_id, auth_token }
Gateway: creates device_registry + device_configs entries in Workers KV
Device reboots ──► fetches broker config from the gateway ──► connects to MQTT
Device appears on Dashboard automatically
```

The **auth_token** is a 32-character hex string generated on the ESP32 using hardware entropy (`esp_random()`). It is exchanged only over BLE during provisioning — never over MQTT. It is the device's permanent credential for all future gateway and MQTT config operations.

---

## 9. Supported Hardware

| Chip | Architecture | Flash min | BLE | LEDC channels | Notes |
|------|-------------|-----------|-----|---------------|-------|
| ESP32-C3 | 1× RISC-V 160 MHz | 4 MB | 5.0 LE | 6 (LS only) | Recommended — compact, low cost |
| ESP32-C6 | 1× RISC-V 160 MHz | 4 MB | 5.0 LE | 6 (LS only) | Adds WiFi 6, Thread, Zigbee |
| ESP32-S3 | 2× Xtensa 240 MHz | 4 MB | 5.0 LE | 8 (LS only) | More GPIOs, USB-OTG |
| ESP32 (classic) | 2× Xtensa 240 MHz | 4 MB | 4.2 | 16 (HS + LS) | Legacy support |

> **Recommended starting point:** ESP32-C3 DevKit. Small, inexpensive, excellent BLE 5.0,
> fully supported by all firmware features, available from major suppliers.

---

## 10. Supported Device Types

| Preset (in App) | Capabilities broadcast | Relay outputs | Notes |
|-----------------|----------------------|---------------|-------|
| 1-Gang Switch | `relay` | 1 | |
| 2-Gang Switch | `relay`, `relay_2` | 2 | |
| 3-Gang Switch | `relay`, `relay_2`, `relay_3` | 3 | |
| 4-Gang Switch | `relay`, `relay_2`, `relay_3`, `relay_4` | 4 | |
| Dimmer | `relay`, `brightness` | 1 | LEDC PWM ch 0 |
| Colour Temperature | `relay`, `brightness`, `color_temp` | 1 | LEDC ch 1 (warm) + ch 2 (cool) |
| RGB Light | `relay`, `brightness`, `rgb` | 1 | LEDC ch 3–5 (R, G, B) |
| Temperature Sensor | `temperature`, `humidity` | 0 | NTC ADC or internal SOC sensor |
| Motion Sensor | `motion` | 0 | PIR input, ISR-driven |
| Contact Sensor | `contact` | 0 | Reed switch input |
| Thermostat | `temperature`, `hvac_mode` | 1 | Target temp + cool/heat/auto/off modes |

The app renders the exact controls for any combination of capabilities automatically —
no hardcoded screens per device type. Adding a new capability requires only a
new `case` in `schema_driven_ui_builder.dart` and the matching firmware handler.

---

## 11. Protocol Reference — MQTT Topics

All topics follow the pattern `devices/{device_id}/{type}` where `device_id` is the
device's WiFi MAC address as uppercase hex without separators (e.g. `AABBCCDDEEFF`).

| Topic | Direction | When | Payload format |
|-------|-----------|------|---------------|
| `devices/{id}/announce` | Device → Broker → App | On every MQTT connect | `{"device_id","name","capabilities":[],"local_ip","firmware_version","status"}` |
| `devices/{id}/telemetry` | Device → Broker → App | Every 30 s (default) | `{"power":true,"brightness":75,"temperature":24.5,...}` |
| `devices/{id}/command` | App → Broker → Device | On user action | Any subset of telemetry keys, e.g. `{"power":false}` |
| `devices/{id}/status` | Device → Broker → App | LWT on disconnect | `"offline"` |

> **Note:** The `devices/{id}/config` topic (used in older firmware for broker changes
> over MQTT) is superseded by the gateway. New firmware fetches config via HTTPS on boot.
> Do not send broker credentials over MQTT.

### Telemetry Payload Fields

| Field | Type | Device types |
|-------|------|-------------|
| `power` | `bool` | All switch/light types |
| `power_2`, `power_3`, `power_4` | `bool` | Multi-gang switches |
| `brightness` | `int` 0–100 | Dimmer, colour temp, RGB |
| `color_temp` | `int` 2000–6500 (Kelvin) | Colour temperature |
| `red`, `green`, `blue` | `int` 0–255 | RGB light |
| `temperature` | `float` °C | Sensor, thermostat |
| `humidity` | `float` % | Sensor |
| `motion` | `bool` | Motion sensor |
| `contact` | `bool` | Contact sensor (`true` = closed) |
| `target_temp` | `float` °C | Thermostat |
| `hvac_mode` | `string` `"cool"/"heat"/"auto"/"off"` | Thermostat |

---

## 12. Gateway Data Structure

`cloudflare_gateway/` stores two kinds of Workers KV keys. Both are only
reachable through the Worker's own route logic — KV has no public REST API of
its own the way Firebase RTDB did, so there's no separate "security rules"
layer to configure; the Worker's auth_token checks in `src/index.js` are the
only gate.

```
device_registry:AABBCCDDEEFF → {
  "auth_token":    "3F8A...C2D1",   ← 32-char hex, hardware entropy, PRIVATE
  "registered_at": 1717430400000,   ← Unix timestamp ms
  "last_seen":     1717430400000    ← Set once at registration, not updated per-boot
                                     ←   (keeps writes flat regardless of boot frequency —
                                     ←   see index.js's getDeviceConfig comment)
}

device_configs:AABBCCDDEEFF → {
  "broker_host":     "mqtt.yourdomain.com",
  "broker_port":     8883,
  "broker_tls":      true,
  "broker_username": "device_user",
  "broker_password": "s3cur3p@ss",
  "is_factory":      false,
  "updated_at":      1717516800000
}
```

### Gateway Routes

| Route | Called by | Purpose |
|----------|-----------|---------|
| `registerDevice` | App (after BLE provisioning) | Creates registry + seeds factory config |
| `getDeviceConfig` | Firmware (every boot) | Returns broker config after validating auth_token |
| `updateDeviceConfig` | App (Settings → Push broker) | Updates device's config in Workers KV |
| `revertDeviceToFactory` | App (Settings → Restore factory) | Resets config to factory broker |

---

## 13. Security Model

Understanding the security design is important before deploying to customers.

### auth_token

- Generated on the ESP32 using `esp_random()` — hardware entropy from the RF subsystem
- 128 bits (32 hex chars), unique per device, permanent
- Stored in NVS `DSGV_cfg` namespace — survives reboots, survives OTA
- **Never transmitted over MQTT** — only ever sent over BLE during provisioning
- Used as the authentication credential for all gateway route calls
- Compared using constant-time comparison (`safeEqual()`) in the Worker to prevent timing attacks

### Cloudflare Gateway

- `device_registry`/`device_configs` live in Workers KV, which has no public REST API of its own — the only way to read or write them is through the Worker's route handlers in `cloudflare_gateway/src/index.js`, which enforce the auth_token check on every route except the initial `registerDevice`
- The gateway's URL is not a secret — security relies entirely on the per-device auth_token
- No service account, no OAuth bridge, no third-party cloud provider in the trust chain — Workers reads/writes its own KV namespace directly

### MQTT

- Credentials (broker username/password) are stored in NVS after being fetched from the gateway over HTTPS
- They never travel over the MQTT wire
- TLS is enforced on the factory broker connection (`broker_tls: true` by default)
- The LWT topic (`devices/{id}/status = "offline"`) is the only MQTT message that does not carry auth

### BLE Provisioning

- BLE is inherently range-limited (typically < 10 m)
- The provisioning payload (WiFi credentials + auth_token) is encrypted by the BLE LE pairing layer
- No credentials are stored in the QR code — the QR code only contains the BLE device name

### Recommendations for Production

- Add a **Cloudflare Rate Limiting rule** (dashboard → your zone/Worker → Security → WAF → Rate limiting rules) to slow down brute-force `auth_token` guessing against the gateway — the Worker itself has no rate limiting built in
- Enable **NVS encryption** on the ESP32 (`idf.py menuconfig → Security → Enable flash encryption`) to protect stored credentials if flash is physically extracted
- Use **TLS client certificates** (mTLS) on your MQTT broker for zero-trust device authentication at scale

---

## 14. Configuration Reference

### `dsgv_config.h` — Firmware Constants

Located at `dsgv_firmware/components/dsgv_common/include/dsgv_config.h`.

| Constant | What it does | Default / Example |
|----------|-------------|-------------------|
| `GATEWAY_GET_CONFIG_URL` | Cloudflare Worker URL for broker config fetch | `https://dsgv-hub-gateway.{subdomain}.workers.dev/getDeviceConfig` |
| `GATEWAY_TIMEOUT_MS` | How long to wait for the gateway before using cached config | `10000` |
| `MQTT_CLOUD_HOST` | Factory MQTT broker hostname (must match app + gateway) | `mqtt.yourdomain.com` |
| `MQTT_CLOUD_PORT` | Factory MQTT broker port | `8883` |
| `MQTT_KEEPALIVE_SEC` | MQTT keep-alive interval | `60` |
| `DSGV_TELEMETRY_INTERVAL_MS` | How often devices publish sensor data | `30000` |
| `GPIO_BUTTON_PIN` | Factory reset button (hold 5 s) | Chip-specific |
| `GPIO_STATUS_LED_PIN` | Status LED | Chip-specific |

All GPIO pin maps are **selected automatically** based on `CONFIG_IDF_TARGET_*` at build time.
Do not manually edit pin defines unless you are using a custom PCB.

### `mqtt_config.dart` — App Constants

Located at `dsgv_hub_app/lib/domain/models/mqtt_config.dart`.

| Field | What it does |
|-------|-------------|
| `factoryDefault.host` | Manufacturer MQTT broker — must match `MQTT_CLOUD_HOST` in firmware |
| `factoryDefault.port` | Factory broker port (default `8883`) |
| `factoryDefault.useTls` | TLS on factory broker (default `true`) |

### `gateway_config_service.dart` — Gateway URL

Located at `dsgv_hub_app/lib/domain/services/gateway_config_service.dart`.

| Constant | What it does |
|----------|-------------|
| `_kGatewayBase` | `cloudflare_gateway/`'s deployed Worker URL (`https://<name>.<subdomain>.workers.dev`) |

---

## 15. Adding a New Device Type

The platform is designed to support new hardware with minimal code changes.

### App Side — Add a new capability

`device_type_registry.dart` is the single source of truth for every capability and
device type — the UI builder no longer hardcodes a switch-case per capability.

1. Open `lib/domain/services/device_type_registry.dart`
2. If the capability is new, add a `CapabilityDef` entry to `_capabilities` (label,
   icon, telemetry/command key, and min/max/step/unit if it's a range control)
3. Add (or extend) a `DeviceTypeDef` entry for the device type
4. `schema_driven_ui_builder.dart` reads the registry automatically — no UI code to write

### Firmware Side — Handle the new capability

1. Add the capability string to the announce payload in `dsgv_mqtt.c`
2. Handle the incoming command in the MQTT command handler (same file)
3. Add the hardware driver in `dsgv_gpio.c` if new GPIO control is needed

### Registration — No app update required

The app renders whatever capabilities the device broadcasts. If you ship a new device
type with a new capability, existing app installations automatically show the correct
controls the first time they see that device — no app store update needed.

---

## 16. Debugging and Monitoring

### Firmware Serial Monitor

```bash
idf.py monitor
# Press Ctrl+] to exit
```

Key log tags to watch:

| Tag | What it reports |
|-----|----------------|
| `DSGV_Gateway` | Gateway HTTPS fetch result, broker config applied |
| `DSGV_MQTT` | Connection attempts, topic publishes, incoming commands |
| `DSGV_cfg` | NVS config load/save, auth token generation |
| `DSGV_Prov` | BLE provisioning steps, credential receipt |
| `DSGV_OTA` | OTA download progress, verification, reboot |

### App Debug

```bash
flutter run --verbose          # Full Flutter output
flutter logs                   # Device logs only
```

### Gateway Logs

```bash
cd cloudflare_gateway
wrangler tail
```

Streams live logs from the deployed Worker — every request, including
errors thrown inside route handlers.

### MQTT Debugging

Use [MQTT Explorer](https://mqtt-explorer.com) (free desktop app) to:
- Subscribe to `devices/#` and watch all traffic
- Manually publish a command to a device: `devices/AABBCCDDEEFF/command` → `{"power":true}`
- Verify LWT messages (`devices/{id}/status = "offline"`) are being published

### Common Issues

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| App shows "Disconnected" in Settings | Wrong broker host or no internet | Check `MQTT_CLOUD_HOST` / custom broker settings |
| Device not appearing on dashboard after provisioning | BLE provisioning failed silently | Check serial monitor for `DSGV_Prov` logs |
| Gateway fetch fails on every boot | Wrong `GATEWAY_GET_CONFIG_URL` | Verify the Worker URL/subdomain in `dsgv_config.h` |
| Device connects to wrong broker after firmware update | NVS `mqtt_cfg` retained old config | Factory reset (hold BOOT 5 s) or call `nvs_flash_erase()` in debug |
| Build error: `esp_crt_bundle_attach` not found | Certificate bundle not enabled | Add `CONFIG_MBEDTLS_CERTIFICATE_BUNDLE=y` to `sdkconfig.defaults` |
| `flutter doctor` shows Android SDK missing | `ANDROID_HOME` not set | Set env var (see Part C, Step 2) |

---

## 17. Project Files at a Glance

| File | Purpose | Edit when |
|------|---------|----------|
| `dsgv_config.h` | Firmware constants — GPIO, broker URL, gateway URL | Porting to new hardware, changing broker |
| `dsgv_app_main.c` | Shared boot sequence, called by every device's `main.c` stub | Changing startup order or adding a global init step |
| `dsgv_events.c` / `.h` | GPIO ↔ MQTT event bus (decouples hardware from transport) | Adding a new event type or telemetry source |
| `mqtt_config.dart` | App's factory broker constant | Changing manufacturer broker |
| `gateway_config_service.dart` | `cloudflare_gateway/` Worker base URL | After deploying the gateway |
| `cloudflare_gateway/wrangler.toml` | Worker name, entry point, `DSGV_KV` namespace binding | After creating the KV namespace |
| `cloudflare_gateway/src/index.js` | Gateway route logic + `FACTORY_CONFIG_BASE` constant | Changing broker, adding new routes |
| `cloudflare_gateway/src/store.js` | Workers KV read/write wrapper | Rarely — only if the KV key scheme changes |
| `cloudflare_gateway/SETUP_GUIDE.md` | Full deploy walkthrough (CLI + dashboard) | Reference only |
| `device_type_registry.dart` | Single source of truth for capabilities + device types | Adding new device types |
| `schema_driven_ui_builder.dart` | Renders controls by reading the registry | Rarely — only for new *control widget kinds* |
| `device_group_notifier.dart` / `groups_screen.dart` | Rooms/groups state + batch commands | Changing group/room behaviour |
| `schedule_service.dart` / `schedule_sheet.dart` | Timed on/off schedules | Adding new schedule recurrence rules |
| `dsgv_mqtt.c` | MQTT connection, topic handling, telemetry, commands | Adding new MQTT features |
| `dsgv_gateway.c` | HTTPS fetch from the gateway's `getDeviceConfig` route, called from `dsgv_app_main()` | Extending config fields |
| `dsgv_provisioning.c` | BLE GATT provisioning protocol | Changing provisioning payload fields |
| `dsgv_captive_portal.c` | AP mode credential entry portal | Modifying the setup web page |
| `wifi_manager.c` | Wi-Fi connection, AP mode, credential storage | Adding connection modes |
| `FLASHING_GUIDE.md` | Wiring + flash commands per device type | Reference only |
| `PRE_PRODUCTION_GUIDE.md` | Production readiness checklist | Before shipping hardware |
| `IoT_APP_Design/Critical_Review.md` | Principal-engineer review of architecture + in-flight changes | Reference — predates the Cloudflare migration, historical context only |
| `IoT_APP_Design/Security_Review.md` | Static security review across firmware/app/gateway | Reference — before a security-sensitive release |
| `IoT_APP_Design/Production_Readiness_GoNoGo.md` | Go/No-Go checklist, updated per release candidate | Before shipping hardware |
| `TEST_CHECKLIST.md` | Hardware + app test checklist for all features | Before every release |

---

## 18. Recent Updates

### App

- **Rooms & Groups** — devices can be assigned to rooms and batch-controlled via
  named groups (`device_group.dart`, `device_group_notifier.dart`, `groups_screen.dart`).
  Groups are local-only (ObjectBox), never synced to the broker.
- **Device Type Registry** — capability-to-UI mapping was centralized into
  `device_type_registry.dart`. Adding a device type is now a one-file change
  instead of editing the UI builder's switch statement directly (see [§15](#15-adding-a-new-device-type)).
- **Schedules** — timed on/off schedules per device (`schedule_service.dart`,
  `schedule_sheet.dart`); the scheduler was fixed to align firing to clock-minute
  boundaries and to catch up correctly after the app resumes from background.
- **WiFi management** — in-app WiFi network scan list and bulk WiFi credential
  change across multiple devices at once.
- **Dashboard polish** — device naming, Matter-related naming cleanup, lazy camera
  init on the add-device flow, and general dashboard UI refinement.
- **OTA** — moved to a firmware-manifest approach (version/URL/hash resolved from
  a manifest) instead of hardcoding the binary URL per release.

### Firmware

- **`dsgv_common` component consolidation** — the old per-device `main/` and
  `include/` trees were fully migrated into the shared `dsgv_common` component.
  Every device's `main.c` is now a thin stub that calls `dsgv_app_main()`; the
  actual boot sequence lives in one place (`dsgv_app_main.c`).
- **Event-driven telemetry (`dsgv_events`)** — GPIO code no longer calls the MQTT
  publish function directly. It posts telemetry JSON onto a FreeRTOS queue; a
  consumer task publishes it asynchronously. This removes the hard compile-time
  dependency of GPIO on MQTT.
- **Relay/power-restore sync fix**, **COM port + IDF lock hardening** for the
  1-gang switch build, and other stability fixes — see `git log` for the full list.

### Gateway migrated off Firebase to Cloudflare (new)

The device-config gateway (`registerDevice`, `getDeviceConfig`,
`updateDeviceConfig`, `revertDeviceToFactory`) was Firebase Cloud Functions +
Realtime Database. Deploying Cloud Functions turned out to require the Blaze
(pay-as-you-go) plan — confirmed by direct deploy attempts — so the gateway
was rebuilt from scratch on **Cloudflare Workers + Workers KV**
(`cloudflare_gateway/`), which is free with no card required. No Firebase
project is part of this architecture anymore — `dsgv_gateway.c` (firmware,
renamed from `dsgv_firebase.c`) and `gateway_config_service.dart` (app,
renamed from `firebase_config_service.dart`) both talk to the Cloudflare
Worker now. See [§5](#5-part-a--cloudflare-gateway-setup) and
[`cloudflare_gateway/SETUP_GUIDE.md`](./cloudflare_gateway/SETUP_GUIDE.md).

### Engineering Review Docs

`IoT_APP_Design/` includes three review documents worth reading before a
production release: `Critical_Review.md` and `Security_Review.md` (both
predate the Cloudflare migration above — read for historical architecture
context, not as a description of the current gateway), and
`Production_Readiness_GoNoGo.md` (release checklist, currently **No-Go**
pending the items those reviews raised, principally around firmware OTA/Secure
Boot — unrelated to the gateway change).

---

<div align="center">
  <p>Built to commercial IoT standards — offline-first, credential-secure, single firmware binary for all hardware SKUs.</p>
  <p><em>De Socko Global Ventures</em></p>
</div>
