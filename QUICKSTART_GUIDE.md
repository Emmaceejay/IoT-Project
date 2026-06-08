# DSGV Hub — Quick Reference

This file is a short index. The full step-by-step guides are listed below — open the
one that matches what you are trying to do.

---

## I am setting up for the first time

→ **[SETUP_GUIDE.md](./SETUP_GUIDE.md)**

Covers everything in order: Firebase → Firmware → App → Provisioning → Voice Control.
Start here if you are new to the platform.

---

## I need to wire and flash a specific device type

→ **[FLASHING_GUIDE.md](./FLASHING_GUIDE.md)**

GPIO pin maps, wiring diagrams, and per-SKU build commands for all 11 device types.

---

## I need to test something

→ **[TESTING_GUIDE.md](./TESTING_GUIDE.md)**

Flutter unit/widget tests, Cloud Function curl tests, firmware build tests, hardware
tests, Google Home / Alexa integration tests.

---

## I need to push a firmware update to my devices

→ **[OTA_GUIDE.md](./OTA_GUIDE.md)**

Complete step-by-step: build firmware → compute SHA-256 hash → host on Firebase Storage
→ bake URL and hash into the app build (`--dart-define`) → push from Settings.
Includes troubleshooting, version strategy, and serial-monitor verification.

---

## I am getting ready to ship to customers

→ **[PRE_PRODUCTION_GUIDE.md](./PRE_PRODUCTION_GUIDE.md)**

Production readiness checklist — NVS encryption, Firebase App Check, mTLS, OTA
signing, and everything else required before hardware leaves the building.

---

## I need a firmware reference (directory layout, log tags, key files)

→ **[dsgv_firmware/README.md](./dsgv_firmware/README.md)**

---

## I need a Firebase setup reference (console steps, rules, function URLs)

→ **[dsgv_hub_app/FIREBASE_SETUP_GUIDE.md](./dsgv_hub_app/FIREBASE_SETUP_GUIDE.md)**

---

## Common commands at a glance

```bash
# Build a device (run from dsgv_firmware/)
make DEVICE=1gang_switch TARGET=esp32c3 build

# Flash + open monitor (most common daily command)
make DEVICE=1gang_switch TARGET=esp32c3 PORT=/dev/ttyUSB0 fm

# Build all 11 device types (CI / release)
make TARGET=esp32c3 build-all

# Run Flutter app (run from dsgv_hub_app/)
flutter run

# Run all Flutter tests
flutter test

# Deploy Cloud Functions (run from dsgv_hub_app/)
firebase deploy --only functions

# Deploy database rules
firebase deploy --only database

# Deploy everything
firebase deploy

# Tail live Cloud Function logs
firebase functions:log --follow
```

---

## Three values you must update before anything works

| What | Where | Example |
|------|-------|---------|
| Firebase Project ID | `dsgv_hub_app/.firebaserc` line 3 | `dsgv-hub-a1b2c` |
| Firebase Function base URL | `dsgv_hub_app/lib/domain/services/firebase_config_service.dart` ~line 10 | `https://us-central1-dsgv-hub-a1b2c.cloudfunctions.net` |
| MQTT broker hostname | `dsgv_hub_app/lib/domain/models/mqtt_config.dart` ~line 10 and `dsgv_firmware/components/dsgv_common/include/dsgv_config.h` | `mqtt.yourdomain.com` |

All three must be updated **before** building the firmware or running the app.
See [SETUP_GUIDE.md Part 1 Step 4](./SETUP_GUIDE.md) for the exact lines to edit.
