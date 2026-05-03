# Nexus Firmware — ESP32 Dual-Stack (Matter + MQTT)

## Overview
This workspace contains the C/C++ firmware for all Nexus Hub-compatible ESP32 devices.
It runs two communication stacks simultaneously:
1. **Matter (CHIP SDK)** — handles local commissioning via Apple/Google/Alexa
2. **MQTT Client** — reports telemetry to Nexus Hub app via EMQX or local Mosquitto

## Workspace Structure
```
nexus_firmware/
├── src/
│   ├── matter/        ← Matter CHIP endpoint definitions
│   ├── mqtt/          ← MQTT client + LWT + TLS
│   ├── ota/           ← OTA firmware update handler
│   ├── gpio/          ← Hardware abstraction (relay, dimmer, sensors)
│   └── wifi/          ← Wi-Fi manager + credential storage (NVS)
├── include/           ← Shared header files
├── test/              ← Unit tests (Unity framework)
└── docs/              ← Pinouts, hardware specs
```

## Prerequisites
- **Toolchain:** ESP-IDF v5.2+ via the **official VS Code ESP-IDF Extension**
- **SDK:** `esp-matter` (Espressif's official Matter SDK)
- **Target Boards:** Any ESP with Matter capability (`ESP32`, `ESP32-C3`, `ESP32-S3`, `ESP32-H2`)

## Getting Started (VS Code)
1. Install the "Espressif IDF" extension in VS Code and run the setup wizard.
2. Clone `esp-matter` into your system and run its `install.sh`.
3. Open this folder in VS Code.
4. Click the **ESP-IDF: Set Espressif device target** button in the bottom status bar and select your chip (e.g., `esp32c3`).
5. Click **Build**, then **Flash**, then **Monitor**.

## Building Different Types of Devices
The `nexus_config.h` file acts as the single source of truth for the device identity. The app reads the `capabilities` JSON payload reported by the device to automatically adjust its UI.
To build a thermostat instead of a light switch:
1. Change the GPIO pins in `nexus_config.h`.
2. Update the Matter Endpoint in `main/matter/matter_endpoint.c` to use the Thermostat cluster instead of the On/Off Light cluster.
3. Update the MQTT telemetry payload in `nexus_mqtt.c` to send `{"capabilities": ["hvac_control", "temperature_sensor"]}`.

## Key Design Rules
- Wi-Fi credentials and MQTT broker config stored in NVS (Non-Volatile Storage) partition
- Matter Node ID and fabric data stored in dedicated Matter NVS partition
- MQTT client runs as a FreeRTOS task independent of the Matter event loop
- LWT topic: `devices/{mac_id}/status` payload: `offline` (retained)
- On boot: publish `online` to same topic (retained)
