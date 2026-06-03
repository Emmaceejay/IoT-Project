<div align="center">
  <h1>DSGV Hub IoT Platform</h1>
  <p><strong>Full-stack commercial IoT platform — Flutter mobile app · ESP-IDF firmware · Firebase cloud gateway</strong></p>
  <p>
    Offline-first &nbsp;·&nbsp;
    BLE provisioning &nbsp;·&nbsp;
    Firebase-secured config &nbsp;·&nbsp;
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
5. [Part A — Firebase Setup](#5-part-a--firebase-setup)
6. [Part B — Firmware Setup](#6-part-b--firmware-setup)
7. [Part C — Mobile App Setup](#7-part-c--mobile-app-setup)
8. [Provisioning a New Device](#8-provisioning-a-new-device)
9. [Supported Hardware](#9-supported-hardware)
10. [Supported Device Types](#10-supported-device-types)
11. [Protocol Reference — MQTT Topics](#11-protocol-reference--mqtt-topics)
12. [Firebase Data Structure](#12-firebase-data-structure)
13. [Security Model](#13-security-model)
14. [Configuration Reference](#14-configuration-reference)
15. [Adding a New Device Type](#15-adding-a-new-device-type)
16. [Debugging and Monitoring](#16-debugging-and-monitoring)
17. [Project Files at a Glance](#17-project-files-at-a-glance)

---

## 1. What Is This?

DSGV Hub is a **production-ready, end-to-end IoT platform** built by De Socko Global Ventures. It consists of three parts that work together:

| Part | Technology | Purpose |
|------|-----------|---------|
| **Mobile App** | Flutter / Dart | Control devices, provision new ones, manage broker settings |
| **Firmware** | C / ESP-IDF 5.x | Runs on ESP32 devices — handles WiFi, MQTT, sensors, relays, OTA |
| **Cloud Gateway** | Firebase (Node.js Cloud Functions + Realtime Database) | Securely stores and delivers broker configuration to each device |

**The core idea is simple:**
- Flash the same firmware binary to any ESP32 device
- Scan a QR code in the app to provision it over Bluetooth
- The device appears on the dashboard automatically — no computer needed after flashing
- Change the MQTT broker at any time from the app — the change is written to Firebase and every device picks it up silently on its next boot

---

## 2. How It Works — Architecture

### The Three Communication Channels

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          MOBILE APP (Flutter)                           │
└───────────────┬─────────────────────────┬───────────────────────────────┘
                │                         │
   BLE (once,   │                         │  HTTPS (Cloud Functions)
   provisioning)│                         │  Register device
                │                         │  Push broker config
                │                         │  Restore factory broker
                ▼                         ▼
┌──────────────────────┐    ┌────────────────────────────┐
│   ESP32 Device       │    │   Firebase                 │
│                      │    │   ┌──────────────────────┐ │
│  On boot:            │    │   │ device_registry      │ │
│  1. WiFi connect     │    │   │  auth_token (private)│ │
│  2. HTTPS fetch ─────┼────┼──►│ device_configs       │ │
│     broker config    │◄───┼───│  broker settings     │ │
│  3. MQTT connect     │    │   └──────────────────────┘ │
│                      │    └────────────────────────────┘
└──────────┬───────────┘
           │  MQTT (ongoing)
           │  telemetry, commands, status
           ▼
┌──────────────────────┐
│   MQTT Broker        │
│  (your server or     │
│   cloud broker)      │
└──────────────────────┘
```

### MQTT is for Control. Firebase is for Configuration.

| Channel | Used for | Security |
|---------|---------|---------|
| **MQTT** | Live telemetry, relay commands, device status | Auth token in every config command |
| **Firebase HTTPS** | Broker hostname, port, TLS flag, credentials | auth_token validated by Cloud Function |
| **BLE** | First-time WiFi credentials, device type, auth token exchange | Physical proximity required |

Credentials (broker username/password) **never travel over MQTT**. They live in Firebase and are fetched by the device directly over HTTPS.

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
- Tap **Push broker to all devices** → Firebase is updated → devices pick it up on next reboot

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
│   │   │   ├── datasources/         # ObjectBox implementation
│   │   │   ├── models/              # DeviceEntity (database schema)
│   │   │   └── repositories/        # DeviceRepository interface
│   │   ├── domain/
│   │   │   ├── models/              # MatterDevice, MqttConfig
│   │   │   └── services/
│   │   │       ├── device_manager.dart          # Central state engine (AsyncNotifier)
│   │   │       ├── mqtt_service.dart            # MQTT client + factory/custom mode
│   │   │       ├── firebase_config_service.dart # Firebase Cloud Function client
│   │   │       ├── ble_provisioning_service.dart
│   │   │       ├── local_http_service.dart
│   │   │       ├── ota_service.dart
│   │   │       └── telemetry_service.dart
│   │   └── presentation/
│   │       ├── screens/             # Dashboard, Pairing, Settings, Device Detail
│   │       └── widgets/
│   │           ├── app_shell.dart              # Root nav shell (3 tabs)
│   │           ├── device_card.dart            # Expandable device card
│   │           └── schema_driven_ui_builder.dart # Renders controls from capabilities
│   ├── functions/                   ← Firebase Cloud Functions (Node.js)
│   │   ├── index.js                 # registerDevice, getDeviceConfig, updateDeviceConfig, revertDeviceToFactory
│   │   └── package.json
│   ├── firebase.json                # Firebase project config
│   ├── .firebaserc                  # Firebase project ID binding
│   ├── database.rules.json          # Realtime Database security rules
│   └── FIREBASE_SETUP_GUIDE.md     # Full Firebase setup walkthrough
│
├── dsgv_firmware/                   ← ESP32 firmware (C / ESP-IDF 5.x)
│   ├── components/
│   │   └── dsgv_common/
│   │       ├── include/
│   │       │   ├── dsgv_config.h          # GPIO maps, MQTT endpoints, Firebase URL
│   │       │   ├── dsgv_device_config.h   # Runtime config struct
│   │       │   └── dsgv_firebase.h        # Firebase fetch API
│   │       ├── config/
│   │       │   └── dsgv_device_config.c   # NVS load/save with bounds validation
│   │       ├── firebase/
│   │       │   └── dsgv_firebase.c        # HTTPS fetch broker config from Firebase
│   │       ├── gpio/
│   │       │   └── dsgv_gpio.c            # LEDC PWM, relay, ISR sensors
│   │       ├── mqtt/
│   │       │   └── dsgv_mqtt.c            # MQTT connect, announce, telemetry, commands
│   │       ├── http/
│   │       │   └── dsgv_http_server.c     # LAN REST API (/status, /command, /ota)
│   │       ├── provisioning/
│   │       │   └── dsgv_provisioning.c    # NimBLE GATT WiFi provisioning
│   │       └── ota/
│   │           └── dsgv_ota.c             # HTTPS OTA with SHA-256 verification
│   └── devices/
│       ├── switch/                  # 1–4 gang relay switch
│       ├── dimmer/                  # LEDC PWM dimmer
│       ├── rgb/                     # RGB + CCT light
│       ├── sensor/                  # Temperature, humidity, motion, contact
│       └── thermostat/              # HVAC controller
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
| Firebase CLI | Latest | `npm install -g firebase-tools` |

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

## 5. Part A — Firebase Setup

> **Do this first.** Both the app and firmware need a deployed Firebase project.

### Step 1 — Create Firebase Project

1. Go to https://console.firebase.google.com
2. Click **Add project** → name it (e.g. `dsgv-hub`) → disable Google Analytics → **Create project**

### Step 2 — Enable Realtime Database

In the Firebase Console left sidebar:
**Build → Realtime Database → Create database** → choose a region → **Start in locked mode** → **Enable**

### Step 3 — Get Your Project ID

Click the **gear icon** (top-left) → **Project Settings → General** → copy your **Project ID** (e.g. `dsgv-hub-a1b2c`).

### Step 4 — Update the Three Constants

Replace `YOUR_PROJECT_ID` in these files:

```
dsgv_hub_app/.firebaserc                          line 3
dsgv_hub_app/lib/domain/services/firebase_config_service.dart   line 10
dsgv_firmware/components/dsgv_common/include/dsgv_config.h      line 33
```

Also replace `mqtt.dsgv.io` with your real MQTT broker hostname in:
```
dsgv_hub_app/lib/domain/models/mqtt_config.dart                 line 10
dsgv_firmware/components/dsgv_common/include/dsgv_config.h      line 39
dsgv_hub_app/functions/index.js                                 line 18
```

> All three broker hostname values must be identical or "Restore factory broker"
> will send devices to a different address than the firmware factory default.

### Step 5 — Deploy Cloud Functions and Database Rules

```bash
# Log in to Firebase
firebase login

# Install Cloud Function dependencies
cd dsgv_hub_app/functions
npm install
cd ..

# Deploy everything
firebase deploy
```

Expected output:
```
✔  functions[registerDevice]:        Deployed
✔  functions[getDeviceConfig]:       Deployed
✔  functions[updateDeviceConfig]:    Deployed
✔  functions[revertDeviceToFactory]: Deployed
✔  database: Rules deployed
```

For the full Firebase walkthrough including verification steps and troubleshooting,
see **[dsgv_hub_app/FIREBASE_SETUP_GUIDE.md](./dsgv_hub_app/FIREBASE_SETUP_GUIDE.md)**.

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

### Step 5 — Wire Up the Firebase Fetch in main.c

In each device's `main.c`, call `dsgv_firebase_fetch_config()` **after WiFi connects, before starting MQTT**:

```c
#include "dsgv_firebase.h"

// After wifi_connect() returns successfully:
ESP_LOGI(TAG, "Fetching broker config from Firebase...");
dsgv_firebase_fetch_config();   // Uses NVS cache automatically if Firebase is unreachable

// Then start MQTT as usual:
dsgv_mqtt_start();
```

### Step 6 — Add the Firebase Source File to CMakeLists.txt

In `components/dsgv_common/CMakeLists.txt`, add to `SRCS` and `REQUIRES`:

```cmake
idf_component_register(
    SRCS
        # ... existing files ...
        "firebase/dsgv_firebase.c"      # ← ADD
    INCLUDE_DIRS "include"
    REQUIRES
        # ... existing requires ...
        esp_http_client                 # ← ADD
        mbedtls                         # ← ADD
)
```

### Step 7 — Build and Flash

```bash
idf.py build
idf.py -p COM5 flash monitor    # Replace COM5 with your port (COMx on Windows, /dev/tty... on Mac/Linux)
```

On first boot you should see:
```
I (xxxx) DSGV_Firebase: Broker config updated: mqtt.yourdomain.com:8883 (TLS=1)
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

Provisioning is the process of giving a fresh ESP32 its WiFi credentials and device type, then registering it in Firebase. It requires physical proximity (Bluetooth range) to the device.

```
Step 1 — Flash firmware to the ESP32 (one time)
Step 2 — Print or generate a QR code:
          dsgv://provision?name=DSGVHub_XXXXXX
          (last 6 chars = last 3 bytes of WiFi MAC, uppercase hex)
Step 3 — In the app: tap "Add Device" tab
Step 4 — Point camera at the QR code
Step 5 — Enter a device name (e.g. "Kitchen Switch")
Step 6 — Select the device type preset (e.g. "2-Gang Switch")
Step 7 — Enter your WiFi network SSID and password
Step 8 — Tap "Provision Device"
```

**What happens during provisioning:**

```
App ──(BLE)──► Device: { ssid, password, device_type, capabilities, relay_count }
Device connects to WiFi
Device ──(BLE)──► App: "success:<auth_token>:<wifi_mac>"
App ──(HTTPS)──► Firebase registerDevice: { device_id, auth_token }
Firebase: creates device_registry + device_configs entries
Device reboots ──► fetches broker config from Firebase ──► connects to MQTT
Device appears on Dashboard automatically
```

The **auth_token** is a 32-character hex string generated on the ESP32 using hardware entropy (`esp_random()`). It is exchanged only over BLE during provisioning — never over MQTT. It is the device's permanent credential for all future Firebase and MQTT config operations.

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
> over MQTT) is superseded by Firebase. New firmware fetches config via HTTPS on boot.
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

## 12. Firebase Data Structure

The Realtime Database has two top-level paths. Both are locked to direct client access —
all reads and writes go through Cloud Functions.

```
{
  "device_registry": {
    "AABBCCDDEEFF": {
      "auth_token":    "3F8A...C2D1",   ← 32-char hex, hardware entropy, PRIVATE
      "registered_at": 1717430400000,   ← Unix timestamp ms
      "last_seen":     1717516800000    ← Updated on every getDeviceConfig call
    }
  },
  "device_configs": {
    "AABBCCDDEEFF": {
      "broker_host":     "mqtt.yourdomain.com",
      "broker_port":     8883,
      "broker_tls":      true,
      "broker_username": "device_user",
      "broker_password": "s3cur3p@ss",
      "is_factory":      false,
      "updated_at":      1717516800000
    }
  }
}
```

### Cloud Functions

| Function | Called by | Purpose |
|----------|-----------|---------|
| `registerDevice` | App (after BLE provisioning) | Creates registry + seeds factory config |
| `getDeviceConfig` | Firmware (every boot) | Returns broker config after validating auth_token |
| `updateDeviceConfig` | App (Settings → Push broker) | Updates device's config in Firebase |
| `revertDeviceToFactory` | App (Settings → Restore factory) | Resets config to factory broker |

---

## 13. Security Model

Understanding the security design is important before deploying to customers.

### auth_token

- Generated on the ESP32 using `esp_random()` — hardware entropy from the RF subsystem
- 128 bits (32 hex chars), unique per device, permanent
- Stored in NVS `DSGV_cfg` namespace — survives reboots, survives OTA
- **Never transmitted over MQTT** — only ever sent over BLE during provisioning
- Used as the authentication credential for all Firebase Cloud Function calls
- Compared using constant-time comparison in the Cloud Function to prevent timing attacks

### Firebase

- `device_registry` auth tokens are stored in a path that security rules lock to `false` — no client (app or device) can read them directly, only Cloud Functions via Admin SDK
- `device_configs` is similarly locked — all config reads and writes go through Cloud Functions
- The Cloud Function URL and the Firebase `apiKey` are not secrets — security relies entirely on the per-device auth_token

### MQTT

- Credentials (broker username/password) are stored in NVS after being fetched from Firebase over HTTPS
- They never travel over the MQTT wire
- TLS is enforced on the factory broker connection (`broker_tls: true` by default)
- The LWT topic (`devices/{id}/status = "offline"`) is the only MQTT message that does not carry auth

### BLE Provisioning

- BLE is inherently range-limited (typically < 10 m)
- The provisioning payload (WiFi credentials + auth_token) is encrypted by the BLE LE pairing layer
- No credentials are stored in the QR code — the QR code only contains the BLE device name

### Recommendations for Production

- Enable **Firebase App Check** to prevent unauthorised callers hitting your Cloud Functions
- Enable **NVS encryption** on the ESP32 (`idf.py menuconfig → Security → Enable flash encryption`) to protect stored credentials if flash is physically extracted
- Use **TLS client certificates** (mTLS) on your MQTT broker for zero-trust device authentication at scale

---

## 14. Configuration Reference

### `dsgv_config.h` — Firmware Constants

Located at `dsgv_firmware/components/dsgv_common/include/dsgv_config.h`.

| Constant | What it does | Default / Example |
|----------|-------------|-------------------|
| `FIREBASE_GET_CONFIG_URL` | Cloud Function URL for broker config fetch | `https://us-central1-{id}.cloudfunctions.net/getDeviceConfig` |
| `FIREBASE_TIMEOUT_MS` | How long to wait for Firebase before using cached config | `10000` |
| `MQTT_CLOUD_HOST` | Factory MQTT broker hostname (must match app + Firebase) | `mqtt.yourdomain.com` |
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

### `firebase_config_service.dart` — App Cloud Function URL

Located at `dsgv_hub_app/lib/domain/services/firebase_config_service.dart`.

| Constant | What it does |
|----------|-------------|
| `_kFunctionsBase` | Firebase Cloud Functions base URL — must contain your project ID |

---

## 15. Adding a New Device Type

The platform is designed to support new hardware with minimal code changes.

### App Side — Add a new capability control

1. Open `lib/presentation/widgets/schema_driven_ui_builder.dart`
2. Add a new `case 'your_capability':` in the `_buildControl()` switch
3. Return the appropriate Flutter widget (slider, toggle, display, etc.)
4. The control will appear automatically for any device that broadcasts this capability

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
| `DSGV_Firebase` | Firebase HTTPS fetch result, broker config applied |
| `DSGV_MQTT` | Connection attempts, topic publishes, incoming commands |
| `DSGV_cfg` | NVS config load/save, auth token generation |
| `DSGV_Prov` | BLE provisioning steps, credential receipt |
| `DSGV_OTA` | OTA download progress, verification, reboot |

### App Debug

```bash
flutter run --verbose          # Full Flutter output
flutter logs                   # Device logs only
```

### Firebase Function Logs

```bash
firebase functions:log
# Or live stream:
firebase functions:log --follow
```

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
| Firebase fetch fails on every boot | Wrong `FIREBASE_GET_CONFIG_URL` | Verify project ID in `dsgv_config.h` |
| Device connects to wrong broker after firmware update | NVS `mqtt_cfg` retained old config | Factory reset (hold BOOT 5 s) or call `nvs_flash_erase()` in debug |
| Build error: `esp_crt_bundle_attach` not found | Certificate bundle not enabled | Add `CONFIG_MBEDTLS_CERTIFICATE_BUNDLE=y` to `sdkconfig.defaults` |
| `flutter doctor` shows Android SDK missing | `ANDROID_HOME` not set | Set env var (see Part C, Step 2) |

---

## 17. Project Files at a Glance

| File | Purpose | Edit when |
|------|---------|----------|
| `dsgv_config.h` | Firmware constants — GPIO, broker URL, Firebase URL | Porting to new hardware, changing broker |
| `mqtt_config.dart` | App's factory broker constant | Changing manufacturer broker |
| `firebase_config_service.dart` | Cloud Function base URL | After creating Firebase project |
| `.firebaserc` | Firebase project ID | After creating Firebase project |
| `functions/index.js` | Cloud Function logic + `FACTORY_CONFIG` constant | Changing broker, adding new functions |
| `database.rules.json` | Realtime Database security rules | Never — rules are intentionally fully locked |
| `schema_driven_ui_builder.dart` | Maps capability strings to UI controls | Adding new device types |
| `dsgv_mqtt.c` | MQTT connection, topic handling, telemetry, commands | Adding new MQTT features |
| `dsgv_firebase.c` | HTTPS fetch from Firebase Cloud Function | Extending config fields (e.g. adding auth credentials) |
| `dsgv_provisioning.c` | BLE GATT provisioning protocol | Changing provisioning payload fields |
| `FIREBASE_SETUP_GUIDE.md` | Step-by-step Firebase setup with verification | Reference only |
| `FLASHING_GUIDE.md` | Wiring + flash commands per device type | Reference only |
| `PRE_PRODUCTION_GUIDE.md` | Production readiness checklist | Before shipping hardware |

---

<div align="center">
  <p>Built to commercial IoT standards — offline-first, credential-secure, single firmware binary for all hardware SKUs.</p>
  <p><em>De Socko Global Ventures</em></p>
</div>
