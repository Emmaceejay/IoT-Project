# DSGV Hub Firmware — Flashing & Device Configuration Guide

> **New workflow:** You no longer edit any C header files.
> Each device has its own folder. The only file you ever touch is:
> `devices/<device_name>/sdkconfig.defaults`

---

## Part 1 — One-time Setup

### Install ESP-IDF

**Windows:**
1. Download the installer from https://dl.espressif.com/dl/esp-idf/
2. Run it, accept defaults (~10 minutes)
3. Use **ESP-IDF PowerShell** or **ESP-IDF Command Prompt** from Start menu for all commands below

**Mac/Linux:**
```bash
brew install cmake ninja dfu-util          # Mac only
sudo apt install git cmake ninja-build     # Ubuntu/Debian only

mkdir ~/esp && cd ~/esp
git clone --recursive https://github.com/espressif/esp-idf.git
cd esp-idf
./install.sh
source ./export.sh    # run this every time you open a new terminal
```

### Install the USB driver

Look at the small IC next to the USB port on the board:
- **CP2102** chip → https://www.silabs.com/developers/usb-to-uart-bridge-vcp-drivers
- **CH340** chip → search "CH340 driver download" for your OS

### Find your COM port

**Windows:** Device Manager → Ports (COM & LPT) → note the COM number (e.g. `COM5`)

**Mac:**
```bash
ls /dev/tty.*        # look for /dev/tty.usbserial-0001
```

**Linux:**
```bash
ls /dev/ttyUSB*      # look for /dev/ttyUSB0
```

---

## Part 2 — Project Structure

```
dsgv_firmware/
├── components/
│   └── dsgv_common/          ← shared firmware (Wi-Fi, MQTT, OTA, HTTP, BLE, GPIO)
│       └── ...                  NEVER edit these files
│
├── devices/                  ← one folder per device SKU
│   ├── 1gang_switch/
│   │   └── sdkconfig.defaults   ← THE ONLY FILE YOU EDIT
│   ├── 2gang_switch/
│   ├── 3gang_switch/
│   ├── 4gang_switch/
│   ├── dimmer/
│   ├── colour_temp/
│   ├── rgb_light/
│   ├── temp_sensor/
│   ├── motion_sensor/
│   ├── contact_sensor/
│   └── thermostat/
│
├── partitions_4mb.csv        ← flash layout for 4 MB hardware (default)
├── partitions_8mb.csv        ← flash layout for 8 MB hardware (future/gateway)
│
├── scripts/
│   ├── build_device.ps1      ← build (+ optionally flash) one device
│   ├── build_all.ps1         ← build all 11 devices
│   └── check_binary_size.py  ← enforces OTA slot size limit after every build
│
└── sdkconfig.defaults        ← shared base config (MQTT, TLS, BLE, OTA) — rarely touch
```

---

## Part 3 — Configure a Device

Open the device folder you want to configure. Each device has exactly one file:

```
devices/<device_name>/sdkconfig.defaults
```

**Example — `devices/dimmer/sdkconfig.defaults`:**
```ini
CONFIG_DSGV_DEVICE_TYPE="Dimmer"
CONFIG_DSGV_DEVICE_CAPABILITIES="[\"relay\",\"brightness\"]"
CONFIG_DSGV_RELAY_COUNT=1

# Partition table
CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="../../partitions_4mb.csv"
```

That's it. The chip target (ESP32 / C3 / S3) is passed at build time — it determines GPIO pins automatically. You never edit GPIO numbers manually.

> **GPIO pin assignments** are fixed per chip in `components/dsgv_common/include/dsgv_config.h` and selected automatically. See the Quick Reference table in Part 10.

---

### Device Configurations

#### A — 1-Gang Light Switch
**File:** `devices/1gang_switch/sdkconfig.defaults`
```ini
CONFIG_DSGV_DEVICE_TYPE="Switch"
CONFIG_DSGV_DEVICE_CAPABILITIES="[\"relay\"]"
CONFIG_DSGV_RELAY_COUNT=1
```
**Wiring (ESP32-C3):**
```
GPIO2  ──► Relay IN
3.3V   ──► VCC
GND    ──► GND
```

---

#### B — 2-Gang Light Switch
**File:** `devices/2gang_switch/sdkconfig.defaults`
```ini
CONFIG_DSGV_DEVICE_TYPE="Switch"
CONFIG_DSGV_DEVICE_CAPABILITIES="[\"relay\",\"relay_2\"]"
CONFIG_DSGV_RELAY_COUNT=2
```
**Wiring (ESP32-C3):**
```
GPIO2  ──► IN1 (Switch 1)
GPIO3  ──► IN2 (Switch 2)
3.3V   ──► VCC
GND    ──► GND
```
> ⚠️ GPIO3 on C3 doubles as the dimmer pin — do not combine `relay_2` and `brightness` capabilities.

---

#### C — 3-Gang Light Switch
**File:** `devices/3gang_switch/sdkconfig.defaults`
```ini
CONFIG_DSGV_DEVICE_TYPE="Switch"
CONFIG_DSGV_DEVICE_CAPABILITIES="[\"relay\",\"relay_2\",\"relay_3\"]"
CONFIG_DSGV_RELAY_COUNT=3
```
**Wiring (ESP32-C3):** GPIO2, GPIO3, GPIO4 → IN1, IN2, IN3

---

#### D — 4-Gang Light Switch
**File:** `devices/4gang_switch/sdkconfig.defaults`
```ini
CONFIG_DSGV_DEVICE_TYPE="Switch"
CONFIG_DSGV_DEVICE_CAPABILITIES="[\"relay\",\"relay_2\",\"relay_3\",\"relay_4\"]"
CONFIG_DSGV_RELAY_COUNT=4
```
**Wiring (ESP32-C3):** GPIO2, GPIO3, GPIO4, GPIO5 → IN1, IN2, IN3, IN4

---

#### E — Dimmer (PWM brightness)
**File:** `devices/dimmer/sdkconfig.defaults`
```ini
CONFIG_DSGV_DEVICE_TYPE="Dimmer"
CONFIG_DSGV_DEVICE_CAPABILITIES="[\"relay\",\"brightness\"]"
CONFIG_DSGV_RELAY_COUNT=1
```
**Wiring (ESP32-C3) — use AC TRIAC dimmer module (e.g. RobotDyn):**
```
GPIO2  ──► Relay IN  (power on/off)
GPIO3  ──► PWM IN    (brightness 0–100%)
3.3V   ──► VCC
GND    ──► GND
```
> ⚠️ Use an AC-compatible TRIAC dimmer module. Never connect mains voltage directly to the ESP32.

---

#### F — Colour Temperature Light (warm + cool white)
**File:** `devices/colour_temp/sdkconfig.defaults`
```ini
CONFIG_DSGV_DEVICE_TYPE="Light"
CONFIG_DSGV_DEVICE_CAPABILITIES="[\"relay\",\"brightness\",\"color_temp\"]"
CONFIG_DSGV_RELAY_COUNT=1
```
**Wiring (ESP32-C3):**
```
GPIO2  ──► Relay IN       (power)
GPIO4  ──► Warm white PWM
GPIO5  ──► Cool white PWM
GND    ──► GND
```

---

#### G — RGB Light
**File:** `devices/rgb_light/sdkconfig.defaults`
```ini
CONFIG_DSGV_DEVICE_TYPE="Light"
CONFIG_DSGV_DEVICE_CAPABILITIES="[\"relay\",\"brightness\",\"rgb\"]"
CONFIG_DSGV_RELAY_COUNT=1
```
**Wiring (ESP32-C3) — three MOSFET channels or RGB LED driver:**
```
GPIO2   ──► Relay IN  (power)
GPIO6   ──► Red   PWM
GPIO7   ──► Green PWM
GPIO10  ──► Blue  PWM
GND     ──► GND
```

---

#### H — Temperature Sensor Node
**File:** `devices/temp_sensor/sdkconfig.defaults`
```ini
CONFIG_DSGV_DEVICE_TYPE="Sensor"
CONFIG_DSGV_DEVICE_CAPABILITIES="[\"temperature\",\"humidity\"]"
CONFIG_DSGV_RELAY_COUNT=0
```
No relay wiring needed. The ESP32-C3/C6/S3 has a built-in SOC temperature sensor.

**Optional external NTC thermistor for ambient temperature (ESP32-C3):**
```
3.3V ──┬── 10kΩ ──► NTC+ ──► GND
       └──► GPIO1 (ADC1)
```

---

#### I — Motion Sensor (PIR)
**File:** `devices/motion_sensor/sdkconfig.defaults`
```ini
CONFIG_DSGV_DEVICE_TYPE="Sensor"
CONFIG_DSGV_DEVICE_CAPABILITIES="[\"motion\"]"
CONFIG_DSGV_RELAY_COUNT=0
```
**Wiring (ESP32-C3) — HC-SR501 PIR module:**
```
5V     ──► VCC
GND    ──► GND
GPIO11 ──► OUT (HIGH = motion)
```

---

#### J — Contact Sensor (door/window reed switch)
**File:** `devices/contact_sensor/sdkconfig.defaults`
```ini
CONFIG_DSGV_DEVICE_TYPE="Sensor"
CONFIG_DSGV_DEVICE_CAPABILITIES="[\"contact\"]"
CONFIG_DSGV_RELAY_COUNT=0
```
**Wiring (ESP32-C3):**
```
3.3V   ──┬── 10kΩ pull-up ──► GPIO20
         └──► Reed switch ──► GND
```
LOW = closed (contact made), HIGH = open.

---

#### K — Thermostat (temperature + HVAC relay)
**File:** `devices/thermostat/sdkconfig.defaults`
```ini
CONFIG_DSGV_DEVICE_TYPE="Thermostat"
CONFIG_DSGV_DEVICE_CAPABILITIES="[\"temperature\",\"hvac_mode\"]"
CONFIG_DSGV_RELAY_COUNT=0
```
The app shows current temp (read-only), target setpoint, and mode chips (Cool / Heat / Auto / Off).
GPIO2 (on C3) relay drives the HVAC unit's control input.

---

### Set MQTT Broker Address

Edit `sdkconfig.defaults` (shared, at repo root — **not** inside a device folder):

```
MQTT_CLOUD_HOST   is in components/dsgv_common/include/dsgv_config.h
MQTT_LOCAL_HOST   is in components/dsgv_common/include/dsgv_config.h
```

Open that file and update:
```c
#define MQTT_CLOUD_HOST   "your-emqx-endpoint.cloud"
#define MQTT_LOCAL_HOST   "192.168.1.100"
```

The firmware tries the cloud broker first and falls back to local automatically.

---

## Part 4 — Build

### Option A — PowerShell build scripts (recommended, Windows)

```powershell
# Navigate to the project root
cd C:\Users\YourName\Documents\IoT-Project\dsgv_firmware

# Build one device for ESP32-C3 (4 MB flash, default)
.\scripts\build_device.ps1 dimmer esp32c3

# Build and flash in one step
.\scripts\build_device.ps1 dimmer esp32c3 COM5

# Build for 8 MB flash hardware
.\scripts\build_device.ps1 rgb_light esp32s3 -FlashMB 8

# Build all 11 devices for ESP32-C3
.\scripts\build_all.ps1 esp32c3

# Build all devices for ESP32-S3
.\scripts\build_all.ps1 esp32s3

# Build all devices for ESP32-S3 with 8 MB flash
.\scripts\build_all.ps1 esp32s3 -FlashMB 8
```

> Script usage: `build_device.ps1 <device> <chip_target> [COM_port] [-FlashMB 4|8]`
> Valid devices: `1gang_switch` `2gang_switch` `3gang_switch` `4gang_switch` `dimmer` `colour_temp` `rgb_light` `temp_sensor` `motion_sensor` `contact_sensor` `thermostat`
> Valid targets: `esp32` `esp32c3` `esp32s3` `esp32c6`

The build script automatically runs a **binary size check** after every successful build (see Part 5).

---

### Option B — Manual build (any OS)

```bash
# Navigate into the specific device folder
cd devices/dimmer

# Build for ESP32-C3
idf.py -DIDF_TARGET=esp32c3 build

# Build for ESP32-S3
idf.py -DIDF_TARGET=esp32s3 build

# Build for classic ESP32
idf.py -DIDF_TARGET=esp32 build
```

The binary is created at `devices/<device>/build/dsgv_<device>.bin`.

**Run the size check manually after a manual build:**
```bash
# From repo root (4 MB flash limit):
python3 scripts/check_binary_size.py devices/dimmer/build/dsgv_dimmer.bin 1835008

# For 8 MB flash:
python3 scripts/check_binary_size.py devices/dimmer/build/dsgv_dimmer.bin 3080192
```

**Common build errors:**
- **`CONFIG_DSGV_*` undefined** → make sure `sdkconfig.defaults` has all three `CONFIG_DSGV_` lines
- **Cannot find component `dsgv_common`** → build from inside `devices/<device>/`, not the repo root
- **Wrong chip selected** → delete the `build/` folder and re-run with the correct `-DIDF_TARGET`
- **Partition table file not found** → ensure `CONFIG_PARTITION_TABLE_CUSTOM_FILENAME` uses `../../` prefix (already set in all device files)

---

## Part 5 — Binary Size Check

Every build automatically verifies the firmware fits inside its OTA partition.
The script `scripts/check_binary_size.py` enforces a hard limit and **fails the build** if exceeded.

**What it checks:**

| Flash size | OTA slot | Hard limit | Headroom |
|---|---|---|---|
| 4 MB (`partitions_4mb.csv`) | 1,900,544 bytes (1.8 MB) | **1,835,008 bytes** | 64 KB |
| 8 MB (`partitions_8mb.csv`) | 3,145,728 bytes (3.0 MB) | **3,080,192 bytes** | 64 KB |

**Example output (PASS):**
```
>>> Size check (limit: 1792 KB for 4MB flash)
  Binary  : dsgv_dimmer.bin
  Size    :    892,416 bytes  (871.5 KB)
  Limit   :  1,835,008 bytes  (1792.0 KB)
  Budget  :   48.6%    Headroom: 942,592 bytes (920.5 KB)
  PASS
```

**If the check fails:**
1. Add `CONFIG_COMPILER_OPTIMIZATION_SIZE=y` to `sdkconfig.defaults` (already included)
2. Disable unused features (e.g. `CONFIG_CHIP_OTA_REQUESTOR=n` — already included)
3. Upgrade to 8 MB flash and switch `CONFIG_PARTITION_TABLE_CUSTOM_FILENAME` to `../../partitions_8mb.csv`

---

## Part 6 — Flash

```bash
# From inside the device folder (after building):

# Windows:
idf.py -p COM5 flash

# Mac:
idf.py -p /dev/tty.usbserial-0001 flash

# Linux:
idf.py -p /dev/ttyUSB0 flash
```

**Or use the build script to build + flash in one command (Windows):**
```powershell
.\scripts\build_device.ps1 dimmer esp32c3 COM5
```

**If the board doesn't enter flash mode automatically:**
1. Hold **BOOT** button
2. Press and release **RESET/EN**
3. Release **BOOT**
Then re-run the flash command.

> **Important — first flash on new hardware:** The first time you flash a device (or after changing the
> partition table), you must erase the entire flash first so the new partition layout takes effect cleanly:
> ```bash
> idf.py -p COM5 erase_flash
> idf.py -p COM5 flash
> ```

---

## Part 7 — Monitor Serial Output

```bash
# From inside the device folder:

# Windows:
idf.py -p COM5 monitor

# Mac/Linux:
idf.py -p /dev/ttyUSB0 monitor
```

Press **RESET** on the board. Expected output (dimmer example):
```
I DSGV_main: === DSGV Hub Firmware v1.0.0 Booting ===
I DSGV_cfg:  No NVS device config — using compile-time defaults (type=Dimmer caps=["relay","brightness"] relays=1)
I dsgv_gpio: GPIO ready (relay[0]=2 cnt=1 LED=8 dimmer=3 ...)
I dsgv_mqtt: Connected. Device ID: AABBCCDDEEFF
I dsgv_mqtt: Published announce → devices/AABBCCDDEEFF/announce
I DSGV_main: Device : Dimmer  caps=["relay","brightness"]  relays=1
I DSGV_main: HTTP server: port 80
I DSGV_main: MQTT broker: your-emqx.cloud:8883 (TLS) → 192.168.1.100:1883 (fallback)
```

Exit monitor: **Ctrl + ]**

---

## Part 8 — Build + Flash + Monitor in One Command

```bash
# Manual (from inside device folder):
idf.py -DIDF_TARGET=esp32c3 -p COM5 flash monitor

# PowerShell script (from repo root):
.\scripts\build_device.ps1 dimmer esp32c3 COM5
```

---

## Part 9 — Open a Device in VSCode

Each device folder is a self-contained ESP-IDF project. Open it directly:

```bash
code devices/dimmer
```

The ESP-IDF VSCode extension will recognise it as an independent project. IntelliSense resolves the `dsgv_common` headers automatically via the `EXTRA_COMPONENT_DIRS` setting in the device's `CMakeLists.txt`.

To switch which device you're working on, just open the other folder:
```bash
code devices/rgb_light
```

---

## Part 10 — Configure via App (no reflash needed)

After flashing, the device type can be changed from the app during BLE provisioning:

1. Scan QR on device label: `DSGV://provision?name=DSGVHub_XXXXXX`
2. Select **Device Type** preset in the pairing screen
3. Enter Wi-Fi credentials → tap **Provision**

The app sends device type, capabilities, and relay count over BLE. The firmware saves to NVS and reboots. NVS config then overrides the `sdkconfig.defaults` values baked into the binary.

> This means **one firmware binary can serve all SKUs** — provision each device through the app instead of reflashing.

To factory-reset a device back to its compiled defaults: hold the **BOOT/GPIO0** button for 5 seconds.

---

## Part 11 — Upgrading to 8 MB Flash Hardware

When moving to a hardware variant with 8 MB flash (recommended for future product spins — eliminates all binary size pressure):

1. In the device's `sdkconfig.defaults`, replace the partition line:
   ```ini
   # Change this:
   CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="../../partitions_4mb.csv"

   # To this:
   CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="../../partitions_8mb.csv"
   CONFIG_ESPTOOLPY_FLASHSIZE_8MB=y
   ```

2. Delete the existing `build/` folder to force a clean rebuild:
   ```bash
   rm -rf devices/<device>/build
   ```

3. Build normally:
   ```powershell
   .\scripts\build_device.ps1 <device> esp32c3 -FlashMB 8
   ```

4. Erase flash and re-flash (required whenever the partition table changes):
   ```bash
   idf.py -p COM5 erase_flash
   idf.py -p COM5 flash
   ```

---

## Part 12 — Flash Layout Reference

### 4 MB Flash (`partitions_4mb.csv`) — Default

| Partition | Type | Offset | Size | Purpose |
|---|---|---|---|---|
| `nvs` | data/nvs | 0x9000 | 24 KB | App config, Wi-Fi credentials, auth token |
| `otadata` | data/ota | 0xF000 | 8 KB | Bootloader OTA state (active bank) |
| `phy_init` | data/phy | 0x11000 | 4 KB | RF calibration |
| `ota_0` | app/ota_0 | 0x20000 | **1.8 MB** | Active firmware |
| `ota_1` | app/ota_1 | 0x1F0000 | **1.8 MB** | OTA update slot |
| `matter_nvs` | data/nvs | 0x3C0000 | 256 KB | Matter pairing data (isolated) |

The `matter_nvs` partition is isolated from the main `nvs` partition so that removing a device from Apple Home / Google Home / Alexa **only erases Matter pairing data** — Wi-Fi credentials and device config are unaffected.

### 8 MB Flash (`partitions_8mb.csv`) — Recommended for new hardware

| Partition | Type | Offset | Size | Purpose |
|---|---|---|---|---|
| `nvs` | data/nvs | 0x9000 | 24 KB | App config, Wi-Fi credentials, auth token |
| `otadata` | data/ota | 0xF000 | 8 KB | Bootloader OTA state (active bank) |
| `phy_init` | data/phy | 0x11000 | 4 KB | RF calibration |
| `ota_0` | app/ota_0 | 0x20000 | **3 MB** | Active firmware |
| `ota_1` | app/ota_1 | 0x320000 | **3 MB** | OTA update slot |
| `matter_nvs` | data/nvs | 0x620000 | 384 KB | Matter pairing data (isolated) |
| `storage` | data/spiffs | 0x680000 | 1.5 MB | Optional file storage |

---

## Quick Reference — GPIO Pin Map

| Signal | ESP32-C3 / C6 | ESP32-S3 | ESP32 Classic |
|---|---|---|---|
| Relay gang 1 | GPIO 2 | GPIO 4 | GPIO 26 |
| Relay gang 2 | GPIO 3 | GPIO 21 | GPIO 27 |
| Relay gang 3 | GPIO 4 | GPIO 47 | GPIO 25 |
| Relay gang 4 | GPIO 5 | GPIO 48 | GPIO 32 |
| Dimmer PWM | GPIO 3 | GPIO 5 | GPIO 27 |
| Warm white PWM | GPIO 4 | GPIO 6 | GPIO 14 |
| Cool white PWM | GPIO 5 | GPIO 7 | GPIO 12 |
| Red PWM | GPIO 6 | GPIO 15 | GPIO 25 |
| Green PWM | GPIO 7 | GPIO 16 | GPIO 32 |
| Blue PWM | GPIO 10 | GPIO 17 | GPIO 33 |
| NTC ADC temp | GPIO 1 | GPIO 1 | GPIO 34 |
| PIR motion | GPIO 11 | GPIO 18 | GPIO 35 |
| Reed contact | GPIO 20 | GPIO 19 | GPIO 36 |
| Status LED | GPIO 8 | GPIO 2 | GPIO 2 |
| Boot / factory reset | GPIO 9 | GPIO 0 | GPIO 0 |

> ESP32 classic GPIOs 34–39 are **input-only** — no internal pull resistors. Use external pull-up/pull-down on those pins.

---

## Quick Reference — Capability Strings

| Value | What it enables in the app |
|---|---|
| `relay` | On/Off toggle (Switch 1) |
| `relay_2` | On/Off toggle (Switch 2) |
| `relay_3` | On/Off toggle (Switch 3) |
| `relay_4` | On/Off toggle (Switch 4) |
| `brightness` | Brightness slider 0–100% |
| `color_temp` | Warm/cool white slider 2000–6500K |
| `rgb` | R/G/B sliders 0–255 each |
| `temperature` | Current temperature display (read-only) |
| `humidity` | Humidity % display (read-only) |
| `motion` | Motion detected / clear badge |
| `contact` | Open / closed badge |
| `hvac_mode` | Target temp +/−, mode chips (Cool / Heat / Auto / Off) |

---

## Quick Reference — All Device Build Commands

| Device | Edit file | Build command |
|---|---|---|
| 1-Gang Switch | `devices/1gang_switch/sdkconfig.defaults` | `.\scripts\build_device.ps1 1gang_switch esp32c3` |
| 2-Gang Switch | `devices/2gang_switch/sdkconfig.defaults` | `.\scripts\build_device.ps1 2gang_switch esp32c3` |
| 3-Gang Switch | `devices/3gang_switch/sdkconfig.defaults` | `.\scripts\build_device.ps1 3gang_switch esp32c3` |
| 4-Gang Switch | `devices/4gang_switch/sdkconfig.defaults` | `.\scripts\build_device.ps1 4gang_switch esp32c3` |
| Dimmer | `devices/dimmer/sdkconfig.defaults` | `.\scripts\build_device.ps1 dimmer esp32c3` |
| Colour Temp | `devices/colour_temp/sdkconfig.defaults` | `.\scripts\build_device.ps1 colour_temp esp32c3` |
| RGB Light | `devices/rgb_light/sdkconfig.defaults` | `.\scripts\build_device.ps1 rgb_light esp32s3` |
| Temp Sensor | `devices/temp_sensor/sdkconfig.defaults` | `.\scripts\build_device.ps1 temp_sensor esp32c3` |
| Motion Sensor | `devices/motion_sensor/sdkconfig.defaults` | `.\scripts\build_device.ps1 motion_sensor esp32c3` |
| Contact Sensor | `devices/contact_sensor/sdkconfig.defaults` | `.\scripts\build_device.ps1 contact_sensor esp32c3` |
| Thermostat | `devices/thermostat/sdkconfig.defaults` | `.\scripts\build_device.ps1 thermostat esp32s3` |
