# DSGV Hub Firmware — Beginner Flashing Guide

---

## Before You Start — Read This First

**What is "flashing"?**
Flashing means copying firmware (the program) from your computer onto the ESP32 chip on your board over USB.

**What is ESP-IDF?**
It is Espressif's official toolkit that compiles the firmware source code into a binary file and sends it to the board. You install it once, then use it for all devices.

**Do I need to write any code?**
No. Everything is already written. The only decision you make is:
1. Which device are you building for? (e.g. `1gang_switch`, `dimmer`, `rgb_light`)
2. Which ESP32 chip is on your board? (ESP32-C3 is the default for most DSGV devices)

---

## Step 1 — Install ESP-IDF (one-time only)

### Windows

1. Download the Windows installer from:
   **https://dl.espressif.com/dl/esp-idf/**
   (Download the latest stable version — look for "Online" installer)

2. Run the installer. Accept all defaults. This takes about 10 minutes.

3. When it finishes, you will have two new shortcuts in your Start menu:
   - **ESP-IDF PowerShell**
   - **ESP-IDF Command Prompt**

   > **Important:** Always use one of these two shortcuts for every command in this guide.
   > Do NOT use a regular PowerShell or Command Prompt window — it won't have the right tools.

### Mac

Open Terminal and run these commands one at a time:

```bash
brew install cmake ninja dfu-util
mkdir ~/esp && cd ~/esp
git clone --recursive https://github.com/espressif/esp-idf.git
cd esp-idf
./install.sh
source ./export.sh
```

> You must run `source ~/esp/esp-idf/export.sh` every time you open a new Terminal window before using `idf.py`.

### Linux (Ubuntu/Debian)

```bash
sudo apt install git cmake ninja-build python3 python3-pip
mkdir ~/esp && cd ~/esp
git clone --recursive https://github.com/espressif/esp-idf.git
cd esp-idf
./install.sh
source ./export.sh
```

---

## Step 2 — Install the USB Driver (one-time only)

Your ESP32 board connects to your computer via a small USB-to-serial chip. You need the correct driver for your OS to see it.

**Find the chip:** Look at the small IC (integrated circuit) next to the USB port on your board and match it below.

| Chip marking | Driver to install |
|---|---|
| **CP2102** or **CP2104** | https://www.silabs.com/developers/usb-to-uart-bridge-vcp-drivers |
| **CH340** or **CH341** | Search "CH340 driver" for your OS and download from the manufacturer |

After installing the driver, plug in your board via USB.

---

## Step 3 — Find Your COM Port

You need to know which port your board is connected to before you can flash it.

**Windows:**
1. Open **Device Manager** (press `Win + X` → Device Manager)
2. Expand **Ports (COM & LPT)**
3. Look for something like `Silicon Labs CP210x USB to UART Bridge (COM5)`
4. Note the COM number — e.g. **COM5**

**Mac:**
```bash
ls /dev/tty.*
```
Look for `/dev/tty.usbserial-0001` or similar.

**Linux:**
```bash
ls /dev/ttyUSB*
```
Look for `/dev/ttyUSB0`.

> If you don't see your board listed, the USB driver is not installed correctly (go back to Step 2).

---

## Step 4 — Navigate to the Project Folder

Open your **ESP-IDF PowerShell** (Windows) or Terminal (Mac/Linux) and navigate to the firmware folder:

```powershell
cd C:\Users\YourName\OneDrive\Documents\AI_projects\IoT-Project\dsgv_firmware
```

Replace `YourName` with your actual Windows username. You can also right-click the `dsgv_firmware` folder in File Explorer → "Open in Terminal".

---

## Step 5 — Pick Your Device and Flash It

This is the only step that changes each time. Run one command.

### The command format is:
```powershell
.\scripts\build_device.ps1  <device_name>  <chip>  <COM_port>
```

- **`<device_name>`** — which device you're building (see table below)
- **`<chip>`** — which ESP32 chip is on your board (see table below)
- **`<COM_port>`** — the port from Step 3 (e.g. `COM5`)

### Device names

| What you're building | `<device_name>` |
|---|---|
| 1-gang light switch | `1gang_switch` |
| 2-gang light switch | `2gang_switch` |
| 3-gang light switch | `3gang_switch` |
| 4-gang light switch | `4gang_switch` |
| Dimmer (brightness control) | `dimmer` |
| Colour temperature light | `colour_temp` |
| RGB light | `rgb_light` |
| Temperature / humidity sensor | `temp_sensor` |
| Motion sensor (PIR) | `motion_sensor` |
| Door / window contact sensor | `contact_sensor` |
| Thermostat | `thermostat` |

### Chip names

| Chip on your board | `<chip>` |
|---|---|
| ESP32-C3 ← most common DSGV device | `esp32c3` |
| ESP32-C6 | `esp32c6` |
| ESP32-S3 | `esp32s3` |
| ESP32 (classic, no letter suffix) | `esp32` |

> **Not sure which chip you have?** Look for text printed on the large silver or black module on your board. It will say ESP32-C3, ESP32-S3, etc.

### Example commands

```powershell
# Flash a 1-gang switch on an ESP32-C3 connected to COM5
.\scripts\build_device.ps1 1gang_switch esp32c3 COM5

# Flash a dimmer on an ESP32-C3 connected to COM7
.\scripts\build_device.ps1 dimmer esp32c3 COM7

# Flash an RGB light on an ESP32-S3 connected to COM3
.\scripts\build_device.ps1 rgb_light esp32s3 COM3
```

The script will:
1. Compile the firmware for your chosen device and chip (~2 minutes first time, faster after)
2. Check the binary fits in the flash chip
3. Flash it to your board automatically

When it finishes successfully you will see something like:
```
Hash of data verified.
Leaving...
Hard resetting via RTS pin...
```

---

## Step 6 — If the Board Doesn't Flash Automatically

Some boards need to be manually put into flash mode.

1. Hold the **BOOT** button on the board
2. While holding BOOT, press and release the **RESET** (or **EN**) button
3. Release **BOOT**
4. Re-run the same flash command

---

## Step 7 — First Flash on a Brand New Board

The very first time you flash a new board (or if you change the flash size), you must erase the chip first:

```bash
# From inside the device folder (cd devices/1gang_switch first):
idf.py -p COM5 erase_flash
```

Then flash normally:
```powershell
.\scripts\build_device.ps1 1gang_switch esp32c3 COM5
```

---

## Step 8 — Check It Worked (Serial Monitor)

After flashing, you can watch the boot log to confirm the firmware is running correctly.

**Windows (from inside the device folder):**
```bash
cd devices\1gang_switch
idf.py -p COM5 monitor
```

Press **RESET** on the board. You should see output like:
```
I DSGV_main: === DSGV Hub Firmware v1.0.0 Booting ===
I DSGV_cfg:  No NVS config — using compile-time defaults (type=Switch ...)
I dsgv_gpio: GPIO ready (relay[0]=2 ...)
I dsgv_gpio: Wall switches: 1 input(s) → pins [18,19,20,21]
I dsgv_mqtt: Connected. Device ID: AABBCCDDEEFF
```

Exit the monitor: press **Ctrl + ]**

---

## Do I Need to Edit Any Files?

**In almost all cases: No.**

The device configuration files (`sdkconfig.defaults`) already have the correct settings for each device. You do not uncomment anything. You do not edit GPIO numbers. You just run the build command with the right device name and chip.

The only times you would edit a file:

| Situation | What to change | Where |
|---|---|---|
| Using 8 MB flash hardware instead of 4 MB | Change partition table line | Device's `sdkconfig.defaults` |
| Changing your MQTT broker address | Change `MQTT_CLOUD_HOST` | `components/dsgv_common/include/dsgv_config.h` |

---

## Wiring Reference — GPIO Outputs (Relay) and Inputs (Wall Switch)

Wire your relay module and optional physical wall switch to these pins.

**Wall switch wiring:** Connect one terminal of the switch to the GPIO pin listed, and the other terminal to **GND**. No resistor needed — the firmware uses the internal pull-up.

### ESP32-C3 (most common)

| Signal | GPIO | Notes |
|---|---|---|
| Relay gang 1 (output) | **2** | Connect to relay module IN1 |
| Relay gang 2 (output) | **3** | IN2 — 2-gang and above only |
| Relay gang 3 (output) | **4** | IN3 — 3-gang and above only |
| Relay gang 4 (output) | **5** | IN4 — 4-gang only |
| Wall switch 1 (input) | **18** | Switch to GND, no resistor |
| Wall switch 2 (input) | **19** | Switch to GND, no resistor |
| Wall switch 3 (input) | **20** | Switch to GND, no resistor |
| Wall switch 4 (input) | **21** | Switch to GND, no resistor |
| Dimmer PWM (output) | **3** | Dimmer device only |
| Warm white PWM (output) | **4** | Colour temp device only |
| Cool white PWM (output) | **5** | Colour temp device only |
| Red PWM (output) | **6** | RGB device only |
| Green PWM (output) | **7** | RGB device only |
| Blue PWM (output) | **10** | RGB device only |
| PIR motion sensor (input) | **11** | HIGH = motion detected |
| Contact / reed switch (input) | **20** | LOW = closed |
| Status LED (output) | **8** | Mirrors gang 1 state |
| Factory reset button (input) | **9** | Hold 5 s to reset |

> On C3 dev kits, GPIO 18 and 19 are also the USB-JTAG pins. They work fine as wall switch inputs on production PCBs that don't use USB for those signals.

### ESP32-S3

| Signal | GPIO |
|---|---|
| Relay gang 1 | 4 |
| Relay gang 2 | 21 |
| Relay gang 3 | 47 |
| Relay gang 4 | 48 |
| Wall switch 1 | 36 |
| Wall switch 2 | 37 |
| Wall switch 3 | 38 |
| Wall switch 4 | 39 |
| Dimmer PWM | 5 |
| Warm white PWM | 6 |
| Cool white PWM | 7 |
| Red PWM | 15 |
| Green PWM | 16 |
| Blue PWM | 17 |
| PIR motion | 18 |
| Contact sensor | 19 |
| Status LED | 2 |
| Factory reset | 0 |

### ESP32 Classic

| Signal | GPIO | Notes |
|---|---|---|
| Relay gang 1 | 26 | |
| Relay gang 2 | 27 | |
| Relay gang 3 | 25 | |
| Relay gang 4 | 32 | |
| Wall switch 1 | 13 | |
| Wall switch 2 | 16 | |
| Wall switch 3 | 17 | |
| Wall switch 4 | 18 | |
| Dimmer PWM | 27 | |
| Warm white PWM | 14 | |
| Cool white PWM | 12 | |
| Red PWM | 25 | |
| Green PWM | 32 | |
| Blue PWM | 33 | |
| PIR motion | 35 | Input-only, needs external pull-down |
| Contact sensor | 36 | Input-only, needs external pull-up |
| Status LED | 2 | |
| Factory reset | 0 | |

> GPIO 34–39 on the classic ESP32 are input-only and have **no** internal pull resistors. Use an external pull-up or pull-down resistor on those pins.

---

## How the Wall Switch Works

The wall switch input is optional. If you don't wire a switch, everything works via the app only.

If you do wire a switch:
- Pressing the switch (or flicking a rocker) **toggles** the relay — ON becomes OFF, OFF becomes ON.
- Works with **latching rocker switches** (standard wall switch) and **momentary push buttons**.
- After each physical toggle, the firmware immediately updates the app over MQTT so the app always shows the correct state.
- App control and physical control work independently and are always in sync.

---

## Configure a Device via the App (No Reflash Needed)

After flashing, you can change the device type from the app during BLE provisioning — so one binary can serve multiple SKU types without reflashing.

1. Scan the QR code on the device label: `DSGV://provision?name=DSGVHub_XXXXXX`
2. Select the **Device Type** preset in the pairing screen
3. Enter Wi-Fi credentials → tap **Provision**

The app sends the new config over BLE. The firmware saves it and reboots.

To factory-reset back to the flashed defaults: hold the **BOOT** button for **5 seconds**.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| "Port not found" or "No serial data" | Check Device Manager — is the COM port listed? Reinstall USB driver. Try a different USB cable (some are charge-only). |
| Board doesn't enter flash mode | Use the manual BOOT + RESET sequence in Step 6. |
| Build fails: `CONFIG_DSGV_*` undefined | You ran the script from inside a device folder. Run it from the repo root (`dsgv_firmware/`). |
| Build fails: `Cannot find component dsgv_common` | Same as above — must be at repo root for the PowerShell script. |
| Build fails: wrong chip | Delete the `build/` folder inside the device folder and re-run with the correct chip name. |
| App doesn't find the device | Check the serial monitor — confirm `dsgv_mqtt: Connected` appears. Check Wi-Fi credentials. |
| Factory reset | Hold BOOT button for 5 seconds while powered on. |

---

## Upgrading to 8 MB Flash Hardware

If your board has 8 MB flash (check the module label or your order), open the device's `sdkconfig.defaults` and change the partition line:

```ini
# Remove this line:
CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="../../partitions_4mb.csv"

# Add these two lines:
CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="../../partitions_8mb.csv"
CONFIG_ESPTOOLPY_FLASHSIZE_8MB=y
```

Then erase and reflash:
```bash
idf.py -p COM5 erase_flash
.\scripts\build_device.ps1 <device> <chip> COM5
```

---

## Flash Layout Reference

### 4 MB Flash (default)

| Partition | Size | Purpose |
|---|---|---|
| nvs | 24 KB | Wi-Fi credentials, device config, auth token |
| otadata | 8 KB | Tracks which firmware bank is active |
| phy_init | 4 KB | RF calibration data |
| ota_0 | **1.8 MB** | Active firmware |
| ota_1 | **1.8 MB** | OTA update slot |
| matter_nvs | 256 KB | Matter pairing data (isolated) |

### 8 MB Flash

| Partition | Size | Purpose |
|---|---|---|
| nvs | 24 KB | Wi-Fi credentials, device config, auth token |
| otadata | 8 KB | Tracks which firmware bank is active |
| phy_init | 4 KB | RF calibration data |
| ota_0 | **3 MB** | Active firmware |
| ota_1 | **3 MB** | OTA update slot |
| matter_nvs | 384 KB | Matter pairing data (isolated) |
| storage | 1.5 MB | Optional file storage |

> The `matter_nvs` partition is kept separate from the main `nvs` partition. Removing the device from Apple Home / Google Home / Alexa only erases Matter pairing data — your Wi-Fi credentials and device config are unaffected.

---

## Capability Strings Reference

These are the values in `CONFIG_DSGV_DEVICE_CAPABILITIES` and what each one enables in the app.

| Value | App feature |
|---|---|
| `relay` | On/Off toggle (gang 1) |
| `relay_2` | On/Off toggle (gang 2) |
| `relay_3` | On/Off toggle (gang 3) |
| `relay_4` | On/Off toggle (gang 4) |
| `brightness` | Brightness slider 0–100% |
| `color_temp` | Warm/cool white slider 2000–6500 K |
| `rgb` | R/G/B colour sliders |
| `temperature` | Current temperature display (read-only) |
| `humidity` | Humidity % display (read-only) |
| `motion` | Motion detected / clear badge |
| `contact` | Open / closed badge |
| `hvac_mode` | Target temp setpoint + mode selector (Cool / Heat / Auto / Off) |
