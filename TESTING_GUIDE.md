# DSGV Hub — Testing Guide

This guide walks through every layer of the DSGV Hub platform: the Flutter mobile
app, the Firebase Cloud Functions, and the ESP32 firmware. Read it top to bottom
once, then use individual sections as a reference when you need to test a specific
layer.

---

## Overview — What to Test and When

The DSGV Hub platform has three independently testable layers. The Flutter app
contains automated unit and widget tests that run in milliseconds on your laptop
with no hardware needed. The Firebase Cloud Functions are tested manually with
`curl` after each deploy — there is no test runner for Cloud Functions in this
project, so disciplined manual testing is the quality gate. The ESP32 firmware has
two modes of testing: build tests (does the code compile cleanly for all 11 device
types?) and hardware tests (does the running firmware behave correctly on a real
chip?). Build tests run in CI; hardware tests need a physical board and a USB cable.

Run the Flutter automated tests every time you touch Dart code. Run the Cloud
Functions `curl` tests every time you deploy a change to `functions/index.js` or
`functions/lib/`. Run a firmware build test every time you touch C source code,
even if you only changed a comment — a clean compile is your first sanity check.
Run hardware tests when you change anything that affects boot sequence, WiFi,
MQTT, mDNS, OTA, or GPIO behaviour.

---

## Part A — Flutter App Tests (Automated)

The Flutter test suite lives entirely inside `dsgv_hub_app/test/`. Tests run on
your development machine using the Dart VM — no phone, no emulator, no Firebase
connection required. This is possible because every test that touches external
dependencies uses a stub (a fake object that returns canned data) instead of the
real implementation.

### A.1 Prerequisites

You need the Flutter SDK installed and `flutter doctor` showing no critical issues.
From the project root:

```bash
cd dsgv_hub_app
flutter pub get
```

Expected output (last few lines):

```
Got dependencies!
```

If you see `Because dsgv_hub_app depends on objectbox_generator...` warnings, that
is normal — code generation is only needed for the ObjectBox database model, not
for running tests.

### A.2 Run All Tests

**What this checks:** Every test file under `dsgv_hub_app/test/` is compiled and
executed. If any single test fails the whole run returns a non-zero exit code,
making it CI-friendly.

From inside the `dsgv_hub_app/` directory:

```bash
flutter test
```

Expected output when everything passes:

```
00:00 +0: loading /home/user/IoT-Project/dsgv_hub_app/test/unit/iot_device_test.dart
00:01 +11: loading /home/user/IoT-Project/dsgv_hub_app/test/unit/mqtt_config_test.dart
00:02 +24: loading /home/user/IoT-Project/dsgv_hub_app/test/unit/ota_state_test.dart
00:03 +29: loading /home/user/IoT-Project/dsgv_hub_app/test/widget/device_card_test.dart
00:04 +37: loading /home/user/IoT-Project/dsgv_hub_app/test/widget/schema_driven_ui_builder_test.dart
00:05 +45: loading /home/user/IoT-Project/dsgv_hub_app/test/widget_test.dart
00:06 +46: All tests passed!
```

The numbers after `+` are cumulative passing tests. The exact count may change as
you add tests — what matters is the final `All tests passed!` line.

### A.3 Run a Single Test File

Sometimes you only want to test the file you just edited, so you do not have to
wait for the full suite.

**What this checks:** Only the tests in the named file are compiled and run. Faster
feedback loop.

```bash
# Run only the IoTDevice model tests
flutter test test/unit/iot_device_test.dart

# Run only the DeviceCard widget tests
flutter test test/widget/device_card_test.dart
```

Expected output for a single file:

```
00:01 +11: All tests passed!
```

You can also run one specific test by name using `--name`:

```bash
flutter test test/unit/iot_device_test.dart --name "toJson round-trips all fields"
```

Expected output:

```
00:00 +1: All tests passed!
```

### A.4 What Each Existing Test File Checks and Why It Matters

#### `test/unit/iot_device_test.dart`

**Why this file exists:** `IoTDevice` is the central data model shared between
every layer of the app — the MQTT layer produces it, the UI layer consumes it,
and ObjectBox stores it. If `fromJson`/`toJson` are broken, a device that comes
online will either fail to parse or will silently lose data when cached locally.
The `copyWith` tests matter because Riverpod state is immutable: every UI update
goes through `copyWith`, so a bug there would either mutate the wrong field or
fail to update the right one.

Tests in this file:
- Default status is `offline` (a freshly created device should not appear online)
- `copyWith` updates only the specified fields and does not mutate the original
- `fromJson` parses all fields, handles a missing `local_ip`, and falls back to
  `offline` for unrecognised status strings
- `toJson` → `fromJson` round-trip — verifies that what goes in comes back out
  identically

#### `test/unit/mqtt_config_test.dart`

**Why this file exists:** `MqttConfig` is serialised to and from a key/value map
stored in `flutter_secure_storage`. If any field is written with the wrong key name
or read back with the wrong default, the broker connection will silently use the
wrong host, port, or TLS setting — a bug that would be very hard to trace in
production.

Tests in this file:
- Default values are correct (port 1883, TLS off, 10-second timeout)
- `isConfigured` is `false` for an empty or whitespace-only host
- `toStorageMap` serialises every field as a string (because secure storage only
  supports strings)
- `fromStorageMap` round-trips — what you serialise you can deserialise
- `fromStorageMap` falls back to defaults for a completely empty map (first-launch
  safety)

#### `test/unit/ota_state_test.dart`

**Why this file exists:** The OTA update UI is driven by an `OtaUpdateState` value
object with four possible statuses: `idle`, `inProgress`, `complete`, and `failed`.
If the factory constructors set the wrong status or the wrong progress value, the
UI would show "Update complete" at 0% or never show the error message on failure.

Tests in this file:
- `OtaUpdateState.idle` has `progressPercent == 0` and no error message
- `OtaUpdateState.inProgress(id, 45)` carries exactly 45%
- `OtaUpdateState.complete` carries 100%
- `OtaUpdateState.failed` stores the error string
- Every state variant carries the correct `deviceId`

#### `test/widget/device_card_test.dart`

**Why this file exists:** `DeviceCard` is the most user-visible component in the
app — it is what the user sees for every device on the home screen. The expand/
collapse behaviour, the online/offline badge, and the capability chips all need to
work together. Widget tests run faster than integration tests and catch layout bugs
without needing a device.

The test file uses a `_StubRepository` instead of the real ObjectBox repository.
This is intentional: running the actual database in a unit/widget test environment
would require initialising ObjectBox on disk, which introduces I/O dependencies
and slows the tests down significantly.

Tests in this file:
- Card shows the device name
- Online device shows "Online" label; offline device shows "Offline"
- Capability chips render (up to 2 per card)
- Card is collapsed by default — no Switch or Slider visible
- Tapping the card expands it and shows a Switch (for `relay` capability)
- Tapping again collapses it

#### `test/widget/schema_driven_ui_builder_test.dart`

**Why this file exists:** `SchemaDrivenUiBuilder` generates the control panel
for a device entirely from its `capabilities` list. If the mapping from capability
name to widget type breaks, users would get the wrong control (or no control at
all) for their device. The "offline absorbs input" test is especially important:
it verifies that an `AbsorbPointer` widget wraps the controls when the device is
offline so the user cannot accidentally send commands to a disconnected device.

Tests in this file:
- `relay` capability renders a `Switch` labelled "Switch 1"
- `dimmer` capability renders a `Slider`
- `temperature_sensor` renders a read-only text display (`"23.5 °C"`)
- An unknown capability (`laser_cannon`) renders the fallback text
  "Unsupported capability"
- An offline device wraps its controls in an absorbing `AbsorbPointer`
- An online device does not absorb pointer input
- Multiple capabilities each render their own control independently

#### `test/widget_test.dart`

**Why this file exists:** This is the smoke test — the bare minimum check that
the entire app starts up without throwing an exception. It does not test any
specific behaviour; it just ensures that `DSGVHubApp` can be pumped through the
Flutter widget tester with a stub repository without crashing on the first frame.
If any top-level provider or initialisation code throws, this test catches it.

### A.5 How to Add a New Unit Test

Unit tests belong in `dsgv_hub_app/test/unit/`. They test a single class or
function in isolation, with no Flutter widgets and no network calls.

**Example scenario:** You add a new helper method `IoTDevice.isControllable` that
returns `true` only when the device is online and has at least one capability.
Here is how to add a test for it.

**Step 1 — Create (or open) the test file.**

Because this tests `IoTDevice`, add the new test to the existing file:

```
dsgv_hub_app/test/unit/iot_device_test.dart
```

**Step 2 — Add a new `test()` block inside the existing `group('IoTDevice', ...)`.**

```dart
test('isControllable is true only when online and has capabilities', () {
  const online = IoTDevice(
    uniqueDeviceId: 'X',
    deviceName: 'X',
    status: DeviceStatus.online,
    capabilities: ['relay'],
  );
  const offline = IoTDevice(
    uniqueDeviceId: 'Y',
    deviceName: 'Y',
    status: DeviceStatus.offline,
    capabilities: ['relay'],
  );
  const noCapabilities = IoTDevice(
    uniqueDeviceId: 'Z',
    deviceName: 'Z',
    status: DeviceStatus.online,
    capabilities: [],
  );

  expect(online.isControllable, isTrue);
  expect(offline.isControllable, isFalse);
  expect(noCapabilities.isControllable, isFalse);
});
```

**Step 3 — Run the test to confirm it fails first** (this is called "red-green"
testing: make sure the test actually catches a missing implementation before you
implement it).

```bash
flutter test test/unit/iot_device_test.dart --name "isControllable"
```

**Step 4 — Implement `isControllable` in `IoTDevice`, then run again.**

Expected output after implementation:

```
00:00 +1: All tests passed!
```

**Key rules for unit tests:**
- Import only `package:flutter_test/flutter_test.dart` and the class under test.
- Never import `package:flutter/material.dart` in a pure unit test — that pulls
  in widget infrastructure you do not need.
- Each `test()` description should read as a complete sentence describing what
  the code does, not what the test does. Good: `'isConfigured is false for empty
  host'`. Bad: `'test empty host returns false'`.

### A.6 How to Add a New Widget Test

Widget tests belong in `dsgv_hub_app/test/widget/`. They render Flutter widgets
in a fake environment (no real screen, no real GPU) and assert on what is present
in the widget tree.

**Example scenario:** You create a new `DeviceStatusBadge` widget that shows a
coloured dot next to a status label. You want to verify that the dot's colour
changes between online and offline.

**Step 1 — Create a new test file.**

```
dsgv_hub_app/test/widget/device_status_badge_test.dart
```

**Step 2 — Write the test.**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsgv_hub_app/domain/models/iot_device.dart';
import 'package:dsgv_hub_app/presentation/widgets/device_status_badge.dart';

// Helper: wraps the widget in a minimal MaterialApp so it has
// a Directionality and a MediaQuery (Flutter requires these).
Widget _wrap(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  group('DeviceStatusBadge', () {
    testWidgets('shows green dot for online status', (tester) async {
      await tester.pumpWidget(
        _wrap(const DeviceStatusBadge(status: DeviceStatus.online)),
      );
      // Find the Container that represents the dot.
      final container = tester.widget<Container>(
        find.byKey(const Key('status_dot')),
      );
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, Colors.green);
    });

    testWidgets('shows grey dot for offline status', (tester) async {
      await tester.pumpWidget(
        _wrap(const DeviceStatusBadge(status: DeviceStatus.offline)),
      );
      final container = tester.widget<Container>(
        find.byKey(const Key('status_dot')),
      );
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, Colors.grey);
    });
  });
}
```

**Step 3 — Run and confirm the test fails** (the widget does not exist yet).

```bash
flutter test test/widget/device_status_badge_test.dart
```

**Step 4 — Implement `DeviceStatusBadge`, then re-run.**

Expected output:

```
00:01 +2: All tests passed!
```

**Key rules for widget tests:**
- Always wrap your widget in at least a `MaterialApp`. Without it, most Material
  widgets throw `No MaterialLocalizations found` at runtime.
- Use `await tester.pump()` after any action (tap, scroll, setState) to let the
  widget rebuild. Use `await tester.pumpAndSettle()` when there are animations
  that need to finish.
- If your widget uses Riverpod providers, wrap it in `ProviderScope` with
  `overrides: [yourProvider.overrideWithValue(stub)]` — see the existing
  `device_card_test.dart` for the pattern.
- Prefer `find.byType()` and `find.text()` over `find.byKey()` unless the widget
  tree has multiple instances of the same type.

### A.7 Expected Output When All Tests Pass

```
00:06 +46: All tests passed!
```

If any test fails, Flutter prints the failing test name and a diff between the
expected and actual values:

```
00:03 +24 -1: IoTDevice toJson omits local_ip when null [E]
  Expected: <false>
    Actual: <true>
  package:flutter_test/src/matchers.dart ...
  test/unit/iot_device_test.dart 111:36  main.<fn>.<fn>

00:06 +45 -1: Some tests failed.
```

The `-1` in the progress counter means one test failed. Fix the code (or the
test, if the test expectation is wrong), then run again.

---

## Part B — Cloud Functions Tests (Manual curl)

Cloud Functions cannot be run locally without the Firebase Emulator Suite, which
requires a separate setup. The tests in this section hit the live deployed
functions. Every test is a single `curl` command you can paste into a terminal.

### B.1 Prerequisites

**What this checks before you start:** The functions must be deployed and the
Firebase project must be reachable from your terminal.

```bash
# Navigate to the app directory
cd dsgv_hub_app

# Deploy all functions (runs in the functions/ subdirectory automatically)
firebase deploy --only functions
```

Expected output (last few lines):

```
✔  functions[registerDevice(us-central1)]: Successful create operation.
✔  functions[getDeviceConfig(us-central1)]: Successful create operation.
...
✔  Deploy complete!

Project Console: https://console.firebase.google.com/project/YOUR_PROJECT_ID/overview
```

Set a shell variable for your project's function base URL so you do not have to
repeat it in every command. Replace `YOUR_PROJECT_ID` with your actual project ID:

```bash
BASE="https://us-central1-YOUR_PROJECT_ID.cloudfunctions.net"
```

Set a test device MAC address and token (these are fake values used only for
testing — 12 hex chars for the MAC, 32 hex chars for the token):

```bash
MAC="AABBCCDDEEFF"
TOKEN="0123456789ABCDEF0123456789ABCDEF"
```

### B.2 Testing `registerDevice`

**What this checks:** A new device (identified by MAC address and auth token) can
be registered in Firebase RTDB. Calling it a second time with the same MAC is
idempotent and returns `already_registered: true`.

**First call — registers the device:**

```bash
curl -s -X POST "$BASE/registerDevice" \
  -H "Content-Type: application/json" \
  -d "{\"device_id\": \"$MAC\", \"auth_token\": \"$TOKEN\"}" | jq .
```

Expected response:

```json
{
  "success": true
}
```

**Second call with the same MAC — idempotent:**

```bash
curl -s -X POST "$BASE/registerDevice" \
  -H "Content-Type: application/json" \
  -d "{\"device_id\": \"$MAC\", \"auth_token\": \"$TOKEN\"}" | jq .
```

Expected response:

```json
{
  "success": true,
  "already_registered": true
}
```

**Bad MAC format (not 12 hex chars) — validation error:**

```bash
curl -s -X POST "$BASE/registerDevice" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "TOOSHORT", "auth_token": "0123456789ABCDEF0123456789ABCDEF"}' | jq .
```

Expected response (HTTP 400):

```json
{
  "error": "device_id must be 12 hex characters (WiFi MAC)"
}
```

### B.3 Testing `getDeviceConfig`

**What this checks:** A registered device can retrieve its broker configuration.
An unregistered device gets the factory defaults. A registered device with a wrong
token gets a 401.

**Registered device with correct token:**

```bash
curl -s -X POST "$BASE/getDeviceConfig" \
  -H "Content-Type: application/json" \
  -d "{\"device_id\": \"$MAC\", \"auth_token\": \"$TOKEN\"}" | jq .
```

Expected response (factory config on a fresh registration):

```json
{
  "broker_host": "mqtt.dsgv.io",
  "broker_port": 8883,
  "broker_tls": true,
  "broker_username": "",
  "broker_password": ""
}
```

**Wrong token — authentication failure:**

```bash
curl -s -X POST "$BASE/getDeviceConfig" \
  -H "Content-Type: application/json" \
  -d "{\"device_id\": \"$MAC\", \"auth_token\": \"FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF\"}" | jq .
```

Expected response (HTTP 401):

```json
{
  "error": "Unauthorized"
}
```

**Unregistered device — returns factory defaults without error:**

```bash
curl -s -X POST "$BASE/getDeviceConfig" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "112233445566", "auth_token": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}' | jq .
```

Expected response:

```json
{
  "broker_host": "mqtt.dsgv.io",
  "broker_port": 8883,
  "broker_tls": true,
  "broker_username": "",
  "broker_password": ""
}
```

This is intentional: an unregistered device still gets a usable config so it can
connect to the factory broker and begin announcing itself, even before the Flutter
app has called `registerDevice`.

### B.4 Testing `updateDeviceConfig`

**What this checks:** An authenticated device owner can push a new broker
configuration (for example, switching to a local Mosquitto instance).

```bash
curl -s -X POST "$BASE/updateDeviceConfig" \
  -H "Content-Type: application/json" \
  -d "{
    \"device_id\": \"$MAC\",
    \"auth_token\": \"$TOKEN\",
    \"broker_host\": \"192.168.1.50\",
    \"broker_port\": 1883,
    \"broker_tls\": false,
    \"broker_username\": \"myuser\",
    \"broker_password\": \"mypass\"
  }" | jq .
```

Expected response:

```json
{
  "success": true
}
```

**Verify the config was written** by calling `getDeviceConfig` again:

```bash
curl -s -X POST "$BASE/getDeviceConfig" \
  -H "Content-Type: application/json" \
  -d "{\"device_id\": \"$MAC\", \"auth_token\": \"$TOKEN\"}" | jq .
```

Expected response (showing the updated config):

```json
{
  "broker_host": "192.168.1.50",
  "broker_port": 1883,
  "broker_tls": false,
  "broker_username": "myuser",
  "broker_password": "mypass"
}
```

### B.5 Testing `revertDeviceToFactory`

**What this checks:** The "Restore factory broker" action in the app resets the
config back to `mqtt.dsgv.io:8883` (TLS, no credentials).

```bash
curl -s -X POST "$BASE/revertDeviceToFactory" \
  -H "Content-Type: application/json" \
  -d "{\"device_id\": \"$MAC\", \"auth_token\": \"$TOKEN\"}" | jq .
```

Expected response:

```json
{
  "success": true
}
```

**Verify the revert** with `getDeviceConfig` — it should be back to factory values:

```bash
curl -s -X POST "$BASE/getDeviceConfig" \
  -H "Content-Type: application/json" \
  -d "{\"device_id\": \"$MAC\", \"auth_token\": \"$TOKEN\"}" | jq .
```

Expected response:

```json
{
  "broker_host": "mqtt.dsgv.io",
  "broker_port": 8883,
  "broker_tls": true,
  "broker_username": "",
  "broker_password": ""
}
```

### B.6 Testing `updateDeviceState`

This function has two distinct request paths. The bridge secret must be set in
your Firebase functions config before testing. Set it once:

```bash
firebase functions:config:set bridge.secret="my_bridge_secret_123"
firebase deploy --only functions
```

Then set the secret in your shell:

```bash
SECRET="my_bridge_secret_123"
```

#### Path 1 — Telemetry update (device publishes state)

**What this checks:** When the MQTT bridge receives a telemetry message, it
posts the device's full state to Firebase RTDB under `device_states/{MAC}`.

```bash
curl -s -X POST "$BASE/updateDeviceState" \
  -H "Content-Type: application/json" \
  -H "X-Bridge-Secret: $SECRET" \
  -d "{
    \"mac\": \"$MAC\",
    \"state\": {
      \"power\": true,
      \"brightness\": 75,
      \"current_temp\": 22.5
    }
  }" | jq .
```

Expected response:

```json
{
  "success": true
}
```

#### Path 2 — Status update (device goes offline via LWT)

**What this checks:** When a device disconnects ungracefully, the MQTT broker
publishes its Last Will and Testament. The bridge posts `online: false` to Firebase
so the app immediately shows the device as offline.

> **What is a Last Will and Testament (LWT)?** When an MQTT client connects to
> the broker, it can register a "last will" message — a topic and payload that the
> broker will publish automatically if the client disconnects without sending a
> clean disconnect packet (for example, if the power is cut). For DSGV devices the
> LWT is published to `devices/{MAC}/status` with payload `"offline"`. This is how
> the cloud knows a device has lost power or network without waiting for a timeout.

```bash
curl -s -X POST "$BASE/updateDeviceState" \
  -H "Content-Type: application/json" \
  -H "X-Bridge-Secret: $SECRET" \
  -d "{\"mac\": \"$MAC\", \"online\": false}" | jq .
```

Expected response:

```json
{
  "success": true
}
```

**Missing or wrong bridge secret — rejected:**

```bash
curl -s -X POST "$BASE/updateDeviceState" \
  -H "Content-Type: application/json" \
  -H "X-Bridge-Secret: wrongsecret" \
  -d "{\"mac\": \"$MAC\", \"online\": true}" | jq .
```

Expected response (HTTP 401):

```json
{
  "error": "Invalid bridge secret"
}
```

### B.7 Testing `linkDeviceToUser`

**What this checks:** After a user logs into the Flutter app with Firebase Auth,
the app calls `linkDeviceToUser` to record that this Firebase UID owns this
device. Google Home and Alexa read this ownership record during device discovery.

This test requires a valid Firebase ID token. Get one by signing in through the
Firebase REST API (replace `YOUR_WEB_API_KEY` with the value from your Firebase
console under Project Settings → Web API Key):

```bash
ID_TOKEN=$(curl -s -X POST \
  "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=YOUR_WEB_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"testpassword","returnSecureToken":true}' \
  | jq -r '.idToken')

echo "Got ID token: ${ID_TOKEN:0:20}..."
```

Expected output:

```
Got ID token: eyJhbGciOiJSUzI1NiIs...
```

Now link the device:

```bash
curl -s -X POST "$BASE/linkDeviceToUser" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $ID_TOKEN" \
  -d "{\"device_id\": \"$MAC\", \"auth_token\": \"$TOKEN\"}" | jq .
```

Expected response:

```json
{
  "success": true
}
```

**Without Authorization header — rejected:**

```bash
curl -s -X POST "$BASE/linkDeviceToUser" \
  -H "Content-Type: application/json" \
  -d "{\"device_id\": \"$MAC\", \"auth_token\": \"$TOKEN\"}" | jq .
```

Expected response (HTTP 401):

```json
{
  "error": "Missing Authorization header"
}
```

### B.8 Testing the OAuth 2.0 Flow End-to-End

The OAuth flow is what Google Home and Alexa use to link a user's account.
Testing it manually verifies that the login page renders, that credentials are
accepted, that an auth code is issued, and that the code can be exchanged for
an access token.

**What this checks:** The complete OAuth 2.0 Authorization Code flow from login
page to token.

**Step 1 — Fetch the login page (GET):**

```bash
curl -s "$BASE/oauthLoginPage?client_id=google&redirect_uri=https%3A%2F%2Foauth-redirect.googleusercontent.com%2Fr%2FYOUR_PROJECT_ID&state=RANDOM_STATE&response_type=code"
```

Expected output: An HTML page containing a `<form>` with email and password
fields. The exact markup will vary but it must not be a JSON error.

**Step 2 — Submit the login form (POST to oauthAuthorize):**

```bash
curl -s -X POST "$BASE/oauthAuthorize" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "email=test@example.com" \
  --data-urlencode "password=testpassword" \
  --data-urlencode "client_id=google" \
  --data-urlencode "redirect_uri=https://oauth-redirect.googleusercontent.com/r/YOUR_PROJECT_ID" \
  --data-urlencode "state=RANDOM_STATE" \
  --data-urlencode "response_type=code" \
  -D - -o /dev/null 2>&1 | grep -i "location:"
```

Expected output (a `302 Found` redirect with an auth code in the URL):

```
location: https://oauth-redirect.googleusercontent.com/r/YOUR_PROJECT_ID?code=ABC123&state=RANDOM_STATE
```

Extract the `code` value from the redirect URL. Let us call it `AUTH_CODE`.

```bash
AUTH_CODE="ABC123"  # paste the actual code from the redirect URL above
```

**Step 3 — Exchange the auth code for tokens (POST to oauthToken):**

```bash
curl -s -X POST "$BASE/oauthToken" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "code=$AUTH_CODE" \
  --data-urlencode "client_id=google" \
  --data-urlencode "client_secret=YOUR_GOOGLE_CLIENT_SECRET" \
  --data-urlencode "redirect_uri=https://oauth-redirect.googleusercontent.com/r/YOUR_PROJECT_ID" \
  | jq .
```

Expected response:

```json
{
  "access_token": "eyJhbGciOiJSUzI1NiIs...",
  "token_type": "Bearer",
  "expires_in": 3600,
  "refresh_token": "1//0gABCD..."
}
```

**Step 4 — Validate the access token (POST to oauthToken with refresh_token):**

```bash
REFRESH_TOKEN="1//0gABCD..."   # paste from previous response

curl -s -X POST "$BASE/oauthToken" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=refresh_token" \
  --data-urlencode "refresh_token=$REFRESH_TOKEN" \
  --data-urlencode "client_id=google" \
  --data-urlencode "client_secret=YOUR_GOOGLE_CLIENT_SECRET" \
  | jq .
```

Expected response (new access token):

```json
{
  "access_token": "eyJhbGciOiJSUzI1NiIs...",
  "token_type": "Bearer",
  "expires_in": 3600
}
```

### B.9 Checking Firebase RTDB to Confirm Writes Landed

After running the `curl` tests above, verify the data was written to the real
database. Open the Firebase console in your browser:

```
https://console.firebase.google.com/project/YOUR_PROJECT_ID/database/data
```

Navigate to these paths and confirm the expected data is present:

| Path | Expected data after test |
|---|---|
| `device_registry/AABBCCDDEEFF` | `auth_token`, `registered_at`, `last_seen` timestamps |
| `device_configs/AABBCCDDEEFF` | `broker_host`, `broker_port`, `broker_tls`, `is_factory` |
| `device_states/AABBCCDDEEFF` | `power`, `brightness`, `online`, `last_updated` |
| `user_devices/{uid}/AABBCCDDEEFF` | `true` |

Alternatively, use the Firebase CLI:

```bash
firebase database:get /device_registry/AABBCCDDEEFF
```

Expected output:

```json
{
  "auth_token": "0123456789ABCDEF0123456789ABCDEF",
  "last_seen": 1717459200000,
  "registered_at": 1717459100000
}
```

---

## Part C — Firmware Build Tests

Build tests verify that the C source code compiles cleanly for every device type
and chip variant. They do not require hardware and are safe to run on any machine
that has ESP-IDF installed.

### C.1 Prerequisites

You need ESP-IDF installed and the `idf.py` toolchain on your PATH. The
recommended way to check is:

```bash
idf.py --version
```

Expected output:

```
ESP-IDF v5.2.1
```

If you get `command not found`, you need to source the IDF environment first. On
Linux/macOS:

```bash
. $HOME/esp/esp-idf/export.sh
```

On Windows (PowerShell):

```powershell
C:\Espressif\frameworks\esp-idf-v5.2.1\export.ps1
```

All firmware commands run from the `dsgv_firmware/` directory:

```bash
cd dsgv_firmware
```

### C.2 Build a Single Device Type

**What this checks:** The named device type compiles without errors for the named
chip target. The output `.bin` file is placed in
`dsgv_firmware/devices/{DEVICE}/build/`.

```bash
make DEVICE=1gang_switch TARGET=esp32c3 build
```

Expected output (last few lines):

```
[100%] Linking CXX executable dsgv_1gang_switch.elf
esptool.py v4.7.0
Generating binary image from built executable
Generated: build/dsgv_1gang_switch.bin
Project build complete. To flash, run:
 idf.py flash
```

The exact percentage steps will vary. What matters is that it ends with
`Project build complete` and no `error:` lines.

Try each of the four supported chips to make sure the GPIO pin map compiles
correctly for each target:

```bash
make DEVICE=dimmer TARGET=esp32c3   build
make DEVICE=dimmer TARGET=esp32c6   build
make DEVICE=dimmer TARGET=esp32s3   build
make DEVICE=dimmer TARGET=esp32     build
```

### C.3 Build All 11 Device Types at Once (CI Pipeline)

**What this checks:** Every device type compiles without error for the given chip.
This is the command run in the CI pipeline before any release. If any single
device fails, `make build-all` exits immediately with a non-zero status code so
the CI job fails.

```bash
make TARGET=esp32c3 build-all
```

Expected output (condensed — one block per device):

```
Building all devices for TARGET=esp32c3…

══════════════════════════════════════════
  Building: 1gang_switch  (target: esp32c3)
══════════════════════════════════════════
...
Project build complete.

══════════════════════════════════════════
  Building: 2gang_switch  (target: esp32c3)
══════════════════════════════════════════
...
Project build complete.

[... repeats for all 11 types ...]

All devices built successfully.
```

The final line `All devices built successfully.` means all 11 device types
compiled cleanly.

### C.4 Checking Binary Size

**What this checks:** The compiled `.bin` file fits inside the OTA partition with
at least a 64 KB margin. If the binary is too large, the OTA update will fail at
runtime because the new firmware cannot fit in the inactive OTA slot.

The partition table (`partitions_4mb.csv`) allocates 1,835,008 bytes (1.75 MB)
for each OTA slot. The check script enforces this limit:

```bash
python3 scripts/check_binary_size.py \
  devices/1gang_switch/build/dsgv_1gang_switch.bin \
  1835008
```

Expected output when the binary is within budget:

```
  Binary  : dsgv_1gang_switch.bin
  Size    :    512,340 bytes  (500.3 KB)
  Limit   :  1,835,008 bytes  (1792.0 KB)
  Budget  :  27.9%    Headroom: 1,322,668 bytes (1291.7 KB)
  PASS
```

Expected output when the binary is too large:

```
  Binary  : dsgv_1gang_switch.bin
  Size    :  1,900,000 bytes  (1855.5 KB)
  Limit   :  1,835,008 bytes  (1792.0 KB)
  Budget  : 103.5%    Headroom: -64,992 bytes (-63.5 KB)

  FAIL: Binary exceeds OTA slot limit by 64,992 bytes (63.5 KB)
  Fix options:
    1. Add CONFIG_COMPILER_OPTIMIZATION_SIZE=y to sdkconfig.defaults
    2. Disable unused features (CONFIG_CHIP_OTA_REQUESTOR=n, etc.)
    3. Upgrade to 8 MB flash and switch to partitions_8mb.csv
```

For 8 MB flash boards (recommended for new hardware), use the larger limit:

```bash
python3 scripts/check_binary_size.py \
  devices/1gang_switch/build/dsgv_1gang_switch.bin \
  3080192
```

### C.5 Common Build Errors and How to Fix Them

**Error: `idf.py: command not found`**

The IDF environment variables are not active in your current shell session.
Source the export script and try again:

```bash
. $HOME/esp/esp-idf/export.sh
make DEVICE=1gang_switch TARGET=esp32c3 build
```

**Error: `No such file or directory: 'devices/dimmer/CMakeLists.txt'`**

The `DEVICE` variable does not match any directory under `devices/`. Check the
exact name:

```bash
make list
```

Expected output:

```
Valid DEVICE values:
  1gang_switch
  2gang_switch
  3gang_switch
  4gang_switch
  dimmer
  rgb_light
  colour_temp
  temp_sensor
  motion_sensor
  contact_sensor
  thermostat
```

**Error: `error: use of undeclared identifier 'GPIO_NUM_48'`**

You built an ESP32-S3 device type with `TARGET=esp32c3`. GPIO_NUM_48 only exists
on the S3 which has 45 GPIOs. Match the TARGET to the hardware:

```bash
make DEVICE=3gang_switch TARGET=esp32s3 build
```

**Error: `Component 'idf::esp_https_ota' not found`**

The ESP-IDF version is too old. OTA requires IDF v5.0+. Check your version:

```bash
idf.py --version
```

If the version is below 5.0, update IDF following the official instructions at
https://docs.espressif.com/projects/esp-idf/en/latest/esp32/get-started/

**Error: `CMake Error: The source directory does not appear to contain CMakeLists.txt`**

You ran `idf.py` directly from the wrong directory. The Makefile handles the
`-C devices/{DEVICE}` flag for you — always use `make`, not `idf.py` directly,
unless you `cd` into the device directory first.

---

## Part D — Firmware Hardware Tests (On a Real ESP32)

Hardware tests require a physical ESP32-C3, C6, or S3 board connected to your
computer via USB. They verify the runtime behaviour of the firmware, not just
whether it compiles.

> **What is the serial monitor?** Every ESP32 board has a USB-to-UART chip that
> exposes a virtual serial port on your computer (e.g., `/dev/ttyUSB0` on Linux,
> `/dev/cu.usbserial-*` on macOS, `COM3` on Windows). The firmware writes
> human-readable log messages to this port at 115200 baud. The serial monitor is
> just a terminal program that reads those messages. `idf.py monitor` (or
> `make ... monitor`) opens it automatically at the right baud rate. Press
> `Ctrl+]` to exit.

### D.1 Find Your Serial Port

**Linux:**

```bash
ls /dev/ttyUSB* /dev/ttyACM*
```

Expected output (one of these will be present when a board is plugged in):

```
/dev/ttyUSB0
```

**macOS:**

```bash
ls /dev/cu.usbserial-* /dev/cu.wchusbserial*
```

Expected output:

```
/dev/cu.usbserial-0001
```

**Windows (PowerShell):**

```powershell
[System.IO.Ports.SerialPort]::getportnames()
```

Expected output:

```
COM3
```

Set a shell variable for convenience:

```bash
PORT=/dev/ttyUSB0    # Linux
# PORT=/dev/cu.usbserial-0001   # macOS
```

### D.2 Flash and Monitor a Device

**What this checks:** The binary built in Part C can be written to the chip and
the chip boots correctly.

```bash
cd dsgv_firmware
make DEVICE=1gang_switch TARGET=esp32c3 PORT=$PORT fm
```

The `fm` target flashes the firmware and immediately opens the serial monitor
in the same command. You will see the flash progress followed by live boot logs.

Expected flash output:

```
Connecting........
Chip is ESP32-C3 (revision v0.4)
Features: WiFi, BLE
...
Writing at 0x00020000... (5 %)
Writing at 0x00028000... (10 %)
...
Wrote 512340 bytes (349476 compressed) at 0x00020000 in 4.5 seconds
Hash of data verified.
Leaving...
Hard resetting via RTS pin...
```

Immediately after the reset the serial monitor takes over and shows boot logs.

### D.3 Reading the Serial Log — What Each Log Tag Means

The firmware uses tagged log lines in the format `I (timestamp) TAG: message`
where `I` is the level (I = Info, W = Warning, E = Error, D = Debug).

| Tag | Module | What it tells you |
|---|---|---|
| `DSGV_main` | `main.c` | Boot sequence milestones |
| `DSGV_cfg` | Device config loader | NVS read/write for MQTT broker settings |
| `DSGV_Prov` | BLE provisioner | WiFi credential exchange over Bluetooth |
| `DSGV_MDNS` | mDNS service | Service advertisement on local network |
| `DSGV_MQTT` | MQTT client | Broker connection, publish, subscribe events |
| `DSGV_Firebase` | Firebase HTTPS client | Config fetch and OTA trigger |
| `DSGV_OTA` | OTA updater | Firmware download progress and completion |

A healthy boot from a provisioned device looks like this (timestamps in
milliseconds since reset):

```
I (312)  DSGV_main:      === DSGV Hub Firmware 1.0.0 Booting ===
I (318)  DSGV_cfg:       Loaded device config from NVS
I (892)  wifi:           connected with SSID
I (1204) DSGV_main:      Wi-Fi connected — LAN IP assigned.
I (1205) DSGV_main:      HTTP server : port 80
I (1210) DSGV_MDNS:      mDNS started. Hostname: dsgv-Switch.local
I (1215) DSGV_MDNS:      Advertising _dsgv._tcp on port 80
I (1890) DSGV_Firebase:  Fetching config from Firebase...
I (2340) DSGV_Firebase:  Config OK — broker: mqtt.dsgv.io:8883 TLS
I (2341) DSGV_MQTT:      Connecting to mqtt.dsgv.io:8883 (TLS)...
I (3105) DSGV_MQTT:      MQTT connected
I (3106) DSGV_MQTT:      Published announce to devices/AABBCCDDEEFF/announce
I (3107) DSGV_MQTT:      Subscribed to devices/AABBCCDDEEFF/command
I (3108) DSGV_main:      === DSGV Hub Firmware fully initialised ===
```

If you see `E (xxxx) DSGV_MQTT: Connection failed` the device cannot reach the
broker. If you see `W (xxxx) DSGV_main: No Wi-Fi credentials — entering BLE
provisioning mode` the device has not been provisioned yet.

### D.4 Verifying WiFi Connect and Firebase Fetch

**What this checks:** The device connects to the local WiFi AP, receives a DHCP
address, makes an outbound HTTPS request to Firebase, and retrieves its broker
configuration.

After flashing, watch the serial monitor output and look for this exact sequence:

```
I (...) wifi:           connected with SSID
I (...) DSGV_main:      Wi-Fi connected — LAN IP assigned.
I (...) DSGV_Firebase:  Fetching config from Firebase...
I (...) DSGV_Firebase:  Config OK — broker: mqtt.dsgv.io:8883 TLS
```

If you see:

```
E (...) DSGV_Firebase:  HTTP request failed: -1
```

Check that the device has internet access (not just LAN access — Firebase is a
cloud endpoint). Verify the Firebase Cloud Function is deployed and the URL in
`dsgv_config.h` matches your project.

### D.5 Verifying MQTT Connect and Announce

**What this checks:** After retrieving the broker config from Firebase, the device
connects to the MQTT broker and publishes an announce message containing its MAC
address, device type, capabilities, and firmware version.

In the serial monitor, look for:

```
I (...) DSGV_MQTT:      MQTT connected
I (...) DSGV_MQTT:      Published announce to devices/AABBCCDDEEFF/announce
I (...) DSGV_MQTT:      Subscribed to devices/AABBCCDDEEFF/command
```

To confirm the announce was received by the broker, subscribe to the topic from
any MQTT client (for example, `mosquitto_sub` from your development machine):

```bash
mosquitto_sub -h mqtt.dsgv.io -p 8883 --cafile /etc/ssl/certs/ca-certificates.crt \
  -t "devices/+/announce" -v
```

Expected output when the device boots:

```
devices/AABBCCDDEEFF/announce {"device_id":"AABBCCDDEEFF","name":"Switch_DDEEFF",
"type":"Switch","capabilities":["relay"],"firmware_version":"1.0.0",
"local_ip":"192.168.1.42"}
```

The `device_id` is the device's WiFi MAC address in uppercase hex without colons.

### D.6 Verifying mDNS — Using dns-sd on Your Computer

**What this checks:** The device is advertising itself on the local network via
mDNS so the Flutter app can discover it without needing an IP address.

Your computer and the ESP32 must be on the same WiFi network.

**macOS or Linux:**

```bash
dns-sd -B _dsgv._tcp local
```

Expected output (updates live as devices appear/disappear):

```
Browsing for _dsgv._tcp.local
DATE: ---Tue 03 Jun 2026---
12:34:56.789  Add        2   5 local    _dsgv._tcp.  Switch_DDEEFF._dsgv._tcp.local.
```

The `Switch_DDEEFF` part is the device's mDNS hostname derived from its device
type and last three MAC bytes.

To resolve the full TXT records (which contain the device ID, capabilities, and
firmware version):

```bash
dns-sd -L "Switch_DDEEFF" _dsgv._tcp local
```

Expected output:

```
Lookup Switch_DDEEFF._dsgv._tcp.local
DATE: ---Tue 03 Jun 2026---
12:34:57.001  Switch_DDEEFF._dsgv._tcp.local. can be reached at dsgv-Switch.local.:80
  id=AABBCCDDEEFF
  caps=["relay"]
  type=Switch
  fw=1.0.0
```

**Windows (with Bonjour installed):**

```
dns-sd -B _dsgv._tcp local
```

The output format is the same as macOS.

If `dns-sd` is not available on Windows, download Bonjour Browser (a free GUI
tool) or the Apple Bonjour SDK from https://developer.apple.com/bonjour/.

### D.7 Verifying Telemetry Is Publishing (Using MQTT Explorer)

**What this checks:** The device publishes its sensor/relay state every
30 seconds to `devices/{MAC}/telemetry`.

Download MQTT Explorer from https://mqtt-explorer.com/ (free, cross-platform).

1. Open MQTT Explorer and create a new connection.
2. Set host to your broker hostname, port 8883, enable TLS.
3. Click Connect.
4. In the topic tree on the left, expand `devices` → find your device MAC →
   click `telemetry`.
5. The payload panel on the right shows the latest message.

Expected payload for a 1-gang switch:

```json
{
  "power": false,
  "device_id": "AABBCCDDEEFF",
  "local_ip": "192.168.1.42",
  "firmware_version": "1.0.0",
  "uptime_s": 142
}
```

The message will refresh every 30 seconds (`DSGV_TELEMETRY_INTERVAL_MS` in
`dsgv_config.h`).

### D.8 Sending a Manual Command (Using MQTT Explorer)

**What this checks:** The device responds to a command published to its
`devices/{MAC}/command` topic.

In MQTT Explorer:

1. In the **Publish** panel at the bottom, set topic to:
   ```
   devices/AABBCCDDEEFF/command
   ```
   (Replace `AABBCCDDEEFF` with your device's actual MAC.)

2. Set payload to:
   ```json
   {"power": true}
   ```

3. Set QoS to 1 and click **Publish**.

Expected result in the serial monitor:

```
I (...) DSGV_MQTT:   Command received: {"power":true}
I (...) DSGV_GPIO:   Relay 1 → ON
```

The relay on the physical board should click or the LED should light up,
depending on your hardware. The next telemetry message (within 30 seconds) should
show `"power": true`.

To turn it off:

```json
{"power": false}
```

### D.9 Verifying OTA Update Works

**What this checks:** The firmware can download and apply a new firmware binary
over WiFi, then reboot into it.

> **What is an OTA update?** OTA stands for Over-The-Air. The ESP32 has two
> firmware storage partitions (ota_0 and ota_1). The currently running firmware
> lives in one slot. During an OTA update, the new binary is streamed from an
> HTTPS URL and written to the inactive slot. If the download completes without
> error, the bootloader is told to switch to the new slot on the next reboot. If
> the new firmware crashes before confirming it is good, the bootloader rolls back
> to the previous slot automatically. The device can never be permanently bricked
> by a bad OTA image.

**Step 1 — Build the new firmware version.**

Increment the version string in `dsgv_config.h` or make a code change:

```c
#define dsgv_firmware_VERSION   "1.0.1"
```

```bash
make DEVICE=1gang_switch TARGET=esp32c3 build
```

**Step 2 — Host the binary on an HTTPS server accessible to the device.**

The simplest option is a temporary Python HTTPS server (requires a self-signed
cert) or uploading the binary to Firebase Storage / an S3 bucket. For a quick
local test on the same network, use `ngrok` to expose a local HTTP server:

```bash
cd devices/1gang_switch/build
python3 -m http.server 8080 &
ngrok http 8080
```

`ngrok` will print a public HTTPS URL like `https://abc123.ngrok.io`.

**Step 3 — Trigger the OTA update via MQTT.**

Publish to `devices/{MAC}/ota-trigger` with the firmware URL as the payload:

```bash
mosquitto_pub -h mqtt.dsgv.io -p 8883 --cafile /etc/ssl/certs/ca-certificates.crt \
  -t "devices/AABBCCDDEEFF/ota-trigger" \
  -m "https://abc123.ngrok.io/dsgv_1gang_switch.bin"
```

**Step 4 — Watch the serial monitor for OTA progress:**

```
I (...) DSGV_OTA:    OTA trigger received: https://abc123.ngrok.io/...
I (...) DSGV_OTA:    WiFi signal: -45 dBm (above -70 minimum)
I (...) DSGV_OTA:    Downloading firmware... 0%
I (...) DSGV_OTA:    Downloading firmware... 25%
I (...) DSGV_OTA:    Downloading firmware... 50%
I (...) DSGV_OTA:    Downloading firmware... 75%
I (...) DSGV_OTA:    Downloading firmware... 100%
I (...) DSGV_OTA:    OTA write complete. Rebooting into new firmware.
```

After the reboot, the monitor will show the boot sequence again. Confirm the new
version is running:

```
I (312)  DSGV_main:  === DSGV Hub Firmware 1.0.1 Booting ===
```

If OTA fails (for example, because the WiFi signal is below `-70 dBm`) you will
see:

```
W (...) DSGV_OTA:    WiFi signal too weak for OTA: -78 dBm (minimum: -70 dBm)
W (...) DSGV_OTA:    OTA aborted. Device continues on current firmware.
```

The device continues running normally — no data is lost.

---

## Part E — Voice Control Integration Tests (Google Home + Alexa)

Integration tests for voice control require developer console accounts and a fully
configured OAuth server. These are end-to-end tests that involve external services
and cannot be automated.

### E.1 Prerequisites

Before starting:

- Firebase Cloud Functions are deployed (Part B prerequisites)
- The OAuth 2.0 flow works end-to-end (Part B, Section B.8)
- A test device is registered, linked to a user account (Part B, Sections B.2
  and B.7), and currently online (Part D)
- You have a Google account enrolled in the Google Home app
- You have an Amazon account enrolled in the Alexa app

Set the following in Firebase functions config if you have not already:

```bash
firebase functions:config:set \
  oauth.google_client_id="YOUR_GOOGLE_CLIENT_ID" \
  oauth.google_client_secret="YOUR_GOOGLE_CLIENT_SECRET" \
  oauth.alexa_client_id="YOUR_ALEXA_CLIENT_ID" \
  oauth.alexa_client_secret="YOUR_ALEXA_CLIENT_SECRET" \
  oauth.firebase_api_key="YOUR_WEB_API_KEY"

firebase deploy --only functions
```

### E.2 Testing Google Home: Account Linking

**What this checks:** Google can authenticate a user through your OAuth server and
retrieve the list of that user's devices.

**Step 1 — In the Actions Console:**

1. Go to https://console.actions.google.com
2. Select your project.
3. Go to Develop → Account Linking.
4. Confirm the Authorization URL is set to:
   ```
   https://us-central1-YOUR_PROJECT_ID.cloudfunctions.net/oauthLoginPage
   ```
5. Confirm the Token URL is set to:
   ```
   https://us-central1-YOUR_PROJECT_ID.cloudfunctions.net/oauthToken
   ```

**Step 2 — Link the account in the Google Home app:**

1. Open the Google Home app on your phone.
2. Tap + → Set up device → Works with Google.
3. Search for your action (it appears as `[test] YOUR_APP_NAME`).
4. Follow the account linking flow — it opens the `oauthLoginPage` URL in a
   browser, you log in, and Google receives the auth code.
5. On success, Google Home says "Account linked successfully."

**Step 3 — Test device discovery:**

In the Google Home app, say or type: "Hey Google, sync my devices."

Expected result: Your device (e.g., "Switch_DDEEFF") appears in the Devices list
with type "Switch" (or "Light", "Thermostat", depending on capabilities).

If the device does not appear, check the `googleSmartHome` Cloud Function logs:

```bash
firebase functions:log --only googleSmartHome
```

Look for a SYNC request and verify the response contains your device's `id`, `type`,
and `traits`.

### E.3 Testing Google Home: Voice Command and State Query

**What this checks:** A voice command reaches the device and the device's new
state is reflected back to Google Home.

**Voice command:**

Say: "Hey Google, turn on Switch DDEEFF" (or whatever name the device was given
during SYNC).

Expected:
1. Google Home responds: "OK, turning on Switch DDEEFF."
2. Within 1–2 seconds, the relay on the physical board activates.
3. The serial monitor shows:
   ```
   I (...) DSGV_MQTT:   Command received: {"power":true}
   I (...) DSGV_GPIO:   Relay 1 → ON
   ```

**State query:**

Say: "Hey Google, is Switch DDEEFF on?"

Expected:
1. Google sends a QUERY intent to `googleSmartHome`.
2. The function reads `device_states/{MAC}` from Firebase RTDB.
3. Google Home responds: "Switch DDEEFF is on."

To verify what Google Home sent and received, check the Cloud Function logs:

```bash
firebase functions:log --only googleSmartHome
```

Look for lines showing the intent type (`action.devices.QUERY`), the device ID,
and the returned state object.

### E.4 Testing Alexa: Skill Setup and Discovery

**What this checks:** Alexa can link accounts and discover devices through your
`alexaSmartHome` Cloud Function.

**Step 1 — In the Alexa Developer Console:**

1. Go to https://developer.amazon.com/alexa/console/ask
2. Open your Smart Home skill.
3. Under Account Linking, confirm the Authorization URI and Access Token URI
   point to your Cloud Functions.
4. Under Default Endpoint, confirm the Lambda or HTTPS endpoint URL is:
   ```
   https://us-central1-YOUR_PROJECT_ID.cloudfunctions.net/alexaSmartHome
   ```

**Step 2 — Enable the skill in the Alexa app:**

1. Open the Alexa app.
2. Go to Skills & Games → search for your skill name.
3. Tap Enable to Use → link your account through the OAuth flow.

**Step 3 — Discover devices:**

Say: "Alexa, discover my devices."

Or in the Alexa app: Devices → + → Add Device → Other → Discover Devices.

Expected: Alexa says "I found 1 new device: Switch DDEEFF" and it appears in
Devices → All Devices.

If discovery fails, check the `alexaSmartHome` Cloud Function logs:

```bash
firebase functions:log --only alexaSmartHome
```

Look for the `Alexa.Discovery` directive and verify the endpoint list in the
response includes your device.

### E.5 Testing Alexa: Voice Command and ReportState

**Voice command:**

Say: "Alexa, turn on Switch DDEEFF."

Expected:
1. Alexa responds: "OK."
2. The relay activates within 1–2 seconds.
3. The serial monitor shows the command received.

**ReportState:**

Alexa periodically calls the `Alexa.ReportState` directive to check device state
without a user command. Your `alexaSmartHome` function handles this by reading
`device_states/{MAC}` from RTDB.

Trigger it manually via the Alexa Developer Console → Test tab:

```json
{
  "directive": {
    "header": {
      "namespace": "Alexa",
      "name": "ReportState",
      "payloadVersion": "3",
      "messageId": "test-message-id-001",
      "correlationToken": "test-token"
    },
    "endpoint": {
      "endpointId": "AABBCCDDEEFF"
    },
    "payload": {}
  }
}
```

Expected response (power currently on):

```json
{
  "event": {
    "header": {
      "namespace": "Alexa",
      "name": "StateReport",
      "payloadVersion": "3"
    },
    "payload": {}
  },
  "context": {
    "properties": [
      {
        "namespace": "Alexa.PowerController",
        "name": "powerState",
        "value": "ON",
        "timeOfSample": "2026-06-03T12:34:56Z",
        "uncertaintyInMilliseconds": 500
      }
    ]
  }
}
```

### E.6 What to Check in Firebase Console to Verify State Updates

After any voice command:

1. Open the Firebase console RTDB at:
   ```
   https://console.firebase.google.com/project/YOUR_PROJECT_ID/database/data/device_states
   ```
2. Find the node for your device MAC.
3. Confirm `power` changed to `true` (for a turn-on command) and `last_updated`
   is a recent Unix timestamp (milliseconds since epoch).

The `last_updated` value divided by 1000 gives you seconds since epoch. You can
convert it at https://www.epochconverter.com/ to verify it is within the last
minute.

---

## Part F — mDNS Local Discovery Tests (Flutter + Device on Same WiFi)

mDNS discovery lets the Flutter app find devices on the local network and
communicate with them directly (low latency, works offline) without routing
commands through the cloud MQTT broker.

### F.1 What mDNS Discovery Does in the App

When the app starts, the `multicast_dns` package sends a query for
`_dsgv._tcp.local` on the local WiFi network. Every DSGV device that is online
and on the same network responds with its hostname, port (80), and TXT records
containing `id=`, `caps=`, `type=`, and `fw=`. The app uses the `id` field to
match the discovered device to its existing `IoTDevice` record (matched by
`uniqueDeviceId`) and fills in the `localIp` field, enabling direct HTTP commands.

### F.2 Testing mDNS Discovery from the Flutter App

**What this checks:** The app discovers a device on the local network and
populates `localIp` without the device needing to publish its IP over MQTT.

**Prerequisites:**
- The ESP32 is powered on and connected to the same WiFi network as your phone.
- The device has passed the serial monitor mDNS test from Part D, Section D.6.

**Step 1 — Enable verbose logging in the Flutter app.**

In `dsgv_hub_app/`, ensure the `multicast_dns` debug logging is enabled. Look for
the mDNS service initialisation in the app and add a print statement to the
discovery callback if needed, or check logcat/console.

**Step 2 — Launch the app on your phone.**

```bash
cd dsgv_hub_app
flutter run
```

Or install the debug APK from the `APK_BUILD_GUIDE.md`.

**Step 3 — Watch the debug console.**

In Android Studio or `flutter run` output, look for mDNS discovery messages:

```
D/DSGV_mDNS: Querying _dsgv._tcp.local...
D/DSGV_mDNS: Found service: Switch_DDEEFF._dsgv._tcp.local at 192.168.1.42:80
D/DSGV_mDNS: TXT records: {id: AABBCCDDEEFF, caps: ["relay"], type: Switch, fw: 1.0.0}
D/DSGV_mDNS: Matched device AABBCCDDEEFF — setting localIp to 192.168.1.42
```

The device card for `AABBCCDDEEFF` in the app should now show a LAN indicator
(depending on your UI implementation), and subsequent control commands will be
sent directly to `http://192.168.1.42/api/cmd` rather than via MQTT.

**Step 4 — Verify a direct HTTP command works.**

From your development machine (not the phone) — to manually test the HTTP
endpoint that the app would use:

```bash
curl -s -X POST http://192.168.1.42/api/cmd \
  -H "Content-Type: application/json" \
  -d '{"power": true}' | jq .
```

Expected response:

```json
{
  "success": true,
  "power": true
}
```

The relay should activate immediately (sub-10 ms latency).

### F.3 Fallback Behaviour When mDNS Is Not Available

**What this checks:** If mDNS discovery fails (the network blocks multicast, the
phone is on a guest network, or the device is far away), the app falls back to
MQTT commands through the cloud broker.

mDNS can fail in the following situations:
- The phone is on a different network segment from the ESP32 (common in
  enterprise WiFi with client isolation enabled).
- The router blocks multicast packets (some ISP-provided routers do this).
- The phone is connected via mobile data rather than WiFi.

When `localIp` is `null` in an `IoTDevice`, the app automatically routes all
commands through MQTT. The device card does not show a LAN indicator. Commands
take longer (typically 200–500 ms via cloud MQTT vs. <10 ms direct) but work
identically from the user's perspective.

**To test the fallback explicitly:**

1. Disconnect the phone from WiFi (switch to mobile data).
2. Try turning a device on or off from the app.
3. Expected: the command is sent via MQTT and the device responds within 1–2
   seconds (depending on broker latency). The serial monitor shows:
   ```
   I (...) DSGV_MQTT:   Command received: {"power":true}
   ```

---

## Part G — Making Changes — What Tests to Run After Common Changes

Use this table as a quick reference. Run every suite listed in the "Run these
tests" column after making changes of the given type.

| Change type | Files typically affected | Run these tests |
|---|---|---|
| Edit `IoTDevice` model | `lib/domain/models/iot_device.dart` | Part A — `flutter test test/unit/iot_device_test.dart` |
| Edit `MqttConfig` model | `lib/domain/models/mqtt_config.dart` | Part A — `flutter test test/unit/mqtt_config_test.dart` |
| Edit OTA service | `lib/domain/services/ota_service.dart` | Part A — `flutter test test/unit/ota_state_test.dart` |
| Edit `DeviceCard` widget | `lib/presentation/widgets/device_card.dart` | Part A — `flutter test test/widget/device_card_test.dart` |
| Edit `SchemaDrivenUiBuilder` | `lib/presentation/widgets/schema_driven_ui_builder.dart` | Part A — `flutter test test/widget/schema_driven_ui_builder_test.dart` |
| Any Dart change | Any `.dart` file | Part A — `flutter test` (full suite) |
| Edit `functions/index.js` or `functions/lib/` | Cloud Function logic | Part B — re-deploy and run all `curl` tests |
| Edit `registerDevice` or `getDeviceConfig` | `functions/index.js` | Part B sections B.2 and B.3 |
| Edit `updateDeviceState` | `functions/index.js` | Part B section B.6 |
| Edit OAuth handlers | `functions/lib/oauth.js` | Part B section B.8 + Part E |
| Edit Google Smart Home handler | `functions/lib/smarthome_google.js` | Part E section E.3 |
| Edit Alexa handler | `functions/lib/smarthome_alexa.js` | Part E sections E.4 and E.5 |
| Edit any `.c` or `.h` firmware file | `dsgv_firmware/main/` or `dsgv_firmware/devices/` | Part C section C.2 (build single device) |
| Edit shared firmware component | `dsgv_firmware/components/` | Part C section C.3 (`make build-all`) |
| Edit `dsgv_config.h` | GPIO maps, MQTT topics, OTA settings | Part C section C.2 + Part D sections D.4 through D.9 |
| Edit mDNS component | `dsgv_firmware/components/dsgv_mdns/` | Part C build + Part D section D.6 + Part F |
| Edit OTA component | `dsgv_firmware/components/dsgv_ota/` | Part C build + Part D section D.9 |
| New device type added | New directory under `dsgv_firmware/devices/` | Part C sections C.2 and C.3 |
| Change partition table | `partitions_4mb.csv` or `partitions_8mb.csv` | Part C section C.4 (binary size check) + full flash test (Part D section D.2) |
| Release / tag | All of the above | Part A (full suite) + Part B (all curl tests) + Part C (`make build-all`) + Part D (full hardware walkthrough) |
