# APK Build Guide — DSGV Hub App

## Where to Find the APK

All APK files are generated inside the build output folder:

```
dsgv_hub_app\build\app\outputs\flutter-apk\
```

---

## Build Methods

### 1. Debug APK (fastest — for testing on a device)

```bash
flutter build apk --debug
```

**Output:**
```
build\app\outputs\flutter-apk\app-debug.apk
```

- Not optimized, includes debug symbols
- Can be installed directly on any Android device with "Unknown Sources" enabled
- Also generated automatically when you run `flutter run`

---

### 2. Release APK (for distribution)

```bash
flutter build apk --release
```

**Output:**
```
build\app\outputs\flutter-apk\app-release.apk
```

- Fully optimized and minified
- Requires a signing key for Play Store submission
- Smaller and faster than debug

---

### 3. Split APKs by CPU Architecture (smallest file size)

```bash
flutter build apk --split-per-abi
```

**Output (3 separate files):**
```
build\app\outputs\flutter-apk\app-arm64-v8a-release.apk   ← Most modern Android phones
build\app\outputs\flutter-apk\app-armeabi-v7a-release.apk ← Older 32-bit devices
build\app\outputs\flutter-apk\app-x86_64-release.apk      ← Emulators / x86 devices
```

- Pick the right one for your device (arm64-v8a covers 95%+ of modern phones)
- Each file is ~30–40% smaller than the universal APK

---

### 4. Universal APK (one file, all architectures)

```bash
flutter build apk --release
```

Same as method 2 — the default release build is already universal (works on all devices but is larger).

---

## Quick Reference Table

| Command | APK File | Use Case |
|---|---|---|
| `flutter run` | `app-debug.apk` | Auto-installs on connected device |
| `flutter build apk --debug` | `app-debug.apk` | Manual debug install |
| `flutter build apk --release` | `app-release.apk` | Share / sideload |
| `flutter build apk --split-per-abi` | `app-arm64-v8a-release.apk` (+ 2 others) | Smallest size per device |
| `flutter build appbundle` | `build\app\outputs\bundle\release\app-release.aab` | Google Play Store upload |

---

## How to Install the APK on Your Phone

1. Copy the `.apk` file to your phone (USB, Google Drive, WhatsApp, etc.)
2. On your phone: **Settings → Security → Install Unknown Apps** → enable for your file manager
3. Open the `.apk` file on your phone and tap **Install**

---

## Tip: Run from Project Root

All commands above must be run from inside the `dsgv_hub_app` folder:

```bash
cd "c:\Users\ojike\OneDrive\Documents\AI_projects\IoT-Project\dsgv_hub_app"
flutter build apk --release
```

---

## Building with OTA Firmware Update

Production APK builds that ship to customers must include the OTA firmware constants. Without them, the "Push update to all devices" button in Settings will be permanently disabled, and the Device Detail screen's "Push Firmware Update" button will also be disabled. This section explains exactly what to do.

### Why --dart-define is required

The DSGV Hub app never asks the user to type in a firmware URL or a hash. Instead, these values are compiled directly into the app binary at build time using Flutter's `--dart-define` flag. The `OtaOrchestratorService` class in `lib/domain/services/ota_service.dart` reads them as compile-time constants:

```dart
static const factoryUrl     = String.fromEnvironment('OTA_FIRMWARE_URL');
static const factoryHash    = String.fromEnvironment('OTA_FIRMWARE_HASH');
static const factoryVersion = String.fromEnvironment('OTA_FIRMWARE_VERSION', defaultValue: '');
```

If these flags are omitted at build time, all three constants are empty strings, `hasFactoryFirmware` returns `false`, and both OTA buttons are disabled. There is no way to enable them at runtime — a rebuild is required.

### What you need before building

Before running the build command you need three things:

1. **The firmware binary** — compiled with:
   ```bash
   cd /home/user/IoT-Project/dsgv_firmware
   make DEVICE=1gang_switch TARGET=esp32c3 build
   ```
   Output: `dsgv_firmware/build/dsgv_firmware.bin`

2. **The SHA-256 hash** of that exact binary:
   ```bash
   # Linux / macOS
   sha256sum dsgv_firmware/build/dsgv_firmware.bin

   # Windows PowerShell
   (Get-FileHash "dsgv_firmware\build\dsgv_firmware.bin" -Algorithm SHA256).Hash.ToLower()
   ```
   Copy the 64-character hex string exactly. If even one character is wrong, the device will reject the firmware.

3. **The HTTPS download URL** — upload the `.bin` file to Firebase Storage, AWS S3, or another HTTPS host and copy the resulting URL. The URL must start with `https://` — the device firmware rejects plain HTTP.

> Compute the hash from the exact file you will upload. If you upload a different file or re-upload, recompute the hash.

### The exact build command

```bash
cd /home/user/IoT-Project/dsgv_hub_app

flutter build apk --release \
  --dart-define=OTA_FIRMWARE_URL=https://firebasestorage.googleapis.com/v0/b/your-project.appspot.com/o/firmware%2Fv1.2.3.bin?alt=media&token=xxxx \
  --dart-define=OTA_FIRMWARE_HASH=a3f8c2d1e9b047560fa82c3e6a1d4b9c2f7e0a5d8b3c6f1e4a7d0b2c5e8f1a4 \
  --dart-define=OTA_FIRMWARE_VERSION=1.2.3
```

Replace each value with your actual URL, hash, and version number.

**Output:**
```
build\app\outputs\flutter-apk\app-release.apk
```

For the Play Store, use the same flags with `appbundle`:

```bash
flutter build appbundle --release \
  --dart-define=OTA_FIRMWARE_URL=https://... \
  --dart-define=OTA_FIRMWARE_HASH=<64-char-sha256-hex> \
  --dart-define=OTA_FIRMWARE_VERSION=1.2.3
```

### What happens if you forget --dart-define

| What you see | What it means |
|---|---|
| Settings → Firmware Update shows **"No firmware configured for this build."** | `OTA_FIRMWARE_URL` or `OTA_FIRMWARE_HASH` (or both) were not set |
| The **"Push update to all devices"** button shows text **"No firmware in this build"** and is greyed out | Same as above — `hasFactoryFirmware` is false |
| The **"Push Firmware Update"** button in Device Detail is greyed out | Same root cause |
| The Manufacturer badge shows **no version number** | `OTA_FIRMWARE_VERSION` was omitted (URL and HASH may still be set, so button may still work) |

The fix is always the same: rebuild the APK with all three `--dart-define` flags.

### Tip: Use a shell script to avoid typos

Typing the full command every release is error-prone. Create a build script at `dsgv_hub_app/build_release.sh`:

```bash
#!/usr/bin/env bash
# build_release.sh — run from inside dsgv_hub_app/
# Edit the three variables below before each release.

OTA_URL="https://firebasestorage.googleapis.com/v0/b/your-project.appspot.com/o/firmware%2Fv1.2.3.bin?alt=media&token=xxxx"
OTA_HASH="a3f8c2d1e9b047560fa82c3e6a1d4b9c2f7e0a5d8b3c6f1e4a7d0b2c5e8f1a4"
OTA_VERSION="1.2.3"

flutter build apk --release \
  --dart-define=OTA_FIRMWARE_URL="$OTA_URL" \
  --dart-define=OTA_FIRMWARE_HASH="$OTA_HASH" \
  --dart-define=OTA_FIRMWARE_VERSION="$OTA_VERSION"

echo ""
echo "APK ready: build/app/outputs/flutter-apk/app-release.apk"
```

Make it executable and run it:

```bash
chmod +x build_release.sh
./build_release.sh
```

This way you edit three clearly labelled variables at the top of the script instead of hunting through a long command for the right place to paste values.

> For the complete OTA workflow — including hosting options, hash verification, and testing with the serial monitor — see **OTA_GUIDE.md** at the project root.
