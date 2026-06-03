# Firebase Setup Guide — DSGV Hub

Complete step-by-step guide for integrating Firebase as the secure device
config gateway. Follow the parts in order.

---

## Architecture Overview

```
BLE Provision
  └─► App calls registerDevice()
        └─► Firebase: device_registry + device_configs (factory defaults)

App pushes broker change
  └─► App calls updateDeviceConfig()
        └─► Firebase: device_configs updated

Device boots
  └─► WiFi connects
  └─► dsgv_firebase_fetch_config() → HTTPS POST /getDeviceConfig
        └─► Cloud Function validates auth_token
        └─► Returns broker_host, port, tls, username, password
  └─► Saves to NVS
  └─► MQTT connects using NVS config

MQTT is used for telemetry and commands only — credentials never touch MQTT.
```

---

## Part 1 — Firebase Console (browser)

**Step 1.** Go to https://console.firebase.google.com

**Step 2.** Click **Add project** → enter a name (e.g. `dsgv-hub`) →
disable Google Analytics → click **Create project**.

**Step 3.** In the left sidebar: **Build → Realtime Database** →
**Create database** → choose a region close to your users →
select **Start in locked mode** → click **Enable**.

**Step 4.** Click the **gear icon** (top-left) → **Project Settings** →
**General** tab → copy your **Project ID** (looks like `dsgv-hub-a1b2c`).
You will need this in the next part.

---

## Part 2 — Update Your Project ID and Broker Hostname

Replace the placeholders in these three files before deploying anything.

### 2a. Project ID — 3 files

| File | What to change |
|------|----------------|
| `.firebaserc` line 3 | `"YOUR_FIREBASE_PROJECT_ID"` → your Project ID |
| `lib/domain/services/firebase_config_service.dart` line 10 | `YOUR_PROJECT_ID` in the URL string |
| `components/dsgv_common/include/dsgv_config.h` line 33 | `YOUR_PROJECT_ID` in the URL string |

### 2b. Factory broker hostname — 3 files

Replace `mqtt.dsgv.io` with your real production MQTT broker hostname.

| File | What to change |
|------|----------------|
| `lib/domain/models/mqtt_config.dart` line 10 | `factoryDefault.host` |
| `components/dsgv_common/include/dsgv_config.h` line 39 | `MQTT_CLOUD_HOST` |
| `functions/index.js` line 18 | `FACTORY_CONFIG.broker_host` |

> All three must be identical. A mismatch means "Restore factory broker"
> in the app and a firmware factory reset land on different brokers —
> the device disappears from the dashboard permanently.

---

## Part 3 — Firebase CLI and Deploy

### 3a. Install Firebase CLI (once per machine)

```bash
npm install -g firebase-tools
```

Verify:
```bash
firebase --version
```

### 3b. Log in

```bash
firebase login
```

A browser window will open. Sign in with the Google account that owns
the Firebase project.

### 3c. Install Cloud Function dependencies

```bash
cd c:\Users\Chijioke\Documents\IoT-Project\dsgv_hub_app\functions
npm install
cd ..
```

### 3d. Deploy database rules and Cloud Functions

From the Flutter project root (`dsgv_hub_app`):

```bash
firebase deploy
```

Expected output:
```
✔  functions[registerDevice]: Deployed
✔  functions[getDeviceConfig]: Deployed
✔  functions[updateDeviceConfig]: Deployed
✔  functions[revertDeviceToFactory]: Deployed
✔  database: Rules deployed
```

> If you only want to redeploy functions after a code change:
> `firebase deploy --only functions`
>
> If you only want to redeploy database rules:
> `firebase deploy --only database`

### 3e. Verify functions are live

In the Firebase Console: **Build → Functions**. You should see all four
functions listed with a green checkmark.

You can also test `getDeviceConfig` directly from a terminal:

```bash
curl -X POST \
  https://us-central1-YOUR_PROJECT_ID.cloudfunctions.net/getDeviceConfig \
  -H "Content-Type: application/json" \
  -d '{"device_id":"AABBCCDDEEFF","auth_token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}'
```

An unregistered device returns the factory config. A registered device
with a wrong token returns `{"error":"Unauthorized"}`.

---

## Part 4 — Firmware Changes (ESP-IDF)

### 4a. Add the new source file to CMakeLists.txt

Open `components/dsgv_common/CMakeLists.txt` and add the new file and
required components:

```cmake
idf_component_register(
    SRCS
        # ... your existing source files ...
        "firebase/dsgv_firebase.c"      # ← ADD THIS LINE
    INCLUDE_DIRS
        "include"
    REQUIRES
        # ... your existing requires ...
        esp_http_client                 # ← ADD
        mbedtls                         # ← ADD (for certificate bundle)
)
```

### 4b. Enable HTTPS support in sdkconfig

Add these two lines to the relevant device's `sdkconfig.defaults`
(or to the shared one if all devices share it):

```
CONFIG_ESP_HTTP_CLIENT_ENABLE_HTTPS=y
CONFIG_MBEDTLS_CERTIFICATE_BUNDLE=y
```

### 4c. Call the fetch in your boot sequence

In each device's `main.c`, include the header and call the fetch function
**after WiFi connects and before starting MQTT**:

```c
#include "dsgv_firebase.h"

// ...existing WiFi init code...

// After wifi_connect() returns ESP_OK:
ESP_LOGI(TAG, "Fetching broker config from Firebase...");
dsgv_firebase_fetch_config();
// On success: NVS is updated with the latest broker from Firebase.
// On failure: device silently uses its cached NVS config (or factory
// defaults on a fresh flash). Either way, MQTT connect proceeds normally.

// ...existing MQTT start code...
```

### 4d. Rebuild and flash

```bash
idf.py build flash monitor
```

Watch for these log lines on first boot:

```
I (xxxx) DSGV_Firebase: Broker config updated: mqtt.dsgv.io:8883 (TLS=1)
```

Or on failure (device will still boot using cached/default config):

```
W (xxxx) DSGV_Firebase: HTTPS request failed: ESP_ERR_... — using cached config
```

---

## Part 5 — End-to-End Verification

Work through these checks in order to confirm the full flow is working.

**Check 1 — Device registration**
1. Pair a device using the app (Add Device tab → scan QR → Provision)
2. Open Firebase Console → **Realtime Database**
3. You should see two new entries appear within a few seconds:
   - `/device_registry/AABBCCDDEEFF` — contains `auth_token`, `registered_at`
   - `/device_configs/AABBCCDDEEFF` — contains factory broker config

**Check 2 — Device fetches config on boot**
1. Power cycle (reboot) the provisioned device
2. Watch serial monitor — look for `DSGV_Firebase: Broker config updated`
3. Device should connect to MQTT normally after the fetch

**Check 3 — Push a custom broker from the app**
1. In the app: Settings → **Use custom broker** → enter a valid broker
2. Tap **Save & Connect**
3. Tap **Push broker to all devices**
4. Open Firebase Console → `device_configs/{device_id}` →
   `broker_host` should show your custom broker
5. Reboot the device — it should connect to the custom broker

**Check 4 — Restore factory broker**
1. In the app: Settings → **Device Broker Sync** → **Restore factory broker**
2. Confirm in Firebase → `device_configs/{device_id}` →
   `broker_host` resets to `mqtt.dsgv.io` (your real hostname)
   and `is_factory` is `true`
3. Reboot device — it reconnects to the factory broker

**Check 5 — Offline resilience**
1. Disable internet on the device (or point `FIREBASE_GET_CONFIG_URL`
   to an invalid URL temporarily)
2. Reboot device — it should still connect to MQTT using the last
   config cached in NVS
3. Re-enable internet and reboot — Firebase fetch succeeds again

---

## Firebase Realtime Database Structure (for reference)

```
{
  "device_registry": {
    "AABBCCDDEEFF": {
      "auth_token":    "ABC123...XYZ",   ← 32-char hex, hardware entropy
      "registered_at": 1717430400000,
      "last_seen":     1717430500000
    }
  },
  "device_configs": {
    "AABBCCDDEEFF": {
      "broker_host":     "mqtt.dsgv.io",
      "broker_port":     8883,
      "broker_tls":      true,
      "broker_username": "",
      "broker_password": "",
      "is_factory":      true,
      "updated_at":      1717430400000
    }
  }
}
```

`device_registry` is private — only Cloud Functions (Admin SDK) can
read it. `device_configs` is also locked (database rules: `false`).
No client can read or write either path directly.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `firebase deploy` fails with "project not found" | Wrong project ID in `.firebaserc` | Update `.firebaserc` with correct Project ID |
| Functions deploy but return 500 | Node dependency missing | Run `cd functions && npm install` then redeploy |
| Device log shows `HTTPS request failed: ESP_ERR_HTTP_CONNECT` | Wrong URL or WiFi not ready | Confirm `FIREBASE_GET_CONFIG_URL` has the correct project ID; ensure WiFi is fully connected before calling the fetch |
| Device log shows `HTTP 401 Unauthorized` | Auth token mismatch | Re-pair the device via BLE — the token in Firebase may be from a different firmware flash |
| `device_configs` not appearing in Firebase after provisioning | App cannot reach Cloud Functions | Check network connectivity on the phone; check Firebase Functions logs in the console |
| Broker change not picked up by device | Device not rebooted | `dsgv_firebase_fetch_config()` is called on boot — reboot or power cycle the device |

---

## Security Notes

- **`device_registry` is never exposed** to devices or the app directly.
  Only Cloud Functions (server-side Admin SDK) can read auth tokens.
- **Constant-time token comparison** is used in `index.js` (`safeEqual`)
  to prevent timing attacks.
- **No Firebase SDK is required** in the Flutter app — all calls use
  plain HTTPS via the `http` package already in `pubspec.yaml`.
- **No credentials ever travel over MQTT.** MQTT carries only telemetry,
  commands, and device announcements.
- Once in production, enable **Firebase App Check** in the Firebase
  Console to prevent unauthorized callers from hitting your Cloud
  Functions.
