# DSGV Hub Firmware — Flashing & Device Configuration Guide

> Reference for configuring, building, and flashing DSGV Hub firmware to ESP32 devices.
> Config file: `dsgv_firmware/include/dsgv_config.h`
> Runtime config: `dsgv_firmware/include/dsgv_device_config.h`

---

## Part 1 — One-time Setup

### Install ESP-IDF

**Windows:**
1. Download the installer from https://dl.espressif.com/dl/esp-idf/
2. Run it, accept defaults (~10 minutes)
3. Use **ESP-IDF Command Prompt** from Start menu for all commands below

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

## Part 2 — Navigate to the Project

```bash
cd path/to/IoT-Project/dsgv_firmware
# Windows example: cd C:\Users\YourName\Documents\IoT-Project\dsgv_firmware
```

---

## Part 3 — Configure Device Type

Open `dsgv_firmware/include/dsgv_config.h` and edit the top two lines.
Optionally update relay count and pins in the chip section below.

### The two lines you always edit

```c
#define dsgv_DEVICE_TYPE        "Switch"
#define dsgv_DEVICE_CAPABILITIES "[\"relay\"]"
```

---

### Device Configurations

#### A — 1-Gang Light Switch
```c
#define dsgv_DEVICE_TYPE        "Switch"
#define dsgv_DEVICE_CAPABILITIES "[\"relay\"]"

// In chip section:
#  define dsgv_RELAY_COUNT        1
#  define dsgv_RELAY_PINS         { GPIO_NUM_2 }   // C3/C6 example
```
**Wiring (ESP32-C3):**
```
GPIO2  ──► Relay IN
3.3V   ──► VCC
GND    ──► GND
```

---

#### B — 2-Gang Light Switch
```c
#define dsgv_DEVICE_TYPE        "Switch"
#define dsgv_DEVICE_CAPABILITIES "[\"relay\",\"relay_2\"]"

// In chip section:
#  define dsgv_RELAY_COUNT        2
#  define dsgv_RELAY_PINS         { GPIO_NUM_2, GPIO_NUM_3 }
```
**Wiring (ESP32-C3):**
```
GPIO2  ──► IN1 (Switch 1)
GPIO3  ──► IN2 (Switch 2)
3.3V   ──► VCC
GND    ──► GND
```
> ⚠️ GPIO3 doubles as the dimmer pin. Do not combine relay_2 and dimmer capabilities.

---

#### C — 3-Gang Light Switch
```c
#define dsgv_DEVICE_TYPE        "Switch"
#define dsgv_DEVICE_CAPABILITIES "[\"relay\",\"relay_2\",\"relay_3\"]"

#  define dsgv_RELAY_COUNT        3
#  define dsgv_RELAY_PINS         { GPIO_NUM_2, GPIO_NUM_3, GPIO_NUM_4 }
```

---

#### D — 4-Gang Light Switch
```c
#define dsgv_DEVICE_TYPE        "Switch"
#define dsgv_DEVICE_CAPABILITIES "[\"relay\",\"relay_2\",\"relay_3\",\"relay_4\"]"

#  define dsgv_RELAY_COUNT        4
#  define dsgv_RELAY_PINS         { GPIO_NUM_2, GPIO_NUM_3, GPIO_NUM_4, GPIO_NUM_5 }
```

---

#### E — Dimmer (PWM brightness)
```c
#define dsgv_DEVICE_TYPE        "Dimmer"
#define dsgv_DEVICE_CAPABILITIES "[\"relay\",\"dimmer\"]"

#  define dsgv_RELAY_COUNT        1
#  define dsgv_RELAY_PINS         { GPIO_NUM_2 }
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
```c
#define dsgv_DEVICE_TYPE        "Dimmer"
#define dsgv_DEVICE_CAPABILITIES "[\"relay\",\"color_temperature\"]"

#  define dsgv_RELAY_COUNT        1
#  define dsgv_RELAY_PINS         { GPIO_NUM_2 }
```
**Wiring (ESP32-C3):**
```
GPIO2  ──► Relay IN     (power)
GPIO4  ──► Warm white PWM
GPIO5  ──► Cool white PWM
GND    ──► GND
```

---

#### G — RGB Light
```c
#define dsgv_DEVICE_TYPE        "RGB"
#define dsgv_DEVICE_CAPABILITIES "[\"relay\",\"rgb_light\"]"

#  define dsgv_RELAY_COUNT        1
#  define dsgv_RELAY_PINS         { GPIO_NUM_2 }
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
```c
#define dsgv_DEVICE_TYPE        "Sensor"
#define dsgv_DEVICE_CAPABILITIES "[\"temperature_sensor\"]"

#  define dsgv_RELAY_COUNT        0
#  define dsgv_RELAY_PINS         { GPIO_NUM_NC }
```
No extra wiring needed — the ESP32-C3/C6/S3 has a built-in SOC temperature sensor.

**Optional external NTC thermistor for ambient temperature (ESP32-C3):**
```
3.3V ──┬── 10kΩ ──► NTC+ ──► GND
       └──► GPIO1 (ADC1)
```

---

#### I — Motion Sensor (PIR)
```c
#define dsgv_DEVICE_TYPE        "Sensor"
#define dsgv_DEVICE_CAPABILITIES "[\"motion_sensor\"]"

#  define dsgv_RELAY_COUNT        0
#  define dsgv_RELAY_PINS         { GPIO_NUM_NC }
```
**Wiring (ESP32-C3) — HC-SR501 PIR module:**
```
5V     ──► VCC
GND    ──► GND
GPIO11 ──► OUT (HIGH = motion)
```

---

#### J — Contact Sensor (door/window reed switch)
```c
#define dsgv_DEVICE_TYPE        "Sensor"
#define dsgv_DEVICE_CAPABILITIES "[\"contact_sensor\"]"

#  define dsgv_RELAY_COUNT        0
#  define dsgv_RELAY_PINS         { GPIO_NUM_NC }
```
**Wiring (ESP32-C3):**
```
3.3V   ──┬── 10kΩ pull-up ──► GPIO20
         └──► Reed switch ──► GND
```
LOW = closed (contact made), HIGH = open.

---

#### K — Thermostat (temperature sensor + HVAC relay)
```c
#define dsgv_DEVICE_TYPE        "Thermostat"
#define dsgv_DEVICE_CAPABILITIES "[\"temperature_sensor\",\"hvac_control\"]"

#  define dsgv_RELAY_COUNT        1
#  define dsgv_RELAY_PINS         { GPIO_NUM_2 }
```
The app shows current temp (read-only), target setpoint (+/− buttons), and mode chips (Cool / Heat / Auto / Off).
GPIO2 relay drives the HVAC unit's control input.

---

### Set MQTT Broker Address

```c
#define MQTT_CLOUD_HOST   "your-emqx-endpoint.cloud"  // cloud broker
#define MQTT_LOCAL_HOST   "192.168.1.100"              // local Mosquitto IP
```

The firmware tries the cloud broker first and falls back to local automatically.

---

## Part 4 — Build

### Set chip target (once per project)

```bash
idf.py set-target esp32c3    # ESP32-C3
idf.py set-target esp32c6    # ESP32-C6
idf.py set-target esp32s3    # ESP32-S3
idf.py set-target esp32      # classic ESP32
```

### Build

```bash
idf.py build
```

Common build errors:
- **Wrong chip selected** → re-run `idf.py set-target`
- **GPIO_NUM_NC error** → ensure relay count matches the pins array length
- **Redefined symbol** → check you're only editing the correct chip's `#if` block

---

## Part 5 — Flash

```bash
# Windows:
idf.py -p COM5 flash

# Mac:
idf.py -p /dev/tty.usbserial-0001 flash

# Linux:
idf.py -p /dev/ttyUSB0 flash
```

**If the board doesn't flash automatically:**
1. Hold **BOOT** button
2. Press and release **RESET/EN**
3. Release **BOOT**
Then re-run the flash command.

---

## Part 6 — Monitor Serial Output

```bash
# Windows:
idf.py -p COM5 monitor

# Mac/Linux:
idf.py -p /dev/ttyUSB0 monitor
```

Press **RESET** on the board. Expected output (2-gang switch example):
```
I dsgv_cfg:  No NVS device config — using compile-time defaults (type=Switch caps=["relay","relay_2"] relays=2)
I dsgv_gpio: GPIO ready (relay[0]=2 cnt=2 LED=8 ...)
I dsgv_mqtt: Connected. Device ID: AABBCCDDEEFF
I dsgv_mqtt: Published announce → devices/AABBCCDDEEFF/announce
```

Exit monitor: **Ctrl + ]**

**Reboot loop (watchdog / guru meditation):** Usually a wrong GPIO number. Check `dsgv_RELAY_COUNT` matches `dsgv_RELAY_PINS`, and no two features share a pin.

---

## Part 7 — Build + Flash + Monitor in One Command

```bash
idf.py -p COM5 flash monitor
```

---

## Part 8 — Configure via App (no reflash needed)

After flashing, the device type can be set from the app during BLE provisioning:

1. Scan QR on device label: `DSGV://provision?name=DSGVHub_XXXXXX`
2. Select **Device Type** preset in the pairing screen (1-Gang Switch, Dimmer, RGB Light, etc.)
3. Enter Wi-Fi credentials → tap **Provision**

The app sends device type, capabilities, and relay count over BLE. The firmware saves to NVS and reboots. From then on, NVS config overrides `dsgv_config.h` defaults. This means **one firmware binary works for all SKUs** — configure each device through the app.

To factory reset a device back to defaults: hold the **BOOT/GPIO0** button for 5 seconds.

---

## Quick Reference — GPIO Pin Map

| Signal | ESP32-C3 / C6 | ESP32-S3 | ESP32 Classic |
|---|---|---|---|
| Relay gang 1 | GPIO2 | GPIO4 | GPIO26 |
| Relay gang 2 | GPIO3 | GPIO21 | GPIO27 |
| Relay gang 3 | GPIO4 | GPIO47 | GPIO25 |
| Relay gang 4 | GPIO5 | GPIO48 | GPIO32 |
| Dimmer PWM | GPIO3 | GPIO5 | GPIO27 |
| Warm white PWM | GPIO4 | GPIO6 | GPIO14 |
| Cool white PWM | GPIO5 | GPIO7 | GPIO12 |
| Red PWM | GPIO6 | GPIO15 | GPIO25 |
| Green PWM | GPIO7 | GPIO16 | GPIO32 |
| Blue PWM | GPIO10 | GPIO17 | GPIO33 |
| NTC ADC temp | GPIO1 | GPIO1 | GPIO34 |
| PIR motion | GPIO11 | GPIO18 | GPIO35 |
| Reed contact | GPIO20 | GPIO19 | GPIO36 |
| Status LED | GPIO8 | GPIO2 | GPIO2 |
| Boot/factory reset | GPIO9 | GPIO0 | GPIO0 |

> ESP32 classic GPIOs 34–39 are **input-only** — no internal pull resistors. Use external pull-up/pull-down resistors on these pins.

---

## Capability Reference

| Capability string | What it enables in the app |
|---|---|
| `relay` | On/Off toggle (Switch 1) |
| `relay_2` | On/Off toggle (Switch 2) |
| `relay_3` | On/Off toggle (Switch 3) |
| `relay_4` | On/Off toggle (Switch 4) |
| `dimmer` | Brightness slider 0–100% |
| `color_temperature` | Warm/cool white slider 2000–6500K |
| `rgb_light` | R/G/B sliders 0–255 each |
| `temperature_sensor` | Current temperature display (read-only) |
| `humidity_sensor` | Humidity % display (read-only) |
| `motion_sensor` | Motion detected / clear badge |
| `contact_sensor` | Open / closed badge |
| `hvac_control` | Target temp +/−, mode chips (Cool/Heat/Auto/Off) |
