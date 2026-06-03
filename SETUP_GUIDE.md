# DSGV Hub — Complete Setup Guide

This guide walks you through setting up the entire DSGV Hub platform from scratch: Firebase in the cloud, firmware on the ESP32, and the Flutter app on your phone. You do not need prior experience with embedded development, Firebase, or MQTT. Each step explains what you are doing and why, not just which command to type.

**Time estimate:** First complete setup takes 2–3 hours. After that, building and flashing a new device type takes about 5 minutes.

---

## What is DSGV Hub?

DSGV Hub is a smart home platform with three parts that work together:

1. **ESP32 Firmware** — C code that runs on the physical device. It controls the hardware (relays, dimmers, RGB lights, sensors, thermostat), connects to your WiFi, and communicates over MQTT.

2. **Flutter Mobile App** — the app you install on your Android or iOS phone. It provisions new devices via Bluetooth, shows a live dashboard, and lets you control everything remotely or locally.

3. **Firebase** — a Google cloud service used for two things: storing broker configuration so devices can fetch it on boot, and acting as the bridge to Google Home and Alexa voice control.

**How control flows:**

- **First setup:** Flash firmware → scan QR in app → Bluetooth provisioning (sends WiFi credentials + device type) → device joins your network → appears on dashboard
- **Remote control:** App → MQTT broker → device
- **Local control:** App → finds device on LAN via mDNS → HTTP directly to device (faster, works without internet)
- **Voice control:** Google Home or Alexa → Firebase Cloud Function → MQTT → device

---

## What is Firebase?

Firebase is Google's cloud backend platform. You get a project with a URL and a database, and you pay nothing until you exceed free-tier limits (which takes significant traffic).

DSGV Hub uses two Firebase features:

- **Cloud Functions** — small pieces of server code that run on demand. You do not manage a server; Google runs the code when it receives an HTTP request. DSGV has 11 functions: device registration, config delivery, state updates, OAuth authentication for voice assistants, and the Google Home and Alexa smart home handlers.

- **Realtime Database (RTDB)** — a cloud JSON database. When a device publishes telemetry over MQTT, a bridge process writes that state to RTDB. When Google Home asks "is the kitchen light on?", it reads from RTDB. This is what keeps voice assistants in sync without them having to talk to the MQTT broker directly.

---

## What is MQTT?

MQTT is a lightweight messaging protocol designed for IoT devices. Think of it as a pub/sub message bus: devices **publish** messages to named channels called **topics**, and apps or other services **subscribe** to receive them.

A topic looks like a file path: `devices/A1B2C3D4E5F6/telemetry`. The device publishes its current state to this topic every 30 seconds. The app subscribes and updates its display whenever a new message arrives.

MQTT uses far less bandwidth and battery than HTTP polling, and it works well on unreliable networks. All DSGV communication uses MQTT over TLS on port 8883.

---

## Three constants you must update before anything works

These three placeholders appear across multiple files. Every section of this guide will remind you which file to edit. Do them all together in Part 1 so you do not forget.

| Constant | Placeholder | Files to edit |
|---|---|---|
| **Firebase Project ID** | `YOUR_FIREBASE_PROJECT_ID` | `dsgv_hub_app/.firebaserc` line 3 |
| **Firebase Cloud Function base URL** | `YOUR_PROJECT_ID` | `dsgv_hub_app/lib/domain/services/firebase_config_service.dart` line 11, `dsgv_firmware/components/dsgv_common/include/dsgv_config.h` line 34 |
| **MQTT broker hostname** | `mqtt.dsgv.io` | `dsgv_hub_app/lib/domain/models/mqtt_config.dart` line 8, `dsgv_firmware/components/dsgv_common/include/dsgv_config.h` line 42, `dsgv_hub_app/functions/index.js` line 16 |

The MQTT broker hostname is the address of whatever MQTT broker you are running (your own EMQX, Mosquitto, HiveMQ Cloud, etc.). If you are still evaluating the platform and do not have a broker yet, skip the broker updates for now and come back to them once you have one running.

---

## Part 0 — What You Need Before You Start

### Hardware

- An ESP32 development board. **ESP32-C3 is recommended** for new builds — it has native USB support, runs DSGV firmware well, and its pin count matches the default GPIO assignments in `dsgv_config.h`. Other supported chips: ESP32-C6, ESP32-S3, classic ESP32.
- A USB cable that carries **data**, not just power. Many cheap cables are charge-only and will not show up as a serial port. If your computer does not detect the board, try a different cable first.
- A Windows, macOS, or Linux computer.

### Accounts

- A **Google account** (for Firebase and optionally Google Home voice control).
- Optionally, an **Amazon developer account** (for Alexa skill setup).

### Software to install

Work through this list before starting — having everything ready avoids interruptions mid-guide.

| Software | Purpose | Where to get it |
|---|---|---|
| **Git** | Clone the repository | git-scm.com |
| **Node.js 20** | Run Firebase CLI and deploy Cloud Functions | nodejs.org — download the LTS version |
| **Firebase CLI** | Deploy functions and rules | Installed via npm (Step 1 below) |
| **VS Code** | IDE for both firmware and app development | code.visualstudio.com |
| **Espressif IDF extension** | Installs ESP-IDF 5.x and provides build/flash/monitor buttons | VS Code Extensions marketplace |
| **Flutter SDK** | Build and run the mobile app | flutter.dev/docs/get-started/install |

---

## Part 1 — Firebase Setup

Do this first. The firmware cannot fetch its broker config, and the app cannot register devices, until Firebase is live.

### Step 1 — Create a Firebase project

1. Go to [console.firebase.google.com](https://console.firebase.google.com) and sign in with your Google account.
2. Click **Add project**.
3. Enter a project name such as `dsgv-hub`. Firebase will suggest a unique project ID like `dsgv-hub-a1b2c` — this is the value you will use in all three constant updates. Note it down now.
4. On the next screen, **disable Google Analytics** (not needed for this platform).
5. Click **Create project** and wait about 30 seconds.

You should see your new project dashboard. The URL in your browser will include the project ID, for example `console.firebase.google.com/project/dsgv-hub-a1b2c`.

### Step 2 — Enable Realtime Database

1. In the left sidebar, click **Build → Realtime Database**.
2. Click **Create database**.
3. Choose a region close to you (e.g. `us-central1` for the Americas, `europe-west1` for Europe). **This region also determines your Cloud Functions URL.** If you choose `europe-west1`, your function URLs will be `https://europe-west1-YOUR_PROJECT_ID.cloudfunctions.net/...` instead of `us-central1`. Make a note of it.
4. Select **Start in locked mode** and click **Enable**.

The database is now ready. It starts empty — devices will populate it automatically as they come online.

### Step 3 — Note your Project ID

1. Click the gear icon next to **Project Overview** in the top-left sidebar.
2. Select **Project settings**.
3. On the **General** tab, find **Project ID** — it looks like `dsgv-hub-a1b2c`.
4. Also note the **Web API key** on this page — you will need it in Step 8 for OAuth.

### Step 4 — Update the three constants

Now that you have your project ID, update the placeholder values in the codebase.

**File 1: `dsgv_hub_app/.firebaserc` (line 3)**

Open the file. It currently reads:
```json
{
  "projects": {
    "default": "YOUR_FIREBASE_PROJECT_ID"
  }
}
```
Replace `YOUR_FIREBASE_PROJECT_ID` with your actual project ID:
```json
{
  "projects": {
    "default": "dsgv-hub-a1b2c"
  }
}
```

**File 2: `dsgv_hub_app/lib/domain/services/firebase_config_service.dart` (line 11)**

Find the line:
```dart
    'https://us-central1-YOUR_PROJECT_ID.cloudfunctions.net';
```
Replace `YOUR_PROJECT_ID` with your project ID (and update the region if you chose something other than `us-central1`):
```dart
    'https://us-central1-dsgv-hub-a1b2c.cloudfunctions.net';
```

**File 3: `dsgv_firmware/components/dsgv_common/include/dsgv_config.h` (line 34)**

Find the line:
```c
    "https://us-central1-YOUR_PROJECT_ID.cloudfunctions.net/getDeviceConfig"
```
Replace `YOUR_PROJECT_ID`:
```c
    "https://us-central1-dsgv-hub-a1b2c.cloudfunctions.net/getDeviceConfig"
```

> **Tip:** The URL in `dsgv_config.h` must end with `/getDeviceConfig` — that is the specific function the firmware calls on every boot to retrieve its broker configuration. The base URL in `firebase_config_service.dart` does not include a function name — the Dart code appends the function name when it makes each request.

> **Warning:** If you chose a region other than `us-central1` when creating the Realtime Database, your Cloud Functions may still deploy to `us-central1` unless you specify otherwise. Check your deployed function URLs in Firebase Console → Functions after Step 7 and update these constants if they differ.

### Step 5 — Enable Firebase Authentication

The mobile app and OAuth server need Firebase Auth to verify user credentials.

1. In the Firebase Console sidebar, click **Build → Authentication**.
2. Click **Get started**.
3. Click the **Sign-in method** tab.
4. Click **Email/Password** and toggle **Enable** on. Leave the second toggle (Passwordless email link) off.
5. Click **Save**.

### Step 6 — Create a test user account

This is the account you will use when linking to Google Home or Alexa. It is your DSGV identity — devices are linked to this account.

1. Still in **Authentication**, click the **Users** tab.
2. Click **Add user**.
3. Enter your email address and a strong password.
4. Click **Add user**.

You should see your user appear in the list with a UID like `abc123def456...`. This UID is how Firebase identifies your account internally.

### Step 7 — Install Firebase CLI and deploy

The Firebase CLI is a command-line tool for deploying functions, rules, and other Firebase resources.

```bash
npm install -g firebase-tools
```

Expected output:
```
added 612 packages in 18s
```

Log in with your Google account:
```bash
firebase login
```

Expected output: a browser window opens. Sign in with the same Google account that owns your Firebase project. When complete, the terminal shows:
```
✔  Success! Logged in as your@email.com
```

Install the Cloud Functions dependencies:
```bash
cd dsgv_hub_app/functions
npm install
```

Expected output:
```
added 147 packages in 6s
```

Go back to the app directory and deploy everything (functions + database rules):
```bash
cd ..
firebase deploy
```

Expected output (abbreviated — you will see one line per function):
```
=== Deploying to 'dsgv-hub-a1b2c'...

i  deploying functions, database

✔  functions[registerDevice(us-central1)]: Successful create operation.
✔  functions[getDeviceConfig(us-central1)]: Successful create operation.
✔  functions[updateDeviceConfig(us-central1)]: Successful create operation.
✔  functions[revertDeviceToFactory(us-central1)]: Successful create operation.
✔  functions[updateDeviceState(us-central1)]: Successful create operation.
✔  functions[linkDeviceToUser(us-central1)]: Successful create operation.
✔  functions[oauthLoginPage(us-central1)]: Successful create operation.
✔  functions[oauthAuthorize(us-central1)]: Successful create operation.
✔  functions[oauthToken(us-central1)]: Successful create operation.
✔  functions[googleSmartHome(us-central1)]: Successful create operation.
✔  functions[alexaSmartHome(us-central1)]: Successful create operation.
✔  database: rules from database.rules.json deployed to https://dsgv-hub-a1b2c-default-rtdb.firebaseio.com

✔  Deploy complete!
```

All 11 functions deployed. If any function fails, re-run `firebase deploy` — transient network errors are common and retrying almost always succeeds.

### Step 8 — Set OAuth secrets

The OAuth server needs credentials from Google Home and Alexa, plus your Firebase Web API key. These are secrets that must not be committed to source control — Firebase Functions config stores them server-side.

Run the following command, replacing each placeholder value with your actual secrets. You will obtain the Google and Alexa client credentials when you set up those platforms in Part 6. For now, set the Firebase API key and bridge secret — the voice assistant secrets can be added later.

```bash
firebase functions:config:set \
  oauth.google_client_id="YOUR_GOOGLE_CLIENT_ID" \
  oauth.google_client_secret="YOUR_GOOGLE_CLIENT_SECRET" \
  oauth.alexa_client_id="YOUR_ALEXA_CLIENT_ID" \
  oauth.alexa_client_secret="YOUR_ALEXA_CLIENT_SECRET" \
  oauth.firebase_web_api_key="YOUR_FIREBASE_WEB_API_KEY" \
  oauth.token_secret="$(openssl rand -hex 32)" \
  bridge.secret="$(openssl rand -hex 32)"
```

The `openssl rand -hex 32` commands generate random 64-character hex strings as signing secrets. If you do not have `openssl`, replace them with any long random strings you generate yourself.

After setting config, redeploy functions so they pick up the new values:

```bash
firebase deploy --only functions
```

> **Tip:** To see the current config at any time, run `firebase functions:config:get`. Secrets are stored in Firebase and never visible in the source code.

> **Warning:** The `oauth.firebase_web_api_key` is the **Web API key** from Firebase Console → Project Settings → General, not the Firebase Admin SDK service account key. They are different. The Web API key is safe to use in server-side Firebase Auth REST calls.

### Step 9 — Verify the deployment with a quick test

Test the `registerDevice` function with a curl command to confirm it is reachable:

```bash
curl -s -X POST \
  https://us-central1-dsgv-hub-a1b2c.cloudfunctions.net/registerDevice \
  -H "Content-Type: application/json" \
  -d '{"device_id":"AABBCCDDEEFF","auth_token":"00112233445566778899AABBCCDDEEFF"}'
```

Expected response:
```json
{"success":true}
```

If you get a `{"success":true,"already_registered":true}` response on a second call with the same device ID, that is also correct — registration is idempotent.

If you get a network error or HTML error page, check that the project ID in the URL matches your `.firebaserc` and that the deploy completed successfully.

---

## Part 2 — Firmware Setup

### Step 1 — Install VS Code and the Espressif IDF extension

1. Download and install [VS Code](https://code.visualstudio.com).
2. Open VS Code and press `Ctrl+Shift+X` (Windows/Linux) or `Cmd+Shift+X` (macOS) to open Extensions.
3. Search for **Espressif IDF** and install the extension by Espressif Systems.
4. After installation, a setup wizard opens automatically. If it does not, open the Command Palette (`Ctrl+Shift+P`) and run **ESP-IDF: Configure ESP-IDF Extension**.
5. Select **EXPRESS** setup.
6. Select version **v5.x** (the latest v5 release).
7. Click **Install**. The wizard downloads the full toolchain, which takes 5–15 minutes depending on your connection.

When installation completes, you will see a success message. Open a new terminal inside VS Code and verify:

```bash
idf.py --version
```

Expected output:
```
ESP-IDF v5.3.1
```

(The exact patch version may differ — any v5.x is correct.)

> **Tip:** The Espressif extension also adds toolbar buttons at the bottom of VS Code: a chip selector, a build button (hammer icon), a flash button, and a monitor button. These do the same thing as the `make` commands in this guide. Use whichever you prefer.

### Step 2 — Install the USB-to-serial driver

Your ESP32 dev board has a small USB bridge chip that converts USB signals to the serial protocol the ESP32 understands. Look at the small chip near the USB port on your board:

| Chip marking on board | Driver |
|---|---|
| **CP2102** or **CP210x** | Silicon Labs CP210x — search "CP210x Windows VCP Drivers" on silabs.com |
| **CH340** or **CH341** | Search "CH340 driver" — the WCH website has downloads for all platforms |
| **FT232** or **FTDI** | ftdichip.com → Drivers → VCP Drivers |

ESP32-C3 dev boards often use CH340 or CP2102. If you cannot see the chip marking, try the CP2102 driver first — it covers the majority of popular boards.

After installing, plug in your board via USB and find its port:

```bash
# macOS
ls /dev/cu.*
# Look for something like /dev/cu.usbserial-0001 or /dev/cu.SLAB_USBtoUART

# Linux
ls /dev/ttyUSB*
# Look for /dev/ttyUSB0

# Windows
# Open Device Manager → Ports (COM & LPT) → note the COM number, e.g. COM5
```

If nothing appears, the driver is not installed or the cable is charge-only. Try a different cable before reinstalling the driver.

### Step 3 — Open the firmware project

In VS Code, open the `dsgv_firmware` folder (not the whole repository root — open just that subfolder so the ESP-IDF extension picks up the correct `CMakeLists.txt`):

- **File → Open Folder → select `IoT-Project/dsgv_firmware`**

The extension will detect the ESP-IDF project and show the build toolbar at the bottom.

### Step 4 — Update dsgv_config.h

Open `dsgv_firmware/components/dsgv_common/include/dsgv_config.h`.

There are two lines to update:

**Line 34 — Firebase Cloud Function URL:**
```c
#define FIREBASE_GET_CONFIG_URL \
    "https://us-central1-YOUR_PROJECT_ID.cloudfunctions.net/getDeviceConfig"
```

Replace with your project ID (you already did this in Part 1 Step 4 — just confirm it is correct here):
```c
#define FIREBASE_GET_CONFIG_URL \
    "https://us-central1-dsgv-hub-a1b2c.cloudfunctions.net/getDeviceConfig"
```

`FIREBASE_GET_CONFIG_URL` is the address the firmware calls on every boot after WiFi connects. The device sends its MAC address and auth token to this function, and the function responds with the MQTT broker host, port, TLS flag, and credentials. This is how you can change the broker for all devices centrally without reflashing them.

**Line 42 — MQTT broker hostname:**
```c
#define MQTT_CLOUD_HOST          "mqtt.dsgv.io"
```

Replace with your broker's hostname:
```c
#define MQTT_CLOUD_HOST          "mqtt.yourdomain.com"
```

`MQTT_CLOUD_HOST` is the factory default — baked into the firmware binary. The device uses it on first boot before it has fetched its config from Firebase. After the first successful fetch, the Firebase-provided value takes over and is cached in NVS (the device's non-volatile storage), so a subsequent Firebase failure does not leave the device without a broker.

> **Warning:** `MQTT_CLOUD_HOST` must match the `host` field in `MqttConfig.factoryDefault` in `dsgv_hub_app/lib/domain/models/mqtt_config.dart` (line 8) and the `broker_host` in `FACTORY_CONFIG` in `dsgv_hub_app/functions/index.js` (line 16). All three must be identical, or the device and app will disagree about the factory broker.

### Step 5 — Wire your device

Before building, confirm you know how to wire your ESP32 board to the relay, dimmer, sensor, or other hardware for the device type you are building.

See **`FLASHING_GUIDE.md`** (in the project root) for the complete wiring diagram for each of the 11 device types, including GPIO pin maps for each supported chip.

For a first build, you do not need to wire anything — you can build and flash the firmware to a bare ESP32 dev board and read the serial monitor to confirm it boots correctly.

### Step 6 — Build your first device type

Open a terminal in the `dsgv_firmware` directory and run:

```bash
make DEVICE=1gang_switch TARGET=esp32c3 build
```

What this does: the Makefile calls `idf.py -C devices/1gang_switch -DIDF_TARGET=esp32c3 build`, which compiles the shared component (`dsgv_common`) and the device-specific main entry point, then links everything into a flashable binary.

Expected output (last few lines):
```
[994/994] Generating binary image from built executables
esptool.py v4.8.1
Creating esp32c3 image...
Merged 2 ELF sections
Successfully created esp32c3 image.
Generated /home/user/IoT-Project/dsgv_firmware/devices/1gang_switch/build/1gang_switch.bin
Binary size 0x134b10 bytes. Smallest app partition is 0x1f0000 bytes. 0xbb4f0 bytes (60%) free.

Project build complete. To flash, run:
  make DEVICE=1gang_switch TARGET=esp32c3 PORT=/dev/ttyUSB0 flash
```

The key line is `Binary size ... bytes. Smallest app partition is ... free.` — as long as there is free space, the build succeeded. If you see `ERROR: app binary is too large`, the binary is over the partition limit; this usually means an incompatible sdkconfig option was enabled.

> **Tip:** Subsequent builds of the same device are much faster because only changed files are recompiled. The first build compiles hundreds of ESP-IDF components and takes 3–8 minutes. After that, a rebuild with one changed source file takes 15–30 seconds.

### Step 7 — Flash the firmware

Plug in your ESP32 board. Find the serial port (you identified it in Step 2). Then:

```bash
make DEVICE=1gang_switch TARGET=esp32c3 PORT=/dev/ttyUSB0 fm
```

The `fm` target flashes and then immediately opens the serial monitor — the most common workflow. Replace `/dev/ttyUSB0` with your actual port (e.g. `COM5` on Windows, `/dev/cu.usbserial-0001` on macOS).

Expected output during flash:
```
esptool.py v4.8.1
Serial port /dev/ttyUSB0
Connecting...
Detecting chip type... ESP32-C3
Chip is ESP32-C3 (QFN32) (revision v0.4)
...
Compressed 1264400 bytes to 757211...
Writing at 0x00010000... (100 %)
Leaving...
Hard resetting via RTS pin...
```

After flash, the monitor starts automatically. Press `Ctrl+]` to exit the monitor.

> **Warning:** On some Linux systems, your user account may not have permission to access `/dev/ttyUSB0`. If you get `Permission denied`, run `sudo usermod -a -G dialout $USER`, then log out and back in.

### Step 8 — Read the serial monitor

This is the most important debugging tool you have. The firmware logs every significant event with a tag that tells you exactly which module produced it.

**First boot — no WiFi credentials (BLE provisioning mode):**

```
I (312)  DSGV_cfg:   No WiFi credentials in NVS — starting BLE provisioning
I (315)  DSGV_Prov:  BLE advertising started — device name: DSGVHub_DDEEFF
I (316)  DSGV_Prov:  Waiting for Flutter app to send credentials...
```

This is the correct state for a brand-new device. The device is advertising over Bluetooth and waiting for the app to connect and send WiFi credentials. The 6-character suffix (`DDEEFF`) is the last 6 hex characters of the device's WiFi MAC address — you will need this for the QR code in Part 4.

**Successful normal boot (after provisioning):**

```
I (312)  DSGV_cfg:      Config loaded from NVS — device_type: 1gang_switch
I (890)  DSGV_WiFi:     Connected to MyHomeNetwork — IP: 192.168.1.42
I (1203) DSGV_Firebase: Broker config updated: mqtt.yourdomain.com:8883 (TLS=1)
I (1205) DSGV_MDNS:     mDNS started — hostname: dsgv-AABBCCDDEEFF
I (1206) DSGV_HTTP:     HTTP server started on port 80
I (1890) DSGV_MQTT:     Connected to mqtt.yourdomain.com:8883
I (1892) DSGV_MQTT:     Announced — devices/AABBCCDDEEFF/announce
I (1895) DSGV_MQTT:     Telemetry timer started (30 s interval)
```

Every module initialises in order. If a step hangs for more than 30 seconds or produces an error, that is where to look.

**Guru Meditation Error:**

```
Guru Meditation Error: Core 0 panic'ed (LoadProhibited). Exception was unhandled.
```

This means the firmware crashed. The most common causes:
- **LoadProhibited** — the code tried to read from a NULL pointer. Usually means a config struct was not loaded before a module tried to use it. Ensure `dsgv_device_config_load()` is called before any other module starts.
- **StoreProhibited** — a write to an invalid memory address. Often a buffer overflow or an uninitialised pointer.
- **Watchdog timeout** — a task stopped responding. Often caused by a GPIO conflict or an infinite loop in an ISR.

After any crash, the monitor prints a stack trace. The most useful line starts with `0x4...` — you can decode it with `idf.py -C devices/1gang_switch addr2line 0x4...` to get the exact source file and line number.

---

## Part 3 — Mobile App Setup

### Step 1 — Install Flutter SDK

Follow the official installation guide for your platform at [flutter.dev/docs/get-started/install](https://flutter.dev/docs/get-started/install).

After installing, run the Flutter doctor to check that everything is configured correctly:

```bash
flutter doctor
```

Expected output (abbreviated — green checkmarks for the items you need):
```
Doctor summary (to see all details, run flutter doctor -v):
[✓] Flutter (Channel stable, 3.x.x)
[✓] Android toolchain - develop for Android devices (Android SDK version 35.x.x)
[✓] Android Studio (version 2024.x)
[✓] VS Code (version 1.x.x)
[✓] Connected devices (1 available)
[✓] Network resources
```

You need at minimum: Flutter itself and the Android toolchain (or Xcode for iOS). If you see warnings about missing components, follow the suggested fix commands — `flutter doctor` usually tells you exactly what to install.

### Step 2 — Connect your Android phone

1. On your Android phone, go to **Settings → About phone**.
2. Find **Build number** and tap it **7 times** rapidly. You will see a countdown: "You are 3 steps away from being a developer", then "You are now a developer!".
3. Go back to **Settings → System → Developer options** (the exact location varies by manufacturer — some put it directly in Settings).
4. Enable **USB debugging**.
5. Connect your phone to your computer with a USB cable.
6. A dialog appears on the phone asking "Allow USB debugging?". Tap **Allow**.

Verify the phone is detected:

```bash
flutter devices
```

Expected output:
```
Found 2 connected devices:
  Pixel 8 (mobile) • RFCR40XXXXX • android-arm64 • Android 14 (API 34)
  Chrome (web)     • chrome      • web-javascript • Google Chrome 125.x
```

Your phone's name and ID will differ. The `android-arm64` entry is what you want.

### Step 3 — Install app dependencies

```bash
cd dsgv_hub_app
flutter pub get
```

Expected output:
```
Resolving dependencies...
  Got dependencies!
```

This downloads all the Dart packages listed in `pubspec.yaml`: MQTT client, BLE, mDNS, QR scanner, ObjectBox local database, Riverpod state management, and more.

### Step 4 — Confirm firebase_config_service.dart is updated

Open `dsgv_hub_app/lib/domain/services/firebase_config_service.dart` and check line 11. It should already show your project ID from Part 1 Step 4:

```dart
const _kFunctionsBase =
    'https://us-central1-dsgv-hub-a1b2c.cloudfunctions.net';
```

If it still says `YOUR_PROJECT_ID`, update it now.

### Step 5 — Run the app

With your phone connected and USB debugging enabled:

```bash
flutter run
```

Flutter compiles the app and installs it on your phone. This takes about 2 minutes the first time. On subsequent runs, it uses hot reload and takes about 10 seconds.

Expected output (last few lines):
```
Syncing files to device Pixel 8...
Flutter run key commands.
r Hot reload.
R Hot restart.
h List all available interactive commands.
d Detach (terminate "flutter run" but leave app running).
c Clear the screen.
q Quit (terminate the app and "flutter run").
Running with sound null safety
```

The app appears on your phone.

### Step 6 — What you see on first launch

The app opens to the **Dashboard** tab. It shows an empty list with a message indicating no devices are provisioned yet. This is normal.

Tap the **Settings** tab (bottom right). You will see the MQTT connection status as **Disconnected**. This is also normal — the app cannot connect to the broker until you configure your broker credentials.

In the Settings tab, you can:
- Toggle **Use custom broker** and enter your broker's hostname, port, and credentials, then tap **Save & Connect**.
- The status should change to **Connected** within a few seconds if the credentials are correct.

> **Tip:** If you do not have a broker yet, you can still provision devices and they will connect to whatever broker is configured in Firebase. The app's real-time controls require an MQTT connection, but the provisioning flow itself uses Bluetooth and does not need MQTT.

---

## Part 4 — Provisioning Your First Device

Provisioning is the process of securely introducing a new device to the platform. You tell the device your WiFi credentials and its device type over Bluetooth, and the platform registers it in Firebase.

### Step 1 — Find the device's MAC address and generate the QR code

When the firmware first boots (before any WiFi credentials are stored), it prints its MAC address on the serial monitor:

```
I (315)  DSGV_Prov:  BLE advertising started — device name: DSGVHub_DDEEFF
```

The 6-character suffix (`DDEEFF` in this example) is the last 6 hex characters of the device's WiFi MAC address. The full MAC is 12 characters — the serial monitor will also print the full value as:

```
I (316)  DSGV_cfg:   Device ID: AABBCCDDEEFF
```

The QR code encodes the following string:
```
dsgv://provision?name=DSGVHub_DDEEFF
```

Replace `DDEEFF` with your device's last 6 MAC characters. Generate a QR code from this string using any online QR code generator (search "QR code generator" — qrcode-monkey.com and qr-code-generator.com are commonly used).

> **Tip:** You can print the QR code or display it on a second screen — the app's QR scanner works from either.

### Step 2 — Open the provisioning screen in the app

In the DSGV Hub app, tap the **Add Device** tab (the middle tab with a plus icon). Tap **Scan QR Code**.

The app requests camera and Bluetooth permissions if it has not already. Grant both — camera is needed to read the QR code, and Bluetooth is needed to send WiFi credentials to the device.

### Step 3 — Scan the QR code

Point your phone's camera at the QR code you generated. The app reads the QR code and decodes the device name. A provisioning form appears.

### Step 4 — Fill in the provisioning form

| Field | What to enter |
|---|---|
| **Device name** | A friendly label, e.g. "Kitchen Switch" |
| **Device type** | Select from the dropdown: 1-Gang Switch, 2-Gang Switch, Dimmer, RGB Light, etc. This must match the firmware you flashed in Part 2. |
| **WiFi SSID** | Your home WiFi network name |
| **WiFi password** | Your home WiFi password |

> **Warning:** Enter your WiFi credentials carefully. The device stores them in its internal flash and uses them to connect to your home network. If the credentials are wrong, the device will sit in a reboot loop trying to connect. You will need to factory reset it (Part 5) and reprovision.

### Step 5 — Tap "Provision Device"

The app connects to the device over Bluetooth and sends the credentials. A progress indicator shows for 10–15 seconds.

During those seconds, here is what happens at each stage:

1. **App connects to device via BLE** — the app scans for the Bluetooth advertisement (`DSGVHub_DDEEFF`), connects to the GATT service, and writes a JSON payload containing the WiFi SSID, password, device type, capabilities, and an auth token to the credential characteristic.

2. **Device saves credentials to NVS** — the firmware receives the JSON, validates it, and writes each field to its internal flash storage (NVS). The auth token is a random 32-byte hex string generated by the app — it acts like a password that proves the app provisioned this device.

3. **Device reboots** — the firmware restarts into normal operating mode now that it has WiFi credentials.

4. **Device connects to WiFi** — using the SSID and password just saved.

5. **Device fetches broker config from Firebase** — calls the `getDeviceConfig` Cloud Function over HTTPS. At this point the device is not yet registered, so Firebase returns the factory broker config.

6. **Device starts MQTT, mDNS, and HTTP** — connects to the broker, advertises on the local network, and starts the HTTP API.

7. **Device publishes announce message** — publishes a JSON message to `devices/AABBCCDDEEFF/announce` containing its device ID, capabilities, firmware version, and local IP address.

8. **App receives the announce** — the app subscribed to this topic and receives the message.

9. **App registers the device in Firebase** — calls the `registerDevice` Cloud Function with the device ID and auth token. Firebase stores these in `device_registry/{MAC}` and seeds a factory broker config in `device_configs/{MAC}`.

10. **Device appears on the dashboard** — the app saves the device to its local ObjectBox database and navigates to the Dashboard tab.

**What just happened?** In plain terms: you proved to the platform that you physically have the device (by scanning the QR code that only someone in the same room could see) and that you know the home WiFi password. The platform accepted those proofs and gave the device its own authenticated identity. From now on, the device authenticates to Firebase using the auth token — no username or password stored in firmware.

### Step 6 — Check the Dashboard

Tap the **Dashboard** tab. Your device should appear as a card within 30 seconds. If it does not:

- Check the serial monitor. Look for `DSGV_MQTT: Connected` and `DSGV_MQTT: Announced`. If MQTT is not connected, the device cannot report to the app over MQTT.
- Check that the app's Settings tab shows "Connected" to the MQTT broker.

### Step 7 — Control the device

Tap the device card on the Dashboard to expand it. You will see controls appropriate to the device type — a toggle for a switch, a slider for a dimmer, color pickers for RGB lights.

Tap the toggle. The relay should click. In the serial monitor you will see:

```
I (45231) DSGV_MQTT:  Command received: {"relay":true}
I (45232) DSGV_GPIO:  Relay 0 → ON
I (45233) DSGV_MQTT:  Telemetry published
```

---

## Part 5 — Day-to-Day Usage

### Changing the MQTT broker

If you switch to a different MQTT broker (or are setting up a broker for the first time):

1. In the app, go to the **Settings** tab.
2. Toggle **Use custom broker** on.
3. Enter your broker's hostname, port (typically 8883 for TLS or 1883 for plain), username, and password.
4. Tap **Save & Connect**.
5. The status indicator should change to **Connected**.

To push the new broker configuration to all your devices so they reconnect on their next boot:

1. In Settings, tap **Push broker to all devices**.
2. The app calls `updateDeviceConfig` in Firebase for each registered device.
3. On their next reboot, devices will fetch the new broker from Firebase instead of using the NVS-cached value.

To restore the factory broker for all devices:

1. In Settings, tap the **↩ Manufacturer** button.
2. This calls `revertDeviceToFactory` in Firebase, resetting each device's config to the `MQTT_CLOUD_HOST` value in `dsgv_config.h`.

### Changing a device name

1. Tap the device card on the Dashboard to expand it.
2. Tap the pencil icon next to the device name.
3. Enter the new name and save.

The name is stored in the app's local database. It does not affect how the device identifies itself on MQTT (which uses the MAC address).

### OTA firmware update

Over-the-air updates let you push new firmware to devices without physically connecting them.

1. In Settings, select a device from the list.
2. Tap **Check for update**.
3. If a newer firmware version is available, tap **Update**.
4. The device downloads the new firmware over HTTPS, verifies its SHA-256 checksum, writes it to the inactive OTA partition, and reboots into it.

The serial monitor during an OTA update looks like:
```
I (12000) DSGV_OTA:   Starting OTA update from https://...
I (12500) DSGV_OTA:   Written 65536 / 1264400 bytes (5%)
...
I (35000) DSGV_OTA:   Written 1264400 / 1264400 bytes (100%)
I (35100) DSGV_OTA:   SHA-256 verification passed
I (35110) DSGV_OTA:   Rebooting into new firmware...
```

The old firmware is preserved in the other OTA partition. If the new firmware crashes before confirming a successful boot, the bootloader automatically falls back to the previous version. You cannot permanently brick a device with a bad OTA update.

### Factory resetting a device

**Physical reset (recommended for re-provisioning):**

Hold the **BOOT** button (labelled BOOT or GPIO0 on the board) for 5 seconds. The status LED flashes rapidly, then the device clears its WiFi credentials, auth token, and broker config from NVS, and restarts into BLE provisioning mode.

**Remove from app:**

Tap the device card → overflow menu (three dots) → **Remove device**. This removes the device from the app's local database and from Firebase's `user_devices` record. It does **not** reset the hardware — the device keeps its credentials and will reconnect to the broker. To fully decommission a device, do the physical reset as well.

---

## Part 6 — Voice Control Setup

### Google Home

Voice control through Google Home requires a Smart Home Action in the Google Cloud Console and account linking via the OAuth server you deployed in Part 1.

> **Pre-requisite:** Firebase Functions must be deployed (Part 1 Step 7) and OAuth secrets must be set (Part 1 Step 8). Complete both before starting this section.

**Step 1 — Create a Smart Home project in Google Cloud Console**

1. Go to [console.actions.google.com](https://console.actions.google.com) and sign in.
2. Click **New project**.
3. Select your Firebase project from the dropdown (it will appear because it is linked to the same Google account).
4. Choose **Smart Home** as the project type.

**Step 2 — Set the fulfillment URL**

1. In your Actions project, go to **Develop → Actions → Smart Home**.
2. Set the **Fulfillment URL** to:
   ```
   https://us-central1-dsgv-hub-a1b2c.cloudfunctions.net/googleSmartHome
   ```
   Replace `dsgv-hub-a1b2c` with your project ID.

**Step 3 — Configure account linking**

1. In your Actions project, go to **Develop → Account linking**.
2. Set the following values:

| Field | Value |
|---|---|
| **Client ID** | Your `oauth.google_client_id` value |
| **Client secret** | Your `oauth.google_client_secret` value |
| **Authorization URL** | `https://us-central1-dsgv-hub-a1b2c.cloudfunctions.net/oauthLoginPage` |
| **Token URL** | `https://us-central1-dsgv-hub-a1b2c.cloudfunctions.net/oauthToken` |
| **Scopes** | `dsgv.devices.control` |

> **Tip:** The `oauth.google_client_id` and `oauth.google_client_secret` are values you choose — they are not issued by Google. Create them as strong random strings. The same values must be in both the Actions Console and your Firebase Functions config (set in Part 1 Step 8).

**Step 4 — Link your account in Google Home**

1. Open the **Google Home** app on your phone.
2. Tap the **+** icon → **Set up device** → **Works with Google**.
3. Search for **DSGV** and tap your action.
4. A browser opens showing the DSGV login page. Enter the email and password for the Firebase Auth user you created in Part 1 Step 6.
5. Tap **Sign In & Link**.

**Step 5 — Sync devices**

Say **"Hey Google, sync my devices"** or tap the sync button in Google Home. Your provisioned devices should appear.

**Step 6 — How it works**

When you say "Hey Google, turn on the kitchen light", Google calls the `googleSmartHome` Cloud Function with an EXECUTE intent. The function reads which MQTT topics to publish to from Firebase, publishes the command, and responds to Google. When Google asks "Hey Google, is the kitchen light on?", the function reads the device's current state from `device_states/{MAC}` in the Realtime Database. That state must be kept current — see the MQTT State Bridge section below.

---

### Amazon Alexa

**Step 1 — Create a Smart Home skill**

1. Go to [developer.amazon.com/alexa/console/ask](https://developer.amazon.com/alexa/console/ask) and sign in.
2. Click **Create Skill**.
3. Name it `DSGV`.
4. Choose **Smart Home** as the model.
5. Click **Create skill**.

**Step 2 — Set the default endpoint**

In the skill's configuration, set the **Default endpoint** to:
```
https://us-central1-dsgv-hub-a1b2c.cloudfunctions.net/alexaSmartHome
```

**Step 3 — Configure account linking**

1. In the skill sidebar, go to **Account Linking**.
2. Toggle **Do you allow users to create an account or link to an existing account with you?** to on.
3. Set the following:

| Field | Value |
|---|---|
| **Authorization URI** | `https://us-central1-dsgv-hub-a1b2c.cloudfunctions.net/oauthLoginPage` |
| **Access Token URI** | `https://us-central1-dsgv-hub-a1b2c.cloudfunctions.net/oauthToken` |
| **Client ID** | Your `oauth.alexa_client_id` value |
| **Client Secret** | Your `oauth.alexa_client_secret` value |
| **Client Authentication Scheme** | HTTP Basic (recommended) |
| **Scope** | `dsgv.devices.control` |
| **Allowed Return URLs** | Alexa provides these — add `https://pitangui.amazon.com/api/skill/link/...` (the exact URL appears in the skill's Account Linking page) |

**Step 4 — Enable the skill and discover devices**

1. Open the **Amazon Alexa** app on your phone.
2. Go to **Skills & Games → Your Skills → Dev**.
3. Find your DSGV skill and tap **Enable to use**.
4. Sign in with your Firebase Auth credentials when prompted.
5. Say **"Alexa, discover devices"** or tap Discover devices in the app.

Your provisioned DSGV devices will appear in Alexa.

---

### MQTT State Bridge (required for both Google Home and Alexa)

Google Home and Alexa do not talk to your MQTT broker directly. When they ask "is the kitchen light on?", they read from `device_states/{MAC}` in Firebase. That node must be kept up to date.

You have two options:

---

**Option A — EMQX Rule Engine (if you are using EMQX as your broker)**

This is the simpler option if you use EMQX, because the rule engine forwards messages without a separate process running.

1. Open the EMQX Dashboard (typically at `http://your-broker:18083`).
2. Go to **Rules → Create Rule**.
3. For telemetry, create a rule with:
   - **SQL:** `SELECT * FROM "devices/+/telemetry"`
   - **Action:** HTTP POST to `https://us-central1-dsgv-hub-a1b2c.cloudfunctions.net/updateDeviceState`
   - **Headers:** `X-Bridge-Secret: your_bridge_secret_value`
   - **Body template:**
     ```json
     {"mac": "${topic[1]}", "state": ${payload}}
     ```

4. Create a second rule for online/offline status:
   - **SQL:** `SELECT * FROM "devices/+/status"`
   - **Action:** HTTP POST to the same URL
   - **Body template:**
     ```json
     {"mac": "${topic[1]}", "online": "${payload}" == "online"}
     ```

The `your_bridge_secret_value` is the value you set for `bridge.secret` in Part 1 Step 8. Retrieve it with `firebase functions:config:get` if you need to check it.

---

**Option B — Standalone bridge process (works with any broker)**

The bridge is a Node.js process that subscribes to all device topics on your MQTT broker and writes state updates to Firebase.

```bash
cd dsgv_hub_app/functions/mqtt_bridge
npm install
```

Run the bridge:
```bash
MQTT_BROKER_URL=mqtts://mqtt.yourdomain.com:8883 \
MQTT_USERNAME=bridge_user \
MQTT_PASSWORD=your_bridge_password \
GOOGLE_APPLICATION_CREDENTIALS=/path/to/firebase-service-account.json \
node bridge.js
```

Expected output:
```
[Bridge] Connecting to MQTT broker: mqtts://mqtt.yourdomain.com:8883
[Bridge] Connected to MQTT broker.
[Bridge] Subscribed to devices/+/telemetry and devices/+/status
```

`GOOGLE_APPLICATION_CREDENTIALS` must point to a Firebase service account key JSON file. Download it from Firebase Console → Project Settings → Service Accounts → **Generate new private key**.

To run the bridge permanently as a system service, use the systemd unit file template in the comments at the bottom of `dsgv_hub_app/functions/mqtt_bridge/bridge.js`:

```bash
# Copy the unit file (template is in the bridge.js comments — copy it out)
sudo nano /etc/systemd/system/dsgv-bridge.service

# Create the environment file
sudo nano /opt/dsgv-bridge/.env

# Enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable dsgv-bridge
sudo systemctl start dsgv-bridge

# Tail the logs
sudo journalctl -u dsgv-bridge -f
```

---

## Part 7 — Troubleshooting

| Problem | Likely cause | Fix |
|---|---|---|
| Serial monitor shows `Guru Meditation Error: Core 0 panic'ed (LoadProhibited)` | NULL pointer — usually a config struct used before it was loaded | Ensure `dsgv_device_config_load()` is called before any other module initialises |
| Serial monitor shows `Guru Meditation Error: Core 0 panic'ed` with watchdog timeout | GPIO conflict or out-of-memory — a task stopped responding | Check `dsgv_config.h` for duplicate GPIO numbers across relay, PWM, and sensor pins. See `FLASHING_GUIDE.md` for the correct pin map for your chip |
| Device keeps rebooting every few seconds | WiFi credentials wrong, GPIO conflict, or watchdog timeout | Check serial output before the crash for the last tag logged; check `FLASHING_GUIDE.md` pin map |
| Firebase fetch fails on every boot (`DSGV_Firebase: fetch failed`) | Wrong `FIREBASE_GET_CONFIG_URL` — usually a typo in the project ID | Copy the exact URL from Firebase Console → Functions → `getDeviceConfig` → trigger URL |
| Device does not appear on dashboard after provisioning | BLE provisioning failed silently, or app did not register device in Firebase | Check serial monitor for `DSGV_Prov` logs. Try factory reset (hold BOOT for 5 s) and reprovision |
| App shows "Disconnected" in Settings tab | Broker hostname wrong or broker is offline | Verify the hostname in Settings matches your broker. Check `mqtt_config.dart` factory default matches the same broker |
| Build fails with `ERROR: component not found: nimble` | BLE (NimBLE) not enabled in ESP-IDF config | Run `idf.py -C devices/1gang_switch menuconfig` → Component config → Bluetooth → enable Bluetooth and NimBLE |
| Flash fails with `A fatal error occurred: Failed to connect to ESP32` | USB cable is charge-only, or USB driver not installed | Try a different USB cable; check Device Manager (Windows) or `ls /dev/ttyUSB*` (Linux) for the port; reinstall the CH340 or CP2102 driver |
| `make build-all` fails on one specific device | That device has a GPIO conflict or an incompatible sdkconfig option | Run `make DEVICE=<failing_device> TARGET=esp32c3 build` alone to see the full error without other devices' output |
| Google Home shows devices as offline | `device_states/{MAC}.online` is false in Firebase | The MQTT state bridge is not running or is not reaching the `updateDeviceState` function. Check bridge logs or EMQX rule actions |
| OAuth login page returns HTTP 500 | `oauth.firebase_web_api_key` not set in Firebase Functions config | Run the `firebase functions:config:set oauth.firebase_web_api_key="..."` command from Part 1 Step 8, then redeploy |
| App QR scanner opens but does not read the code | QR code is blurry or too small | Generate the QR code at a higher resolution; ensure the camera is focusing (tap the screen to focus) |
| `flutter run` fails with `SDK not found` | Flutter not on PATH, or Android SDK not configured | Run `flutter doctor` and follow the instructions for any items marked with `[✗]` |

---

## Reference — File Map

| File | What it configures |
|---|---|
| `dsgv_hub_app/.firebaserc` | Firebase project ID used by the Firebase CLI |
| `dsgv_hub_app/functions/index.js` | All 11 Cloud Functions; `FACTORY_CONFIG.broker_host` must match firmware |
| `dsgv_hub_app/functions/lib/oauth.js` | OAuth 2.0 server for Google Home and Alexa account linking |
| `dsgv_hub_app/functions/mqtt_bridge/bridge.js` | Standalone MQTT→Firebase state bridge; systemd unit template at bottom |
| `dsgv_hub_app/database.rules.json` | Firebase Realtime Database security rules |
| `dsgv_hub_app/lib/domain/services/firebase_config_service.dart` | Cloud Function base URL used by the Flutter app |
| `dsgv_hub_app/lib/domain/models/mqtt_config.dart` | Factory default MQTT broker for the app |
| `dsgv_firmware/components/dsgv_common/include/dsgv_config.h` | Firebase URL, factory MQTT broker, GPIO pin maps for all supported chips |
| `dsgv_firmware/Makefile` | Build system — wraps idf.py for all 11 device types |
| `dsgv_firmware/devices/<name>/sdkconfig.defaults` | Device-specific ESP-IDF config (relay count, capabilities) |

---

## Related Documents

- **`dsgv_firmware/README.md`** — Firmware architecture, component reference, all 11 device types, startup sequence, serial log tags, and how to add a new device type.
- **`FLASHING_GUIDE.md`** — Wiring diagrams and GPIO pin maps for all 11 device types on all supported chips.
- **`TESTING_GUIDE.md`** — How to test the firmware, app, and cloud functions systematically.
- **`dsgv_hub_app/FIREBASE_SETUP_GUIDE.md`** — Detailed Firebase Console walkthrough with screenshots.
