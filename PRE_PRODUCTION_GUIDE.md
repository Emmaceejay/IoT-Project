# DSGV Hub — Pre-Production Checklist & Hardening Guide

**For: De Socko Global Ventures**
**Product: DSGV Hub IoT Platform**
**Version: 1.0**

This document covers every step required to harden a development build into a shippable product. Work through each section in order before releasing the app or shipping devices to customers.

---

## Table of Contents

1. [Android App Signing (Release APK)](#1-android-app-signing-release-apk)
2. [Custom App Icon](#2-custom-app-icon)
3. [OTA Firmware Hosting & Build-Time URL Injection](#3-ota-firmware-hosting--build-time-url-injection)
4. [Firmware Security — Secure Boot & Flash Encryption](#4-firmware-security--secure-boot--flash-encryption)
5. [OTA Server TLS Certificate Pinning (Firmware)](#5-ota-server-tls-certificate-pinning-firmware)
6. [MQTT Production Broker Setup](#6-mqtt-production-broker-setup)
7. [Auth-Token Security Review](#7-auth-token-security-review)
8. [App Store / Play Store Metadata](#8-app-store--play-store-metadata)
9. [Final Pre-Ship Verification Checklist](#9-final-pre-ship-verification-checklist)

---

## 1. Android App Signing (Release APK)

Debug APKs are signed with a temporary debug key that is the same on every developer's machine. Release builds must use your own private keystore or they cannot be published to the Play Store.

### Step 1 — Generate a keystore (do this once, store it securely)

```bash
keytool -genkeypair -v \
  -keystore dsgv-release-key.jks \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -alias dsgv-key \
  -dname "CN=De Socko Global Ventures, OU=Mobile, O=DSGV, L=YourCity, ST=YourState, C=NG"
```

You will be prompted for a keystore password and key password. **Back up `dsgv-release-key.jks` and both passwords somewhere safe. If you lose the keystore, you can never update the app on the Play Store.**

### Step 2 — Store credentials outside the repo

Create `dsgv_hub_app/android/key.properties` (this file must NOT be committed to git):

```properties
storePassword=<your-keystore-password>
keyPassword=<your-key-password>
keyAlias=dsgv-key
storeFile=../../../../dsgv-release-key.jks
```

Add to `dsgv_hub_app/android/.gitignore` (create it if absent):

```
key.properties
*.jks
*.keystore
```

### Step 3 — Wire the keystore into Gradle

Edit `dsgv_hub_app/android/app/build.gradle.kts`. Replace the current `buildTypes` block with:

```kotlin
// ── Load signing config ──────────────────────────────────────────────────────
val keyPropsFile = rootProject.file("key.properties")
val keyProps = java.util.Properties()
if (keyPropsFile.exists()) { keyProps.load(keyPropsFile.inputStream()) }

android {
    // ... existing namespace / compileSdk / etc. ...

    signingConfigs {
        create("release") {
            keyAlias     = keyProps["keyAlias"]     as String? ?: ""
            keyPassword  = keyProps["keyPassword"]  as String? ?: ""
            storeFile    = keyProps["storeFile"]    ?.let { file(it) }
            storePassword= keyProps["storePassword"]as String? ?: ""
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}
```

### Step 4 — Build the signed APK

```bash
cd IoT-Project/dsgv_hub_app
flutter build apk --release
# or for Play Store:
flutter build appbundle --release
```

The signed output is at:
```
build/app/outputs/flutter-apk/app-release.apk
build/app/outputs/bundle/release/app-release.aab
```

---

## 2. Custom App Icon

The default Flutter blue icon must be replaced with the DSGV Hub brand icon before shipping.

### Step 1 — Prepare the icon image

- Create a **1024 × 1024 px** PNG of the DSGV Hub icon (no transparency for Android)
- Save it to `dsgv_hub_app/assets/app_icon.png`

### Step 2 — Add `flutter_launcher_icons` to pubspec

```yaml
# dsgv_hub_app/pubspec.yaml

dev_dependencies:
  flutter_launcher_icons: ^0.14.0

flutter_launcher_icons:
  android: true
  ios: true
  image_path: "assets/app_icon.png"
  adaptive_icon_background: "#0A0E1A"   # match the app's dark background
  adaptive_icon_foreground: "assets/app_icon.png"
  min_sdk_android: 21
```

### Step 3 — Generate icons

```bash
cd IoT-Project/dsgv_hub_app
dart run flutter_launcher_icons
```

This writes all the correctly-sized icon files into `android/app/src/main/res/mipmap-*/` and `ios/Runner/Assets.xcassets/`. Rebuild the app after.

---

## 3. OTA Firmware Hosting & Build-Time URL Injection

The app's OTA system is centralised in `dsgv_hub_app/lib/domain/services/ota_service.dart` inside the `OtaOrchestratorService` class. Three constants are baked into the binary at build time via `--dart-define` so neither the URL, the hash, nor the version string is ever visible in the app's UI or editable by end users.

| Constant | Purpose |
|---|---|
| `OTA_FIRMWARE_URL` | Full HTTPS URL to the `.bin` file on your CDN or server |
| `OTA_FIRMWARE_HASH` | SHA-256 hex digest of that exact `.bin` file (64 lowercase hex chars) |
| `OTA_FIRMWARE_VERSION` | Human-readable version string shown in the Settings badge (e.g. `1.2.3`) |

`OtaOrchestratorService.hasFactoryFirmware` returns `true` only when both `OTA_FIRMWARE_URL` and `OTA_FIRMWARE_HASH` are non-empty. In development builds where no `--dart-define` is supplied, the button is automatically disabled and a message explains this is a dev build. No runtime guard needs to be added manually.

### Where OTA controls appear in the UI

| Location | What it does |
|---|---|
| **Settings → Firmware Update → "Push update to all devices (N)"** | Sends the factory firmware trigger via MQTT to all online provisioned devices simultaneously. End users just tap this button — they never see a URL or hash. |
| **Device Detail → Firmware Update → "Push Firmware Update"** | Same factory constants, but targets a single device. Used for per-device updates or targeted testing. |
| **Settings → Firmware Update → "Custom firmware (advanced)"** (collapsed) | Developer-only section — accepts a manually entered URL and hash. Only online provisioned devices receive the update. |

> See **OTA_GUIDE.md** for the complete step-by-step walkthrough including Firebase Storage hosting, hash computation, and serial-monitor verification.

### Step 1 — Host the firmware binary

Upload the compiled `dsgv_firmware/build/dsgv_firmware.bin` to a storage service that supports HTTPS. Always use a version-tagged filename (e.g. `v1.2.3.bin`) and never overwrite an existing live URL — devices that have not yet completed their update may still be downloading it.

| Option | Notes |
|---|---|
| AWS S3 | Public read or pre-signed URL; standard choice for production |
| Cloudflare R2 | S3-compatible, free egress — good cost-efficient option |
| GitHub Releases | Free and public — only suitable for open-source firmware |
| Self-hosted NGINX/Caddy | Full control; requires a valid TLS certificate |

**The URL must be HTTPS.** The firmware's `esp_https_ota` component will refuse plain HTTP connections.

### Step 2 — Compute the SHA-256 hash

Compute the hash from the exact file you uploaded. If you re-upload or re-build, recompute.

```bash
# Linux / macOS
sha256sum dsgv_firmware/build/dsgv_firmware.bin

# Windows PowerShell — outputs lowercase hash directly
(Get-FileHash "dsgv_firmware\build\dsgv_firmware.bin" -Algorithm SHA256).Hash.ToLower()
```

The output is a 64-character lowercase hex string. Copy it exactly — the device's hash check is case-sensitive and rejects any mismatch.

### Step 3 — Pass all three constants at build time

```bash
flutter build apk --release \
  --dart-define=OTA_FIRMWARE_URL=https://your-bucket.s3.amazonaws.com/firmware/v1.2.3.bin \
  --dart-define=OTA_FIRMWARE_HASH=a3f8c2d1e9b047560fa82c3e6a1d4b9c2f7e0a5d8b3c6f1e4a7d0b2c5e8f1a4 \
  --dart-define=OTA_FIRMWARE_VERSION=1.2.3
```

All three values are read by `OtaOrchestratorService` in `ota_service.dart` using `String.fromEnvironment()`. Omitting `OTA_FIRMWARE_URL` or `OTA_FIRMWARE_HASH` sets `hasFactoryFirmware` to `false` and the "Push update" button remains disabled. Omitting `OTA_FIRMWARE_VERSION` simply leaves the version badge blank — the button still works.

### Step 4 — Firmware version and file naming strategy

Keep firmware binary filenames version-tagged (`firmware/v1.0.0.bin`, `v1.1.0.bin`, etc.). Never overwrite a live URL — old devices may still be downloading it. Maintain a `CHANGELOG.md` in the firmware directory and a mapping between app versions and the firmware version they embed.

---

## 4. Firmware Security — Secure Boot & Flash Encryption

Without these features, anyone who gains physical access to a device can extract the firmware binary, read NVS secrets (Wi-Fi credentials, MQTT passwords, auth token), or flash rogue firmware.

### Secure Boot v2

Secure Boot ensures the chip only runs firmware signed with your private key.

```bash
cd IoT-Project/dsgv_firmware

# Enable in sdkconfig:
# CONFIG_SECURE_BOOT=y
# CONFIG_SECURE_BOOT_V2_ENABLED=y
# CONFIG_SECURE_BOOT_SIGNING_KEY="secure_boot_signing_key.pem"

# Generate the signing key once (keep this key SECRET and backed up):
espsecure.py generate_signing_key --version 2 secure_boot_signing_key.pem

# Build with secure boot enabled:
idf.py build

# First flash — this burns the key digest to eFuses (irreversible):
idf.py -p COM5 flash
```

**Warning:** Once Secure Boot is enabled and the key is burned, you can only flash firmware signed with that exact key. If the key is lost, the device is permanently unflashable.

### Flash Encryption

Encrypts the firmware partition at rest. Enables via `sdkconfig`:

```
CONFIG_FLASH_ENCRYPTION_ENABLED=y
CONFIG_FLASH_ENCRYPTION_MODE_RELEASE=y
```

Use Development mode first (allows re-flashing for testing), then switch to Release mode for shipped units.

### Minimum security `sdkconfig.defaults` additions

```
CONFIG_SECURE_BOOT=y
CONFIG_SECURE_BOOT_V2_ENABLED=y
CONFIG_FLASH_ENCRYPTION_ENABLED=y
CONFIG_BOOTLOADER_LOG_LEVEL_NONE=y    # suppress boot logs in production
CONFIG_ESP_SYSTEM_PANIC_SILENT_REBOOT=y
```

---

## 5. OTA Server TLS Certificate Pinning (Firmware)

The current firmware comment in `dsgv_ota.c` reads:

```c
// .cert_pem = server_cert_pem_start,  // Pin S3/CDN cert for production
```

Uncomment and implement this before shipping. This prevents a man-in-the-middle attack from injecting rogue firmware over the OTA channel.

### Step 1 — Get the server certificate

```bash
# Download the PEM certificate for your OTA server:
openssl s_client -connect your-bucket.s3.amazonaws.com:443 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > server_cert.pem
```

### Step 2 — Embed it in the firmware

Place `server_cert.pem` in `dsgv_firmware/main/ota/`. Add to `CMakeLists.txt`:

```cmake
target_add_binary_data(dsgv_firmware.elf "main/ota/server_cert.pem" TEXT)
```

### Step 3 — Wire into `dsgv_ota.c`

```c
extern const uint8_t server_cert_pem_start[] asm("_binary_server_cert_pem_start");
extern const uint8_t server_cert_pem_end[]   asm("_binary_server_cert_pem_end");

// In esp_http_client_config_t:
.cert_pem = (const char *)server_cert_pem_start,
```

**Note:** If you use a CDN (CloudFront, Cloudflare), pin the CDN's certificate, not the origin bucket's. Certificates rotate periodically — when the CDN rotates its cert, you must ship a firmware update that pins the new certificate before the old one expires.

---

## 6. MQTT Production Broker Setup

The default config in `dsgv_config.h` uses public broker endpoints suitable for development. Replace with your own broker for production.

### Recommended brokers

| Broker | Type | TLS | Notes |
|---|---|---|---|
| EMQX Cloud | Managed | Yes | Free tier, 1M minutes/month |
| HiveMQ Cloud | Managed | Yes | Free tier, 100 connections |
| AWS IoT Core | Managed | Yes | Per-message pricing, scales to millions |
| Self-hosted Mosquitto | Self-hosted | With config | Full control, needs a VPS |

### Step 1 — Configure the firmware defaults

Edit `dsgv_firmware/include/dsgv_config.h`:

```c
#define MQTT_CLOUD_HOST     "your-broker.emqx.io"
#define MQTT_CLOUD_PORT     8883              // TLS
#define MQTT_CLOUD_USER     "your-username"
#define MQTT_CLOUD_PASS     "your-password"
#define MQTT_LOCAL_HOST     "192.168.1.100"   // your home/office Mosquitto IP
#define MQTT_LOCAL_PORT     1883
```

### Step 2 — Configure the app defaults

Edit `dsgv_hub_app/lib/domain/models/mqtt_config.dart` to set your production broker as the default. Users can still override in Settings.

### Step 3 — Enable TLS in the firmware MQTT client

In `dsgv_firmware/main/mqtt/dsgv_mqtt.c`, ensure the cloud broker config has:

```c
.transport = MQTT_TRANSPORT_OVER_SSL,
.port      = 8883,
.cert_pem  = (const char *)mqtt_broker_cert_pem_start,  // pin your broker's CA cert
```

Embed the broker CA certificate the same way as the OTA server cert (see Section 5).

### Step 4 — Set up access control (ACL) on the broker

Every device should only have permission to publish/subscribe to its own topic subtree:

```
# Mosquitto ACL example
user dsgv-device-{device_id}
topic readwrite devices/{device_id}/#
```

---

## 7. Auth-Token Security Review

The auth-token mechanism protects the `devices/{id}/config` topic from unauthorized broker-change commands. Review these points before shipping:

| Check | Status | Notes |
|---|---|---|
| Token generated from hardware RNG | ✅ | `esp_fill_random()` in `dsgv_provisioning.c` |
| Token exchanged only over BLE | ✅ | Never published over MQTT |
| Token validated with `memcmp()` timing-safe | ✅ | Constant-time comparison in `dsgv_mqtt.c` |
| Token stored in NVS with namespace `dsgv_cfg` | ✅ | Isolated from Wi-Fi and MQTT credentials |
| BLE pairing requires physical proximity | ✅ | User must be in Bluetooth range |
| Rollback timer set to 60 seconds | ✅ | Reverts broker if new broker is unreachable |
| **Action required:** Enable Flash Encryption | ❌ | Prevents NVS token extraction via JTAG/UART |

---

## 8. App Store / Play Store Metadata

Before publishing to the Google Play Store:

### Application ID

Current: `com.dsgv.hub`
This is the permanent identifier. **It cannot be changed after first publish.**

### Version numbers

In `dsgv_hub_app/pubspec.yaml`:

```yaml
version: 1.0.0+1
#        ^^^^^  ^
#        versionName (shown to users)
#                ^ versionCode (integer, must increment on every upload)
```

### Play Store checklist

- [ ] High-res icon (512 × 512 px PNG)
- [ ] Feature graphic (1024 × 500 px)
- [ ] At least 2 screenshots per form factor
- [ ] Short description (80 chars)
- [ ] Full description (4000 chars max)
- [ ] Privacy Policy URL (required for apps that use Bluetooth / location)
- [ ] Content rating questionnaire completed
- [ ] Target audience: 18+ (IoT / professional tool)

### Required Android permissions declared

`android/app/src/main/AndroidManifest.xml` should already include:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
```

BLE scanning on Android 12+ (`BLUETOOTH_SCAN`) also requires `neverForLocation="true"` if you are not deriving location from BLE — add this if applicable to reduce permission scope.

---

## 9. Final Pre-Ship Verification Checklist

Run through every item in this section before approving a device batch for shipping or submitting the app to the Play Store.

### Firmware

- [ ] `idf.py build` completes with zero warnings (treat all warnings as errors for production)
- [ ] Device boots and BLE advertises as `DSGVHub_XXXXXX`
- [ ] MQTT cloud broker TLS connection confirmed (check serial monitor for `MQTT connected`)
- [ ] MQTT fallback to local broker works (disable cloud connectivity and confirm reconnect)
- [ ] All relay/sensor GPIO pins tested with hardware
- [ ] OTA update tested end-to-end: push new firmware from the app, confirm progress reaches 100%, device reboots to new firmware
- [ ] Factory reset (5-second BOOT button hold) clears NVS and re-enters provisioning mode
- [ ] Secure Boot and Flash Encryption enabled on production units
- [ ] OTA server TLS certificate pinned

### Mobile App

- [ ] `flutter analyze` returns zero issues
- [ ] Release APK signed with production keystore (not debug key)
- [ ] `OTA_FIRMWARE_URL`, `OTA_FIRMWARE_HASH`, and `OTA_FIRMWARE_VERSION` injected via `--dart-define` at build time
- [ ] BLE provisioning tested on a fresh device (no prior NVS data)
- [ ] All 11 device presets verified in the UI
- [ ] Dashboard, device detail, settings, and pairing screens tested on Android 10, 12, 14
- [ ] MQTT reconnect works after app backgrounding and screen lock
- [ ] Custom app icon visible on home screen (not the Flutter default)

### Protocol Sync

- [ ] BLE device name prefix: firmware `DSGVHub_` matches app `_kDeviceNamePrefix = 'DSGVHub_'`
- [ ] QR URI scheme: firmware `dsgv://provision` matches app parser
- [ ] MQTT topic patterns identical in `dsgv_mqtt.c` and `mqtt_service.dart`
- [ ] MQTT announce JSON fields match `MatterDevice.fromJson()` field names
- [ ] Telemetry field names match `schema_driven_ui_builder.dart` capability cases
- [ ] OTA progress field `ota_progress` matches `OtaService.watchUpdate()` parser

### Security

- [ ] No hardcoded credentials in any source file or commit history
- [ ] `key.properties` and `*.jks` excluded from git (`.gitignore`)
- [ ] `secure_boot_signing_key.pem` NOT in the repository — stored in a password manager / HSM
- [ ] MQTT broker requires username + password (no anonymous access on production broker)
- [ ] MQTT TLS enabled on cloud broker port 8883

---

## Quick Reference: Production Build Commands

### App — Signed Release APK (with OTA)

```bash
cd IoT-Project/dsgv_hub_app

flutter build apk --release \
  --dart-define=OTA_FIRMWARE_URL=https://your-bucket.s3.amazonaws.com/firmware/v1.2.3.bin \
  --dart-define=OTA_FIRMWARE_HASH=<64-char-sha256-hex> \
  --dart-define=OTA_FIRMWARE_VERSION=1.2.3
```

### App — Play Store Bundle (with OTA)

```bash
flutter build appbundle --release \
  --dart-define=OTA_FIRMWARE_URL=https://your-bucket.s3.amazonaws.com/firmware/v1.2.3.bin \
  --dart-define=OTA_FIRMWARE_HASH=<64-char-sha256-hex> \
  --dart-define=OTA_FIRMWARE_VERSION=1.2.3
```

### Compute SHA-256 hash before building

```bash
# Linux / macOS
sha256sum dsgv_firmware/build/dsgv_firmware.bin

# Windows PowerShell
(Get-FileHash "dsgv_firmware\build\dsgv_firmware.bin" -Algorithm SHA256).Hash.ToLower()
```

### Firmware — Production Build & Flash

```bash
cd IoT-Project/dsgv_firmware

make DEVICE=1gang_switch TARGET=esp32c3 build   # produces dsgv_firmware/build/dsgv_firmware.bin
idf.py -p COM5 flash                             # replace COM5 with your port
idf.py -p COM5 monitor                           # verify boot logs
```

---

*This guide is specific to the DSGV Hub platform. For general ESP-IDF documentation see [docs.espressif.com](https://docs.espressif.com). For Flutter release documentation see [docs.flutter.dev/deployment/android](https://docs.flutter.dev/deployment/android).*
