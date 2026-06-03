# DSGV Firmware — ESP32 Multi-Device Monorepo

**ESP-IDF 5.x · C / FreeRTOS · WiFi + MQTT + BLE + HTTP + mDNS + OTA**

One firmware codebase for all 11 DSGV Hub device types. Flash the same build system
to any supported ESP32 chip — relay switches, dimmers, RGB lights, sensors, thermostats.

---

## Table of Contents

1. [What the Firmware Does](#1-what-the-firmware-does)
2. [Directory Structure](#2-directory-structure)
3. [Prerequisites](#3-prerequisites)
4. [Build System — the Makefile](#4-build-system--the-makefile)
5. [All 11 Device Types](#5-all-11-device-types)
6. [Startup Sequence](#6-startup-sequence)
7. [Key Design Concepts](#7-key-design-concepts)
8. [Component Reference](#8-component-reference)
9. [Serial Log Tags](#9-serial-log-tags)
10. [Adding a New Device Type](#10-adding-a-new-device-type)
11. [Partition Tables](#11-partition-tables)
12. [Key Files at a Glance](#12-key-files-at-a-glance)

---

## 1. What the Firmware Does

The firmware runs on an ESP32 device and handles everything below the cloud:

| Layer | What it does | File |
|-------|-------------|------|
| **BLE provisioning** | Receives WiFi credentials + device type from the Flutter app over Bluetooth on first setup | `dsgv_provisioning.c` |
| **WiFi** | Connects to home network, handles reconnects, triggers mDNS restart on IP change | `wifi_manager.c` |
| **Firebase fetch** | Fetches MQTT broker config (host, port, TLS, credentials) over HTTPS on every boot | `dsgv_firebase.c` |
| **mDNS** | Advertises `_dsgv._tcp` and `_http._tcp` so the app can find the device on the LAN without knowing its IP | `dsgv_mdns.c` |
| **MQTT** | Announces device, publishes telemetry every 30 s, receives and handles commands | `dsgv_mqtt.c` |
| **HTTP REST** | Local LAN API (`/status`, `/command`, `/ota`) for direct control without going through the broker | `dsgv_http_server.c` |
| **GPIO / hardware** | Relay switching, LEDC PWM (dimmer, RGB, colour temp), ISR-driven sensor inputs | `dsgv_gpio.c` |
| **OTA** | Downloads and verifies firmware updates over HTTPS with SHA-256 checking and automatic rollback | `dsgv_ota.c` |
| **NVS** | Persists WiFi credentials, auth token, broker config, and device type across reboots and OTA updates | `dsgv_device_config.c` |

**What it does NOT do:** Matter, Zigbee, Thread, or any other protocol stack. Those were
evaluated and dropped. MQTT over TLS + Firebase config delivery covers all commercial requirements
at a fraction of the certification cost.

---

## 2. Directory Structure

```
dsgv_firmware/
│
├── components/
│   └── dsgv_common/          ← Shared component — compiled into every device build
│       ├── CMakeLists.txt    # Declares sources and dependencies for ESP-IDF
│       ├── Kconfig.projbuild # Adds config options to idf.py menuconfig
│       ├── idf_component.yml # ESP-IDF component manifest (version, dependencies)
│       ├── include/          # Public header files — all other code #includes from here
│       │   ├── dsgv_config.h         # GPIO maps, MQTT endpoint, Firebase URL, mDNS constants
│       │   ├── dsgv_device_config.h  # Runtime config struct (NVS layout)
│       │   ├── dsgv_device_state.h   # Device state struct (power, brightness, temp, etc.)
│       │   ├── dsgv_gpio.h           # GPIO driver API
│       │   ├── dsgv_http_server.h    # HTTP server API
│       │   ├── dsgv_mdns.h           # mDNS API
│       │   ├── dsgv_provisioning.h   # BLE provisioning API
│       │   ├── dsgv_firebase.h       # Firebase fetch API
│       │   └── wifi_manager.h        # WiFi manager API
│       ├── config/           # NVS config load/save
│       ├── firebase/         # HTTPS Firebase broker config fetch
│       ├── gpio/             # LEDC PWM, relay control, ISR sensors
│       ├── http/             # LAN REST API (/status /command /ota)
│       ├── mdns/             # mDNS service advertisement
│       ├── mqtt/             # MQTT connect, announce, telemetry, command handling
│       ├── ota/              # HTTPS OTA with SHA-256 verification
│       ├── provisioning/     # NimBLE GATT WiFi + token provisioning
│       └── wifi/             # WiFi connection manager
│
├── main/                     ← Application entry point (mirrors component structure)
│   ├── main.c                # main() — calls each module's init function in order
│   ├── CMakeLists.txt
│   ├── idf_component.yml
│   └── [config/ gpio/ http/ mqtt/ ota/ provisioning/ wifi/]
│
├── devices/                  ← One subdirectory per device SKU
│   ├── 1gang_switch/
│   │   ├── CMakeLists.txt        # Points to main/ and components/
│   │   └── sdkconfig.defaults    # Device-specific ESP-IDF config overrides
│   ├── 2gang_switch/  3gang_switch/  4gang_switch/
│   ├── dimmer/  rgb_light/  colour_temp/
│   ├── temp_sensor/  motion_sensor/  contact_sensor/
│   └── thermostat/
│
├── include/                  ← Firmware-level headers (root copies of component headers)
├── scripts/                  ← Build utilities
│   ├── build_all.ps1         # PowerShell: build all devices for a chip
│   ├── build_device.ps1      # PowerShell: build a single device
│   └── check_binary_size.py  # Verify binary fits within partition limits
│
├── Makefile                  ← Main build interface (wraps idf.py — see Section 4)
├── sdkconfig.defaults        ← Base ESP-IDF config (all devices inherit from this)
├── partitions_4mb.csv        ← Partition layout for 4 MB flash modules
└── partitions_8mb.csv        ← Partition layout for 8 MB flash modules
```

### Why is code in both `main/` and `components/dsgv_common/`?

ESP-IDF requires a top-level `main/` component for the entry point. The shared logic
(MQTT, GPIO, WiFi, etc.) lives in `components/dsgv_common/` so it can be cleanly
referenced by any device build without duplication. Think of `dsgv_common` as a library
and `main/` as the application that uses it.

---

## 3. Prerequisites

### Required tools

| Tool | Version | Why |
|------|---------|-----|
| **ESP-IDF** | 5.x | The build system, compiler, and all component APIs |
| **VS Code** | Any | The recommended IDE |
| **Espressif IDF extension** | Latest | Installs ESP-IDF, manages targets, provides build/flash/monitor buttons |

### Install ESP-IDF via VS Code (recommended for beginners)

1. Open VS Code → Extensions (`Ctrl+Shift+X`) → search `Espressif IDF` → Install
2. Open the Command Palette (`Ctrl+Shift+P`) → `ESP-IDF: Configure ESP-IDF Extension`
3. Choose **Express** → select ESP-IDF version `v5.x` → click Install
4. Wait for the installer to finish (~10 minutes, downloads toolchain)

After installation, verify it works:
```bash
idf.py --version
# Expected: ESP-IDF v5.x.x
```

### Install ESP-IDF manually (Mac/Linux alternative)

```bash
# macOS
brew install cmake ninja dfu-util

# Ubuntu/Debian
sudo apt install git cmake ninja-build python3-pip

# Clone ESP-IDF
mkdir ~/esp && cd ~/esp
git clone --recursive https://github.com/espressif/esp-idf.git
cd esp-idf
git checkout v5.2    # or latest stable v5.x
./install.sh
source ./export.sh   # run this in every new terminal before using idf.py
```

### Install the USB-to-serial driver

Your ESP32 dev board has a small USB bridge chip. Look at the chip next to the USB port:

| Chip marking | Driver download |
|---|---|
| **CP2102** or **CP210x** | Silicon Labs — search "CP210x USB to UART driver" |
| **CH340** or **CH341** | Search "CH340 driver" for your OS |
| **FTDI** | ftdichip.com → Drivers |

After installing, plug in the board and find its port:

```bash
# macOS
ls /dev/cu.*           # look for /dev/cu.usbserial-XXXX

# Linux
ls /dev/ttyUSB*        # look for /dev/ttyUSB0

# Windows — Device Manager → Ports (COM & LPT) → note the COM number (e.g. COM5)
```

---

## 4. Build System — the Makefile

The `Makefile` at the root of `dsgv_firmware/` wraps `idf.py` to make building
multiple device types easier. You pass the device name and chip variant as variables.

### Variables

| Variable | Default | Options |
|---|---|---|
| `DEVICE` | `1gang_switch` | Any of the 11 device names (see Section 5) |
| `TARGET` | `esp32c3` | `esp32c3`, `esp32c6`, `esp32s3`, `esp32` |
| `PORT` | `/dev/ttyUSB0` | Your serial port (`COM5` on Windows, `/dev/cu.*` on Mac) |
| `BAUD` | `460800` | Flash speed — lower if you get errors (`115200`) |

### Commands

```bash
# Build one device
make DEVICE=dimmer TARGET=esp32c3 build

# Flash to a connected device
make DEVICE=dimmer TARGET=esp32c3 PORT=/dev/ttyUSB0 flash

# Open serial monitor (press Ctrl+] to exit)
make DEVICE=dimmer TARGET=esp32c3 PORT=/dev/ttyUSB0 monitor

# Flash then immediately open the monitor — most common workflow
make DEVICE=dimmer TARGET=esp32c3 PORT=/dev/ttyUSB0 fm

# Clean build artefacts for one device
make DEVICE=dimmer clean

# Build ALL 11 device types (for CI or release)
make TARGET=esp32c3 build-all

# List all valid device names
make list

# Print help
make help
```

### Windows note

On Windows, use the **ESP-IDF Command Prompt** (installed by the VS Code extension or the
Windows installer) not PowerShell or cmd. The `make` command maps to `nmake` or `mingw32-make`
depending on your install — the extension handles this automatically.

Alternatively, use the PowerShell scripts in `scripts/`:

```powershell
.\scripts\build_device.ps1 -Device dimmer -Target esp32c3 -Port COM5
.\scripts\build_all.ps1 -Target esp32c3
```

---

## 5. All 11 Device Types

| Device name | `make DEVICE=` | Capabilities | Relay outputs | Notes |
|---|---|---|---|---|
| 1-Gang Switch | `1gang_switch` | `relay` | 1 | |
| 2-Gang Switch | `2gang_switch` | `relay`, `relay_2` | 2 | |
| 3-Gang Switch | `3gang_switch` | `relay`, `relay_2`, `relay_3` | 3 | |
| 4-Gang Switch | `4gang_switch` | `relay`, …, `relay_4` | 4 | |
| Dimmer | `dimmer` | `relay`, `brightness` | 1 | LEDC PWM ch 0 |
| Colour Temperature | `colour_temp` | `relay`, `brightness`, `color_temp` | 1 | LEDC ch 1 (warm) + ch 2 (cool) |
| RGB Light | `rgb_light` | `relay`, `brightness`, `rgb` | 1 | LEDC ch 3–5 (R, G, B) |
| Temperature Sensor | `temp_sensor` | `temperature`, `humidity` | 0 | NTC ADC or SOC sensor |
| Motion Sensor | `motion_sensor` | `motion` | 0 | PIR, ISR-driven |
| Contact Sensor | `contact_sensor` | `contact` | 0 | Reed switch input |
| Thermostat | `thermostat` | `temperature`, `hvac_mode` | 1 | Target temp + cool/heat/auto/off |

The Flutter app reads the `capabilities` array from the device's MQTT announce message and
renders the appropriate controls automatically — no per-device screen code needed.

---

## 6. Startup Sequence

Every device runs this sequence on power-on, in order. Each step is logged to the
serial monitor so you can see exactly where a problem occurs.

```
Step 1 — NVS init
         Non-Volatile Storage: the flash region where WiFi credentials, auth token,
         and broker config are persisted. Must initialise before anything else reads config.

Step 2 — TCP/IP stack init
         Initialises the lwIP network stack. Required before WiFi or any network call.

Step 3 — GPIO init
         Configures relay output pins, LEDC PWM channels, and sensor input pins with
         their interrupt service routines (ISRs).

Step 4 — WiFi connect
         Loads SSID + password from NVS and connects to the home network.
         If no credentials exist → starts BLE provisioning instead (Step 4b).

Step 4b — BLE provisioning (first boot only)
          Starts the NimBLE GATT server. Waits for the Flutter app to send
          { ssid, password, device_type, capabilities, auth_token } over BLE.
          Saves credentials to NVS then restarts into Step 4 (normal WiFi connect).

Step 5 — Firebase fetch
         Calls getDeviceConfig Cloud Function over HTTPS to get the MQTT broker config.
         Falls back to the NVS-cached config if Firebase is unreachable.

Step 6 — HTTP server start
         Starts the LAN REST API on port 80. The app uses /command for direct
         local control (faster than MQTT when on the same network).

Step 7 — mDNS start
         Advertises _dsgv._tcp and _http._tcp on the local network.
         The app uses this to find the device's IP without a fixed address.

Step 8 — MQTT connect
         Connects to the broker fetched in Step 5.
         Publishes announce message → starts telemetry timer → subscribes to command topic.
```

---

## 7. Key Design Concepts

These are ESP-IDF concepts that appear throughout the codebase. Understanding them
helps when reading or modifying the firmware.

### NVS (Non-Volatile Storage)

NVS is a key-value store in flash memory. Think of it like a tiny database on the chip.
Data written to NVS survives reboots, power cuts, and OTA firmware updates.

```c
// Writing to NVS
nvs_handle_t h;
nvs_open("DSGV_cfg", NVS_READWRITE, &h);
nvs_set_str(h, "wifi_ssid", "MyHomeNetwork");
nvs_commit(h);
nvs_close(h);

// Reading from NVS
char ssid[64];
size_t len = sizeof(ssid);
nvs_get_str(h, "wifi_ssid", ssid, &len);
```

All device config (WiFi SSID/password, auth token, broker host/port/TLS/credentials,
device type) is stored in the `DSGV_cfg` NVS namespace.

### FreeRTOS Tasks

ESP-IDF uses FreeRTOS, a real-time operating system. Instead of one sequential program,
you have multiple tasks (like threads) running concurrently. Each major feature runs as
its own task:

- WiFi event handler task
- MQTT client task
- Telemetry timer task
- HTTP server task
- BLE provisioning task (only during provisioning)

This is why the firmware can publish telemetry every 30 seconds AND respond to an HTTP
command at the same time — they're on separate tasks managed by the FreeRTOS scheduler.

### LEDC (LED Control) — PWM for Dimmer and RGB

LEDC is ESP32's hardware PWM peripheral. It generates a precise square wave at a given
duty cycle — 0% = relay off, 100% = full brightness. The hardware does the timing so the
CPU doesn't have to, meaning smooth dimming without flickering or CPU load.

```c
// Set dimmer to 60% brightness
ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, 60 * 8191 / 100);
ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0);
```

### LWT (Last Will and Testament) — MQTT offline detection

When the device connects to the MQTT broker, it registers a "last will" message:
`devices/{mac}/status = "offline"`. If the device disconnects without sending a clean
disconnect (power cut, crash, network drop), the broker automatically publishes this
message on its behalf. This is how the app knows a device went offline without the
device having to say so explicitly.

### ISR (Interrupt Service Routine) — Sensors

Sensors like the PIR motion detector and door contact are wired to GPIO pins. Instead of
the CPU constantly checking "is the pin high?", an ISR fires the instant the pin changes
state. This is more efficient and catches fast events (a door opening and closing in under
50 ms) that polling would miss.

---

## 8. Component Reference

### `dsgv_config.h` — The configuration centre

**Location:** `components/dsgv_common/include/dsgv_config.h`

This is the first file to edit when porting to new hardware. It contains:

- GPIO pin assignments (selected automatically by `CONFIG_IDF_TARGET_*`)
- Factory MQTT broker hostname and port
- Firebase Cloud Function URL
- mDNS service names
- Timing constants (telemetry interval, MQTT keepalive, Firebase timeout)

> Do not hardcode credentials here — credentials go in NVS at runtime.
> This file only contains non-secret defaults.

### `dsgv_device_config.h` — Runtime config struct

**Location:** `components/dsgv_common/include/dsgv_device_config.h`

Defines the `dsgv_device_config_t` struct that holds all runtime configuration loaded
from NVS on boot. Every module reads from this struct rather than NVS directly.

### `dsgv_mqtt.c` — MQTT engine

**Location:** `components/dsgv_common/mqtt/dsgv_mqtt.c`

Handles the full MQTT lifecycle:
- Connects to broker with TLS and auth credentials from config
- Publishes announce message (device_id, name, capabilities, local_ip, firmware_version)
- Starts a 30-second telemetry timer (FreeRTOS timer, not a blocking loop)
- Subscribes to `devices/{mac}/command` and routes incoming JSON to the GPIO driver
- Sets LWT so the broker marks the device offline on unexpected disconnect

### `dsgv_gpio.c` — Hardware abstraction

**Location:** `components/dsgv_common/gpio/dsgv_gpio.c`

The only file that talks directly to hardware pins. All other modules call its API:

```c
dsgv_gpio_relay_set(relay_index, true);          // turn on relay 1
dsgv_gpio_brightness_set(80);                    // set dimmer to 80%
dsgv_gpio_rgb_set(255, 128, 0);                  // set RGB to orange
float temp = dsgv_gpio_temperature_read();        // read temperature sensor
```

This isolation means you can swap hardware (e.g. different relay driver IC) without
touching the MQTT or HTTP code.

---

## 9. Serial Log Tags

Every log line from the firmware starts with a tag. Use these to filter output
in the serial monitor and find the relevant section quickly.

| Tag | Module | What it tells you |
|-----|--------|------------------|
| `DSGV_cfg` | `dsgv_device_config.c` | NVS reads/writes, auth token generation, config validation |
| `DSGV_WiFi` | `wifi_manager.c` | WiFi connect attempts, IP address assigned, reconnect events |
| `DSGV_Firebase` | `dsgv_firebase.c` | HTTPS fetch result, which broker config was applied |
| `DSGV_MDNS` | `dsgv_mdns.c` | mDNS service registration, hostname set |
| `DSGV_HTTP` | `dsgv_http_server.c` | Incoming HTTP requests, responses |
| `DSGV_MQTT` | `dsgv_mqtt.c` | Broker connect, topic publishes, incoming commands |
| `DSGV_GPIO` | `dsgv_gpio.c` | Relay state changes, PWM updates, sensor readings |
| `DSGV_Prov` | `dsgv_provisioning.c` | BLE advertising, GATT characteristic writes, credential receipt |
| `DSGV_OTA` | `dsgv_ota.c` | OTA download progress, SHA-256 verify, partition swap, reboot |

### Filter log output in the monitor

```bash
# Only show MQTT-related lines
make DEVICE=dimmer fm 2>&1 | grep DSGV_MQTT

# Show everything except verbose WiFi noise
make DEVICE=dimmer fm 2>&1 | grep -v "wifi:"
```

### What a healthy boot sequence looks like

```
I (312)  DSGV_cfg:      Config loaded from NVS — device_type: dimmer
I (890)  DSGV_WiFi:     Connected to MyHomeNetwork — IP: 192.168.1.42
I (1203) DSGV_Firebase: Broker config updated: mqtt.yourdomain.com:8883 (TLS=1)
I (1205) DSGV_MDNS:     mDNS started — hostname: dsgv-A1B2C3D4E5F6
I (1206) DSGV_HTTP:     HTTP server started on port 80
I (1890) DSGV_MQTT:     Connected to mqtt.yourdomain.com:8883
I (1892) DSGV_MQTT:     Announced — devices/A1B2C3D4E5F6/announce
I (1895) DSGV_MQTT:     Telemetry timer started (30 s interval)
```

---

## 10. Adding a New Device Type

The platform is designed so adding a new SKU touches only a small number of files.

### Step 1 — Create the device directory

```bash
cp -r devices/1gang_switch devices/my_new_device
```

### Step 2 — Edit the device's `sdkconfig.defaults`

Set any chip-specific overrides. Most devices can inherit everything from the root
`sdkconfig.defaults` with no changes at all.

### Step 3 — Define capabilities in `dsgv_config.h`

Add the new capability string to the capabilities array for this device type.
The Flutter app reads this and renders the correct controls automatically.

### Step 4 — Handle the new capability in `dsgv_gpio.c`

Add the hardware driver for any new GPIO behaviour (new sensor type, new actuator).

### Step 5 — Handle the MQTT command in `dsgv_mqtt.c`

Add a case in the command handler for the new capability's JSON key.

### Step 6 — Add to the Makefile device list

In `Makefile`, add `my_new_device` to the `DEVICES` list so `make build-all`
includes it.

### Step 7 — Build and test

```bash
make DEVICE=my_new_device TARGET=esp32c3 build
make DEVICE=my_new_device TARGET=esp32c3 PORT=/dev/ttyUSB0 fm
```

No app update required — the app renders controls based on the capabilities the
device broadcasts over MQTT.

---

## 11. Partition Tables

ESP32 flash is divided into regions called partitions. The partition table defines
what goes where. DSGV firmware ships two layouts:

### `partitions_4mb.csv` — for 4 MB flash modules (ESP32-C3, most dev boards)

| Partition | Type | Size | Purpose |
|---|---|---|---|
| `nvs` | NVS | 24 KB | System WiFi NVS |
| `otadata` | OTA data | 8 KB | Tracks which OTA slot is active |
| `app0` | OTA app | 1.9 MB | Primary firmware slot |
| `app1` | OTA app | 1.9 MB | OTA update slot (rollback target) |
| `user_nvs` | NVS | 256 KB | DSGV config (WiFi creds, auth token, broker config) |

### `partitions_8mb.csv` — for 8 MB flash modules (ESP32-S3 with more storage)

Same layout as above but with a larger `storage` (SPIFFS) partition (~1.9 MB) for
serving local web assets or logging if needed in future.

### How OTA rollback works

When an OTA update downloads:
1. New firmware is written to the inactive slot (`app1` if `app0` is running)
2. Device reboots into the new firmware
3. If the new firmware boots and calls `esp_ota_mark_app_valid_cancel_rollback()`, the update is committed
4. If the new firmware crashes before that call, the bootloader automatically boots back into the previous slot

This is why you never brick a device with a bad OTA update — the old firmware is always preserved in the other slot.

---

## 12. Key Files at a Glance

| File | Edit when |
|------|----------|
| `components/dsgv_common/include/dsgv_config.h` | Porting to new PCB, changing broker URL, changing Firebase URL |
| `components/dsgv_common/mqtt/dsgv_mqtt.c` | Adding new MQTT topics, changing telemetry fields, adding command handlers |
| `components/dsgv_common/gpio/dsgv_gpio.c` | Adding new hardware (sensor, actuator, PWM channel) |
| `components/dsgv_common/mdns/dsgv_mdns.c` | Changing mDNS service name or TXT record fields |
| `components/dsgv_common/provisioning/dsgv_provisioning.c` | Changing BLE provisioning payload fields |
| `components/dsgv_common/firebase/dsgv_firebase.c` | Extending Firebase config fields (e.g. adding new broker fields) |
| `components/dsgv_common/ota/dsgv_ota.c` | Changing OTA server URL format or verification logic |
| `sdkconfig.defaults` | Changing base ESP-IDF config for all devices |
| `devices/{name}/sdkconfig.defaults` | Overriding config for one specific device type |
| `partitions_4mb.csv` / `partitions_8mb.csv` | Changing flash layout (rare — only when adding new partition types) |
| `Makefile` | Adding new device types to the build system |

---

*For wiring diagrams, per-device GPIO pin maps, and step-by-step flash instructions,
see [FLASHING_GUIDE.md](../FLASHING_GUIDE.md) in the repository root.*

*For the full platform architecture, Firebase setup, and app documentation,
see the [root README](../README.md).*
