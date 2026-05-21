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
