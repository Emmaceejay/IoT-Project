<div align="center">
  <h1>DSGV Hub IoT Platform</h1>
  <p><strong>Full-stack IoT platform — Flutter mobile app + ESP-IDF firmware for ESP32</strong></p>
  <p>Offline-first · Dual-broker MQTT · BLE provisioning · Schema-driven UI · OTA updates · Authenticated broker control</p>
</div>

---

## Overview

DSGV Hub is a production-ready IoT platform that pairs a Flutter mobile application with custom ESP-IDF firmware running on ESP32 devices. The platform is designed around three principles:

- **Zero vendor lock-in** — works with any MQTT broker (EMQX, HiveMQ, Mosquitto, AWS IoT Core)
- **One firmware binary, any device type** — runtime SKU configuration via BLE provisioning means the same `.bin` file powers a 1-gang switch, a 4-gang switch, an RGB light, a thermostat, or a sensor node
- **Offline-first** — the app operates fully from a local ObjectBox cache; commands reach the device over local HTTP before even touching the network

---

## Architecture

### Transport Hierarchy

When the user taps a control in the app, commands are routed in priority order:

```
1. Local HTTP (same LAN, sub-10 ms)   — if device has a known IP
2. MQTT cloud broker (TLS)            — primary remote path
3. MQTT local broker (Mosquitto LAN)  — automatic fallback if cloud is unreachable
```

The UI performs an optimistic update immediately — it never waits for a network round-trip before reflecting the change.

### App Layer — Flutter / Riverpod / ObjectBox

```
lib/
├── core/                    # ObjectBox store, app-wide providers
├── data/
│   ├── datasources/         # ObjectBoxDeviceDatasource
│   └── repositories/        # DeviceRepository interface
├── domain/
│   ├── models/              # MatterDevice, MatterDeviceState
│   └── services/
│       ├── device_manager.dart          # AsyncNotifier — central state engine
│       ├── mqtt_service.dart            # Dual-broker MQTT, lifecycle reconnect
│       ├── local_http_service.dart      # LAN direct transport
│       ├── ble_provisioning_service.dart # NimBLE GATT provisioning client
│       ├── matter_commissioning_service.dart
│       └── telemetry_service.dart
└── presentation/
    ├── screens/             # Dashboard, device detail, pairing, settings
    └── widgets/
        └── schema_driven_ui_builder.dart  # Renders controls from capability list
```

**Key design decisions:**

| Component | Choice | Reason |
|---|---|---|
| State management | Riverpod `AsyncNotifier` | Granular rebuild control, testable |
| Local database | ObjectBox | High-throughput, reactive, no-ORM overhead |
| MQTT client | mqtt_client | Pure Dart, no native dependency |
| BLE | flutter_blue_plus | Reliable Android + iOS BLE scanning |

### Firmware Layer — ESP-IDF 5.x / C

```
dsgv_firmware/
├── include/
│   ├── dsgv_config.h           # Per-chip GPIO maps, MQTT endpoints, compile-time defaults
│   └── dsgv_device_config.h    # Runtime config struct (NVS-backed)
└── main/
    ├── main.c                   # Boot sequence: NVS → config load → GPIO → MQTT → HTTP
    ├── config/
    │   └── dsgv_device_config.c # NVS load/save with GPIO bounds validation
    ├── gpio/
    │   └── dsgv_gpio.c         # LEDC PWM (6 ch, 5 kHz, 10-bit), relay, ISR sensors
    ├── mqtt/
    │   └── dsgv_mqtt.c         # Dual-broker connect, announce, telemetry, command handler
    ├── http/
    │   └── dsgv_http_server.c  # LAN REST API (/status, /command, /ota)
    ├── provisioning/
    │   └── dsgv_provisioning.c # NimBLE GATT Wi-Fi + device config provisioning
    └── ota/
        └── dsgv_ota.c          # HTTPS OTA into dual-bank partition
```

---

## Features

### Mobile App

- **Schema-driven UI** — devices broadcast a `capabilities` JSON array on boot; the app renders the exact controls needed with no hardcoded per-device screens
- **Dual-broker MQTT** — connects to a cloud broker first, silently falls back to a local Mosquitto instance if the internet is unavailable
- **App lifecycle reconnect** — MQTT connection is automatically restored when the app returns from background
- **Optimistic UI** — state changes reflect instantly in the UI before network confirmation
- **BLE provisioning** — onboards new devices over Bluetooth without touching a computer
- **Device presets** — 11 built-in presets (1–4 gang switch, dimmer, colour temp, RGB, sensors, thermostat) configurable from the pairing screen
- **OTA trigger** — firmware updates can be initiated from the app
- **Broker reconfiguration** — the Settings screen lets you push a new MQTT broker to every provisioned device in one tap; a factory-revert button reconnects them to the original server without a reflash

### Firmware

- **One binary, any SKU** — device type, capabilities, relay count, and GPIO pins are stored in NVS and set by the app during first-boot BLE provisioning
- **Multi-chip support** — single codebase supports ESP32-C3, ESP32-C6, ESP32-S3, and classic ESP32; pin maps are selected automatically at build time
- **Multi-gang relay** — up to 4 independently controlled relay outputs per device
- **LEDC PWM** — 6 channels (dimmer, warm white, cool white, R, G, B) at 5 kHz / 10-bit resolution
- **Dual-broker MQTT** — mirrors the app's strategy; cloud TLS → local Mosquitto fallback
- **Sensor pipeline** — SOC internal temperature sensor (C3/C6/S3) with NTC ADC fallback, PIR motion, and reed-contact inputs
- **LAN HTTP server** — REST API for zero-latency local control when the app and device are on the same network
- **Signed OTA** — HTTPS binary fetch with SHA-256 verification into a dual-bank partition
- **Auth-token broker control** — every device generates a 128-bit hardware-entropy token at first boot (exchanged only over BLE, never over MQTT); broker-change commands must carry this token; a 60-second FreeRTOS rollback timer automatically reverts to the previous broker if the new one is unreachable

---

## Supported Hardware

| Chip | Cores | Flash | BLE | LEDC ch | Notes |
|---|---|---|---|---|---|
| ESP32-C3 | 1 × RISC-V | ≥ 4 MB | 5.0 LE | 6 (LS) | Recommended — compact, low cost |
| ESP32-C6 | 1 × RISC-V | ≥ 4 MB | 5.0 LE | 6 (LS) | Adds Wi-Fi 6, Thread/Zigbee |
| ESP32-S3 | 2 × Xtensa | ≥ 4 MB | 5.0 LE | 8 (LS) | Dual-core, more GPIOs |
| ESP32 classic | 2 × Xtensa | ≥ 4 MB | 4.2 | 16 (HS+LS) | Legacy support |

---

## Supported Device Types

| Preset | Capabilities | Relay count |
|---|---|---|
| 1-Gang Switch | `relay` | 1 |
| 2-Gang Switch | `relay`, `relay_2` | 2 |
| 3-Gang Switch | `relay`, `relay_2`, `relay_3` | 3 |
| 4-Gang Switch | `relay`, `relay_2`, `relay_3`, `relay_4` | 4 |
| Dimmer | `relay`, `dimmer` | 1 |
| Colour Temperature | `relay`, `color_temperature` | 1 |
| RGB Light | `relay`, `rgb_light` | 1 |
| Temperature Sensor | `temperature_sensor` | 0 |
| Motion Sensor | `motion_sensor` | 0 |
| Contact Sensor | `contact_sensor` | 0 |
| Thermostat | `temperature_sensor`, `hvac_control` | 1 |

---

## Repository Structure

```
IoT-Project/
├── dsgv_hub_app/          # Flutter mobile application (Dart)
├── dsgv_firmware/         # ESP32 firmware (C / ESP-IDF 5.x)
├── FLASHING_GUIDE.md       # Step-by-step: configure, build, flash, and wire every device type
└── README.md
```

---

## Getting Started

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) 3.x
- [ESP-IDF 5.x](https://docs.espressif.com/projects/esp-idf/en/stable/esp32/get-started/)
- An ESP32-C3, C6, S3, or classic ESP32 development board
- An MQTT broker (local Mosquitto or any cloud broker)

### Flash the firmware

See **[FLASHING_GUIDE.md](./FLASHING_GUIDE.md)** for full step-by-step instructions covering:

- Tool installation (Windows, Mac, Linux)
- Wiring diagrams for every device type
- Editing `dsgv_config.h` for each device SKU
- `idf.py set-target / build / flash / monitor` commands
- Using the app's BLE provisioning to configure device type without reflashing

Quick path for an ESP32-C3 with a 1-gang switch:

```bash
cd IoT-Project/dsgv_firmware
idf.py set-target esp32c3
idf.py build
idf.py -p COM5 flash monitor     # replace COM5 with your port
```

### Run the mobile app

```bash
cd IoT-Project/dsgv_hub_app
flutter pub get
flutter run
```

On first launch, go to **Settings** and enter your MQTT broker details. The app will connect and immediately show any devices that are already online.

### Provision a new device

1. Flash the firmware to the ESP32
2. In the app, go to **Add Device** and tap **Scan QR Code**
3. Scan the label on the device (`DSGV://provision?name=DSGVHub_XXXXXX`)
4. Select the device type preset (e.g. "2-Gang Switch")
5. Enter Wi-Fi credentials and tap **Provision**

The device connects to your network, publishes an MQTT announce message, and appears in the dashboard automatically. The app silently stores the per-device auth token during provisioning — this token is required later for any broker reconfiguration commands.

---

## Configuration Reference

### `dsgv_firmware/include/dsgv_config.h`

| Define | Purpose | Example |
|---|---|---|
| `dsgv_DEVICE_TYPE` | Type prefix in auto-generated device name | `"Switch"` |
| `dsgv_DEVICE_CAPABILITIES` | JSON array sent in MQTT announce | `"[\"relay\",\"dimmer\"]"` |
| `dsgv_RELAY_COUNT` | Number of relay outputs (1–4) | `2` |
| `dsgv_RELAY_PINS` | GPIO array for active relays | `{ GPIO_NUM_2, GPIO_NUM_3 }` |
| `MQTT_CLOUD_HOST` | Primary MQTT broker hostname | `"broker.emqx.io"` |
| `MQTT_LOCAL_HOST` | Fallback local broker IP | `"192.168.1.100"` |
| `dsgv_TELEMETRY_INTERVAL_MS` | Sensor publish interval | `30000` |

> **Note:** These compile-time defaults are only used on a fresh flash. Once the device is provisioned via the app, the NVS runtime config takes precedence and persists across reboots. To return to defaults, hold the BOOT button for 5 seconds (factory reset).

---

## Protocol Contract

The app and firmware communicate over MQTT using these topic patterns:

| Topic | Direction | Payload |
|---|---|---|
| `devices/{id}/announce` | Device → App | `{"device_id","name","capabilities","local_ip","firmware","status"}` |
| `devices/{id}/telemetry` | Device → App | `{"power","brightness","color_temp","red","green","blue","current_temp","humidity","motion","contact","target_temp","mode"}` |
| `devices/{id}/command` | App → Device | Any subset of telemetry keys |
| `devices/{id}/status` | Device → App | `"online"` / `"offline"` (LWT) |
| `devices/{id}/ota-trigger` | App → Device | `{"url","hash"}` |
| `devices/{id}/config` | App → Device | `{"auth_token","mqtt_host","mqtt_port","mqtt_use_tls"}` or `{"auth_token","revert_to_factory":true}` |

---

*Built to professional IoT standards — offline-first, transport-agnostic, single firmware binary for all hardware SKUs.*
