# OTA Firmware Update Guide — DSGV Hub

**For: De Socko Global Ventures**
**Product: DSGV Hub IoT Platform**
**Version: 1.0**

This guide explains how Over-the-Air (OTA) firmware updates work in DSGV Hub and walks you through every step needed to push a new firmware version to your device fleet.

---

## Table of Contents

1. [What is OTA and how does it work?](#1-what-is-ota-and-how-does-it-work)
2. [The complete OTA workflow (step by step)](#2-the-complete-ota-workflow-step-by-step)
3. [How to test an OTA update](#3-how-to-test-an-ota-update)
4. [Version naming and release management](#4-version-naming-and-release-management)
5. [Custom firmware for developers](#5-custom-firmware-for-developers)
6. [Troubleshooting](#6-troubleshooting)
7. [Quick reference](#7-quick-reference)

---

## 1. What is OTA and how does it work?

**OTA** stands for "Over-the-Air." It means updating the software (firmware) running on your physical devices — switches, sensors, relays — without physically touching them or connecting any cables. The update travels wirelessly over your network.

### The plain-English flow

Here is what happens every time you do an OTA update, from start to finish:

1. **You write new firmware** and compile it on your development computer. This produces a single binary file — a `.bin` file — that contains all the code the device needs to run.

2. **You upload that `.bin` file to a server** (a cloud storage bucket or a web server). The file must be reachable over a public HTTPS URL, like `https://your-storage.com/firmware/v1.2.3.bin`.

3. **You compute a fingerprint of the file** — specifically, a SHA-256 hash. This is a 64-character string that uniquely identifies the exact contents of the binary. If even one byte of the file changes, the hash changes completely. This is how devices know they received exactly the right firmware and not a corrupted or tampered copy.

4. **You build a new version of the Flutter app** and bake the URL, the hash, and a human-readable version number directly into the app's binary at compile time. These values are never shown to end users and never typed in manually — they are invisible to the person using the app.

5. **You distribute the new APK** to your users (or push it through the Play Store).

6. **The user opens the app**, goes to **Settings → Firmware Update**, and taps **"Push update to all devices (N)"**. The app silently sends the URL and hash to every online device over MQTT. The user never sees a URL or a hash — they just tap a button.

7. **Each device receives the trigger**, checks that it is not already running that firmware, downloads the `.bin` file from the URL, verifies the SHA-256 hash locally, writes the new firmware to its spare flash partition, and reboots into the new version. The whole process takes about 30–90 seconds per device depending on binary size and Wi-Fi speed.

8. **If the hash does not match**, the device discards the downloaded binary and stays on its current firmware. Nothing breaks — the device just continues running as before.

> **Key insight:** The "button in the app" is just a trigger. The firmware is never transmitted through your phone. The device downloads the firmware directly from your hosting server. Your phone only delivers the message: "hey, go download this URL and verify this hash."

---

## 2. The complete OTA workflow (step by step)

Work through these steps in order for every firmware release.

---

### Step 1 — Build the new firmware binary

Open a terminal and navigate to the firmware directory:

```bash
cd /home/user/IoT-Project/dsgv_firmware
```

Build the firmware for your target hardware. Replace `1gang_switch` and `esp32c3` with your actual device type and target if different:

```bash
make DEVICE=1gang_switch TARGET=esp32c3 build
```

Wait for the build to complete. It will print something like:

```
Linking CXX executable dsgv_firmware.elf
esptool.py v4.x.x
Chip is ESP32-C3 ...
Binary file: dsgv_firmware/build/dsgv_firmware.bin
```

**The compiled binary is at:**

```
/home/user/IoT-Project/dsgv_firmware/build/dsgv_firmware.bin
```

Verify the file exists and has a reasonable size (typically 500 KB – 1.5 MB):

```bash
ls -lh /home/user/IoT-Project/dsgv_firmware/build/dsgv_firmware.bin
```

> **Do not proceed** if the build reports errors or the `.bin` file is missing.

---

### Step 2 — Compute the SHA-256 hash

You must compute the SHA-256 hash of the exact `.bin` file you will upload. If you re-upload or re-build, you must recompute the hash.

**Linux / macOS:**

```bash
sha256sum /home/user/IoT-Project/dsgv_firmware/build/dsgv_firmware.bin
```

Example output:

```
a3f8c2d1e9b047560fa82c3e6a1d4b9c2f7e0a5d8b3c6f1e4a7d0b2c5e8f1a4  dsgv_firmware.bin
```

The 64-character hex string before the filename is your hash. Copy it exactly — all lowercase, no spaces.

**Windows PowerShell:**

```powershell
Get-FileHash "dsgv_firmware\build\dsgv_firmware.bin" -Algorithm SHA256
```

Example output:

```
Algorithm  Hash                                                              Path
---------  ----                                                              ----
SHA256     A3F8C2D1E9B047560FA82C3E6A1D4B9C2F7E0A5D8B3C6F1E4A7D0B2C5E8F1A4  ...
```

> **Windows note:** PowerShell returns the hash in uppercase. Convert it to lowercase before using it, because the device's hash comparison is case-sensitive. You can do this in PowerShell:
>
> ```powershell
> (Get-FileHash "dsgv_firmware\build\dsgv_firmware.bin" -Algorithm SHA256).Hash.ToLower()
> ```

Save this hash string — you will paste it into the build command in Step 4.

---

### Step 3 — Host the firmware file

The `.bin` file must be accessible over a public HTTPS URL. Do not use HTTP — the device's `esp_https_ota` library will reject plain HTTP connections.

Three hosting options are described below. **Firebase Storage** is recommended because it is already used in this project and requires no additional accounts.

---

#### Option A: Firebase Storage (recommended — already in this project)

Firebase Storage is a free cloud file storage service. You already have a Firebase project set up for DSGV Hub.

**Step 3a — Open Firebase Console**

Go to [https://console.firebase.google.com](https://console.firebase.google.com) and select your DSGV Hub project.

**Step 3b — Navigate to Storage**

In the left sidebar, click **Build → Storage**. If you have not used Storage before, click **Get started** and accept the default security rules for now (you will tighten them later).

**Step 3c — Create a firmware folder**

Click the **"+"** (New folder) button and create a folder called `firmware`.

**Step 3d — Upload the binary**

1. Open the `firmware` folder.
2. Click **Upload file**.
3. Select `/home/user/IoT-Project/dsgv_firmware/build/dsgv_firmware.bin` from your computer.
4. Rename it before uploading to include the version number: `v1.2.3.bin` (replace `1.2.3` with your actual version). This is important — see [Version naming](#4-version-naming-and-release-management).

**Step 3e — Get the download URL**

1. Click on the uploaded file in Firebase Storage.
2. In the right panel, copy the **Download URL**. It looks like:
   ```
   https://firebasestorage.googleapis.com/v0/b/your-project.appspot.com/o/firmware%2Fv1.2.3.bin?alt=media&token=xxxxxxxx
   ```
3. Save this URL — you will paste it into the build command in Step 4.

> **Important:** Test the URL in a browser or with `curl` to confirm it works before building the app:
>
> ```bash
> curl -I "https://firebasestorage.googleapis.com/v0/b/your-project.appspot.com/o/firmware%2Fv1.2.3.bin?alt=media&token=xxxxxxxx"
> ```
>
> You should get `HTTP/2 200`. If you get 403 or 404, check the Storage rules or re-upload.

---

#### Option B: AWS S3

1. Create an S3 bucket in your AWS account (e.g., `dsgv-firmware`).
2. Upload `dsgv_firmware.bin` to the bucket, renaming it `v1.2.3.bin`.
3. Set the object's permissions to **public read** or generate a pre-signed URL.
4. The URL format will be: `https://dsgv-firmware.s3.amazonaws.com/firmware/v1.2.3.bin`

---

#### Option C: Self-hosted NGINX

If you run your own server with a TLS certificate:

```nginx
server {
    listen 443 ssl;
    server_name ota.yourdomain.com;

    ssl_certificate     /etc/letsencrypt/live/ota.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/ota.yourdomain.com/privkey.pem;

    root /var/www/firmware;
    location / {
        try_files $uri =404;
    }
}
```

Place `v1.2.3.bin` in `/var/www/firmware/`. The URL would be: `https://ota.yourdomain.com/v1.2.3.bin`

---

### Step 4 — Build the Flutter app with the OTA constants

Now you have three pieces of information:

| Constant | Example value |
|---|---|
| `OTA_FIRMWARE_URL` | `https://firebasestorage.googleapis.com/v0/b/your-project.appspot.com/o/firmware%2Fv1.2.3.bin?alt=media&token=xxxx` |
| `OTA_FIRMWARE_HASH` | `a3f8c2d1e9b047560fa82c3e6a1d4b9c2f7e0a5d8b3c6f1e4a7d0b2c5e8f1a4` |
| `OTA_FIRMWARE_VERSION` | `1.2.3` |

Navigate to the app directory and build:

```bash
cd /home/user/IoT-Project/dsgv_hub_app

flutter build apk --release \
  --dart-define=OTA_FIRMWARE_URL=https://firebasestorage.googleapis.com/v0/b/your-project.appspot.com/o/firmware%2Fv1.2.3.bin?alt=media&token=xxxx \
  --dart-define=OTA_FIRMWARE_HASH=a3f8c2d1e9b047560fa82c3e6a1d4b9c2f7e0a5d8b3c6f1e4a7d0b2c5e8f1a4 \
  --dart-define=OTA_FIRMWARE_VERSION=1.2.3
```

Replace each value with your actual URL, hash, and version number.

**What these flags do:** `--dart-define` bakes a compile-time constant into the app binary. The values are stored in `OtaOrchestratorService` in `dsgv_hub_app/lib/domain/services/ota_service.dart` and are never visible in the UI. If you omit any of these flags, the OTA button will be disabled (see [Troubleshooting](#6-troubleshooting)).

**The signed APK is at:**

```
/home/user/IoT-Project/dsgv_hub_app/build/app/outputs/flutter-apk/app-release.apk
```

> If you are building for the Play Store, use `flutter build appbundle --release` with the same `--dart-define` flags. The bundle is at `build/app/outputs/bundle/release/app-release.aab`.

---

### Step 5 — Install and use the app

**Distribute the APK** to your users via your normal method (direct sideload, Firebase App Distribution, Play Store, etc.).

Once the user has the new app installed:

1. Open **DSGV Hub**.
2. Make sure you are connected to your MQTT broker (the connection status badge at the top of Settings should be green and say "Connected").
3. Go to **Settings** (tap the settings icon in the navigation bar).
4. Scroll down to the **"Firmware Update"** section.
5. You will see a **"Manufacturer  v1.2.3"** badge card confirming the firmware version baked into this build.
6. Below the card, it shows how many online provisioned devices will receive the update (e.g., "3 online device(s) will receive this update.").
7. Tap **"Push update to all devices (3)"**.
8. A green confirmation snackbar will appear: *"Firmware update sent to 3 device(s). Devices will verify and reboot automatically."*

That is all the user does. The rest happens automatically on each device.

**Alternatively**, for a single device, go to that device's detail screen:

1. From the Dashboard, tap a device card to open **Device Detail**.
2. Scroll down to **"Firmware Update"**.
3. Tap **"Push Firmware Update"**.
4. A progress bar appears showing 0% → 100% as the device flashes. Once complete it shows "Update Complete!".

---

### Step 6 — What happens on the device

After the app sends the MQTT trigger, here is what each device does automatically:

1. **Receives the MQTT message** on the topic `devices/{deviceId}/ota-trigger`. The message contains the firmware URL and the expected SHA-256 hash.

2. **Initiates a download** — the device's `esp_https_ota` component opens an HTTPS connection to the URL and begins downloading the binary. The device reports download progress back to the app via `devices/{deviceId}/telemetry` as `{"ota_progress": 0}` through `{"ota_progress": 100}`.

3. **Verifies the hash** — after the download completes, the device computes the SHA-256 hash of what it received and compares it against the hash you provided. If they do not match, the device discards the download, logs an error, and continues running its current firmware unchanged.

4. **Writes to the passive partition** — the ESP32 has two firmware partitions ("active" and "passive"). The new firmware is written to the passive partition without touching the currently running firmware. This means the device keeps working normally during the flash process.

5. **Reboots** — once flashing is complete, the device reboots and the bootloader switches to the newly flashed partition. The device comes back online running the new firmware, typically within 5–15 seconds.

6. **Rollback safety** — if the new firmware fails to boot successfully, the ESP32 bootloader automatically rolls back to the previous version on the other partition. The device never bricks itself.

> **During the update:** Do not power off the device. Do not disconnect it from Wi-Fi. If you do, the device will either continue on the next reboot (if the download was incomplete) or roll back cleanly (if flashing was interrupted). Either way, it will not brick.

---

## 3. How to test an OTA update

After pushing an update, verify it worked using one of these methods:

### Method 1 — Serial monitor (most reliable)

Connect the device to your computer with a USB-C cable and open a serial monitor:

```bash
cd /home/user/IoT-Project/dsgv_firmware
idf.py -p /dev/ttyUSB0 monitor
```

Replace `/dev/ttyUSB0` with your actual port (use `ls /dev/tty*` on Linux/macOS, or Device Manager on Windows to find it). On Windows the port looks like `COM5`.

After you tap the update button in the app, watch the serial output. You should see:

```
I (12345) OTA: Received OTA trigger via MQTT
I (12346) OTA: Starting OTA update from: https://...
I (12347) esp_https_ota: Starting OTA...
I (15000) OTA: OTA progress: 25%
I (17000) OTA: OTA progress: 50%
I (19000) OTA: OTA progress: 75%
I (21000) OTA: OTA progress: 100%
I (21001) OTA: OTA successful! Rebooting...
I (21500) boot: Loading app partition...
I (22000) app_start: Starting app on cpu0
```

The lines `OTA successful! Rebooting...` confirm the flash succeeded.

### Method 2 — Check the version in Settings

If you incremented `OTA_FIRMWARE_VERSION` in the new build and the device reports its running firmware version via telemetry, you can verify the update by checking what the device reports after rebooting.

### Method 3 — Observe the reboot in the app

In the app's Dashboard, the device will briefly go **Offline** (grey dot) and then return **Online** (cyan dot) within about 10–15 seconds after the update completes. If the device returns online after the update, it flashed successfully and booted the new firmware.

---

## 4. Version naming and release management

Good version discipline prevents accidents and makes rollbacks easy.

### Naming convention

Use **semantic versioning**: `MAJOR.MINOR.PATCH`

- **MAJOR** — breaking change in how the device behaves or communicates
- **MINOR** — new feature added (e.g., new capability, new telemetry field)
- **PATCH** — bug fix or small improvement

Examples: `1.0.0`, `1.1.0`, `1.1.1`, `2.0.0`

### Naming firmware files

Always include the version in the filename before uploading. Never use a generic name like `firmware.bin`:

```
firmware/v1.0.0.bin   ← initial release
firmware/v1.1.0.bin   ← added new capability
firmware/v1.1.1.bin   ← patched a bug in v1.1.0
```

### Never overwrite a live URL

Once a firmware version is uploaded to a URL and shipped in an app release, **never replace that file** at that URL. Devices that have not yet completed their update may still be downloading it. Overwriting the file would cause a hash mismatch and those devices would reject the update.

Always upload to a new URL (new filename) for each release.

### Keep a changelog

Maintain a simple text file (e.g., `dsgv_firmware/CHANGELOG.md`) noting what changed in each version:

```
## v1.1.0 — 2026-06-01
- Added power monitoring telemetry (watts field)
- Fixed relay debounce timing

## v1.0.0 — 2026-05-01
- Initial production release
```

### Track which app version shipped which firmware

Because the firmware URL and hash are baked into the app at build time, every app version has exactly one firmware version embedded in it. Keep a mapping:

| App version | Firmware version | Firmware URL |
|---|---|---|
| 1.0.0 | 1.0.0 | `https://.../firmware/v1.0.0.bin` |
| 1.1.0 | 1.1.0 | `https://.../firmware/v1.1.0.bin` |

---

## 5. Custom firmware for developers

The **Custom firmware (advanced)** section in Settings is for developers who need to test a one-off firmware build without going through a full app release cycle.

### When to use it

- You built an experimental firmware and want to test it on a few devices without releasing a new app version to all users.
- You are debugging a device and need to push a special diagnostic build.
- You are iterating quickly on firmware and do not want to rebuild the app every time.

### How to use it

1. Build and upload your firmware as described in Steps 1–3 above.
2. Open the DSGV Hub app and go to **Settings → Firmware Update**.
3. At the bottom of the Firmware Update section, tap **"Custom firmware  (advanced)"** to expand the collapsed section.
4. Enter the **Firmware URL** (the HTTPS URL to your `.bin` file).
5. Enter the **SHA-256 Hash** (the 64-character lowercase hex string).
6. Tap **"Push custom firmware (N devices)"**.

The update is sent to all online provisioned devices. The device validates and flashes exactly the same way as a factory update.

### What custom firmware does NOT affect

- The **factory firmware badge** in the UI still shows the version baked into the app at build time — custom firmware does not change the version shown there.
- If a user taps "Push update to all devices" on the main button, it will push the factory firmware (not your custom one), potentially overwriting your test firmware.

### Use a private hosting URL for custom builds

For test builds, use a URL that is not publicly guessable (e.g., include a random token in the path). You do not want someone to discover your test firmware URL and inadvertently push it to their devices.

---

## 6. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Button says **"No firmware in this build"** and is greyed out | The app was built without `--dart-define=OTA_FIRMWARE_URL` and `--dart-define=OTA_FIRMWARE_HASH` | Rebuild the app with all three `--dart-define` flags as shown in Step 4 |
| Firmware badge shows **"Manufacturer"** but no version number | `OTA_FIRMWARE_VERSION` was not set at build time | Rebuild with `--dart-define=OTA_FIRMWARE_VERSION=x.x.x` |
| **Device did not update** — no activity after tapping the button | Device is offline, or MQTT trigger was not delivered | Check that the device shows Online (cyan dot) in the Dashboard. Check the MQTT broker connection status at the top of Settings. Open the serial monitor to see if the device received the trigger message. |
| **URL must be HTTPS** error in device serial log | Firmware URL starts with `http://` instead of `https://` | Re-upload to a server with TLS. Use the HTTPS URL. |
| **Hash mismatch** in device serial log: `OTA: Hash verification failed` | The hash you computed does not match the file on the server | The most common cause: you recomputed the hash after re-uploading the file, or the file was corrupted during upload. Delete and re-upload the file, recompute the hash, and rebuild the app. |
| Device keeps rebooting repeatedly after OTA | The new firmware crashes on boot | The bootloader will eventually roll back. Connect a serial monitor (`idf.py monitor`) immediately after the device reboots to see the panic/crash message. Fix the firmware bug and push a corrected version. |
| **Progress stuck at 0%** — progress bar never moves | The MQTT broker did not deliver the trigger to the device | Confirm the broker is connected (Settings status badge). Check `devices/{deviceId}/ota-trigger` in an MQTT client like MQTT Explorer to verify the message was published. Confirm the device is subscribed to that topic (check serial logs at boot). |
| **Progress bar reaches 100% in the app** but device did not reboot | The app's progress simulation finished but the device is taking longer or the real telemetry is not arriving | The app shows simulated progress while waiting for real telemetry from `devices/{id}/telemetry`. Wait a few more seconds and watch the serial monitor. If real OTA progress is arriving on the telemetry topic, it will override the simulation. |
| Device **went offline** and never came back online after OTA | OTA completed but the new firmware cannot connect to MQTT | Check the new firmware's MQTT configuration. Connect via serial monitor to see boot logs. |

---

## 7. Quick reference

### Commands

**Build firmware:**

```bash
cd /home/user/IoT-Project/dsgv_firmware
make DEVICE=1gang_switch TARGET=esp32c3 build
```

**Firmware binary location:**

```
/home/user/IoT-Project/dsgv_firmware/build/dsgv_firmware.bin
```

**Compute SHA-256 hash:**

```bash
# Linux / macOS
sha256sum /home/user/IoT-Project/dsgv_firmware/build/dsgv_firmware.bin

# Windows PowerShell
(Get-FileHash "dsgv_firmware\build\dsgv_firmware.bin" -Algorithm SHA256).Hash.ToLower()
```

**Build Flutter app with OTA constants:**

```bash
cd /home/user/IoT-Project/dsgv_hub_app

flutter build apk --release \
  --dart-define=OTA_FIRMWARE_URL=https://your-host.com/firmware/v1.2.3.bin \
  --dart-define=OTA_FIRMWARE_HASH=<64-char-sha256-hex> \
  --dart-define=OTA_FIRMWARE_VERSION=1.2.3
```

**APK output location:**

```
/home/user/IoT-Project/dsgv_hub_app/build/app/outputs/flutter-apk/app-release.apk
```

**Open serial monitor to watch OTA:**

```bash
cd /home/user/IoT-Project/dsgv_firmware
idf.py -p /dev/ttyUSB0 monitor
```

### Settings screen path

- Fleet update: **Settings → Firmware Update → "Push update to all devices (N)"**
- Per-device update: **Dashboard → [tap device] → Device Detail → Firmware Update → "Push Firmware Update"**
- Custom/developer firmware: **Settings → Firmware Update → "Custom firmware (advanced)" [expand] → enter URL + hash → "Push custom firmware"**

### Checklist for every OTA release

- [ ] New firmware compiled without errors
- [ ] `.bin` file size is reasonable (500 KB – 1.5 MB)
- [ ] SHA-256 hash computed from the exact file that will be uploaded
- [ ] Firmware uploaded to a new versioned URL (not overwriting an existing one)
- [ ] Download URL tested in a browser — returns 200 with the file
- [ ] Flutter app rebuilt with all three `--dart-define` values
- [ ] App built, installed, and tested on a real device before distribution
- [ ] OTA tested on one physical device via serial monitor before fleet rollout
- [ ] Version number added to `CHANGELOG.md`

---

*This guide is specific to the DSGV Hub platform. For ESP-IDF OTA documentation see [docs.espressif.com/projects/esp-idf/en/latest/esp32c3/api-reference/system/ota.html](https://docs.espressif.com/projects/esp-idf/en/latest/esp32c3/api-reference/system/ota.html). For Flutter `--dart-define` documentation see [docs.flutter.dev](https://docs.flutter.dev).*
