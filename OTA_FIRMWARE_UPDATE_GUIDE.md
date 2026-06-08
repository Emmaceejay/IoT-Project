# How to Push a Firmware Update to Your Devices

**Plain English:** You build a firmware file on your computer, upload it to GitHub Releases to get a permanent download link, compute its SHA-256 fingerprint, then paste both into a single JSON file (`firmware_manifest.json`) in your repo. The app reads that file automatically — no user interaction or app update required.

---

## How It Works (Big Picture)

```
You (developer)
    │
    ├── Build firmware .bin file
    ├── Upload to GitHub Releases → get URL
    ├── Compute SHA-256 hash of the file
    └── Edit firmware_manifest.json in the repo
            │
            ▼
    GitHub hosts the file permanently
            │
            ▼
    App reads manifest.json → shows "Update available" on device page
            │
            ▼
    User taps "Update to v1.x.x" in app → device downloads & flashes itself
```

You only ever touch three things:
1. The `.bin` file you build
2. GitHub Releases (to host it)
3. `firmware_manifest.json` (to tell the app about it)

---

## What You Will Need

- Your computer with ESP-IDF already set up
- A GitHub account (same one the repo lives in)
- The DSGV Hub app installed on your phone

---

## Step 1 — Build the Firmware

Open PowerShell, go to the device folder, and run the build command:

```powershell
cd C:\Users\Chijioke\Documents\IoT-Project\dsgv_firmware\devices\1gang_switch
idf.py build
```

Wait for it to finish. When it says `Project build complete`, your firmware file is at:

```
build\1gang_switch.bin
```

> **Building a different device?** Change `1gang_switch` to the correct device folder name
> (e.g. `2gang_switch`, `dimmer`, `rgb_light`, `colour_temp`, `temp_sensor`, etc.).
> The `.bin` file will be inside that device's `build\` folder.

---

## Step 2 — Get the SHA-256 Hash of the File

A hash is a fingerprint of the file. The device checks it after downloading to confirm nothing was corrupted in transit.

In the **same PowerShell window**, run:

```powershell
Get-FileHash build\1gang_switch.bin -Algorithm SHA256
```

You will see output like:

```
Algorithm  Hash                                                              Path
---------  ----                                                              ----
SHA256     A3F1C2D4E5B6A7C8D9E0F1A2B3C4D5E6F7A8B9C0D1E2F3A4B5C6D7E8F9A0B1C2  build\1gang_switch.bin
```

**Copy the long string under Hash.** That is your SHA-256. You will need it in Step 4.

---

## Step 3 — Upload the Firmware to GitHub Releases

GitHub Releases gives every file you upload a permanent, publicly accessible download link.

1. Open your browser and go to: `https://github.com/Emmaceejay/IoT-Project`
2. Click **Releases** on the right side of the page
3. Click **Draft a new release**
4. In the **Choose a tag** box, type a version number like `v1.0.1` and click **Create new tag: v1.0.1**
5. Give it a title, e.g. `Firmware v1.0.1`
6. Click **Attach binaries by dropping them here or selecting them** and select the `.bin` file from the `build` folder
7. Click **Publish release**

After publishing:
- Right-click the `.bin` filename on the release page
- Select **Copy link address**

The link will look like:
```
https://github.com/Emmaceejay/IoT-Project/releases/download/v1.0.1/1gang_switch.bin
```

**Save this URL — you need it in Step 4.**

> If you are updating multiple device types at the same time, repeat Steps 1–3 for each
> one (build each device, upload each `.bin`, collect each URL and hash before moving on).

---

## Step 4 — Update the Manifest File

The manifest is a single JSON file at the root of the repo:

```
IoT-Project\firmware_manifest.json
```

Open it in any text editor (Notepad, VS Code, anything). It looks like this:

```json
{
  "version": "1.0.0",
  "release_date": "2026-06-08",
  "notes": "Initial OTA-enabled release.",
  "devices": {
    "1gang_switch":  { "url": "", "hash": "" },
    "2gang_switch":  { "url": "", "hash": "" },
    ...
  }
}
```

**Make these changes:**

| Field | What to put |
|---|---|
| `"version"` | New version number, e.g. `"1.0.1"` |
| `"release_date"` | Today's date, e.g. `"2026-06-15"` |
| `"notes"` | One sentence describing what changed |
| `"url"` (inside each device) | The GitHub Releases link you copied in Step 3 |
| `"hash"` (inside each device) | The SHA-256 you copied in Step 2 |

**Only update the device entries you actually built new firmware for.**
Leave the other entries' `url` and `hash` values unchanged — they still point to the
previous valid binary for those device types.

**Example after editing:**

```json
{
  "version": "1.0.1",
  "release_date": "2026-06-15",
  "notes": "Fixed wall switch debounce causing double-toggle on fast presses.",
  "devices": {
    "1gang_switch":  {
      "url": "https://github.com/Emmaceejay/IoT-Project/releases/download/v1.0.1/1gang_switch.bin",
      "hash": "A3F1C2D4E5B6A7C8D9E0F1A2B3C4D5E6F7A8B9C0D1E2F3A4B5C6D7E8F9A0B1C2"
    },
    "2gang_switch":  { "url": "...(previous url)...", "hash": "...(previous hash)..." },
    ...
  }
}
```

---

## Step 5 — Commit and Push the Manifest

Save the file, then push it to GitHub so the app can find it:

```powershell
cd C:\Users\Chijioke\Documents\IoT-Project
git add firmware_manifest.json
git commit -m "chore: release firmware v1.0.1"
git push
```

That's it. As soon as the push completes, any user who taps **Check for Updates** on their device page will see the new version.

---

## Step 6 — Push the Update to a Device (from the App)

1. Open the DSGV Hub app on your phone
2. Tap a device on the Dashboard to open its detail page
3. Scroll down to the **Firmware Update** section
4. Tap **Check for Updates** — the app fetches the manifest from GitHub
5. If a new version is available, you will see the version number and release notes
6. Tap **Update to v1.0.1** (the device must show **Online**)
7. A progress bar appears — wait for it to finish
8. The device reboots automatically and reconnects within about 30 seconds

**Do not close the app while the progress bar is running.**

---

## If Something Goes Wrong

| Problem | What to do |
|---|---|
| "Check for Updates" button shows an error | Check your phone's internet connection and try again |
| "Device type not in manifest" message | The device is running very old firmware — flash via USB first (see Quick Reference below) |
| Update button is greyed out with "Device Offline" | The device is not connected — wait for it to come back online |
| Update button says "No binary uploaded yet" | The `url` field in the manifest is still empty — complete Step 3 and 4 |
| Progress bar gets stuck at 0% | Check that the GitHub Releases URL is publicly accessible (paste it in a browser — you should see a download start) |
| Device does not reconnect after reboot | The flash failed — try again. The old firmware is still intact (ESP32 dual-bank OTA is safe) |

---

## Updating Multiple Devices

Open each device's detail page one by one and tap **Update to v1.x.x** on each.
The manifest is shared — you only edit it once regardless of how many devices you update.

---

## Quick Reference — Commands Cheat Sheet

| What | Command (PowerShell) |
|---|---|
| Build firmware | `idf.py build` (run from the device folder) |
| Get SHA-256 hash | `Get-FileHash build\<device>.bin -Algorithm SHA256` |
| Flash via USB (initial or recovery) | `idf.py flash monitor` |
| Full erase + flash (clean slate) | `esptool.py --chip esp32c3 erase_flash` then `idf.py flash` |
| Push manifest update | `git add firmware_manifest.json && git commit -m "chore: release vX.X.X" && git push` |

---

## Manifest File Location

The manifest is always at the same permanent URL — **never change this URL**:

```
https://raw.githubusercontent.com/Emmaceejay/IoT-Project/main/firmware_manifest.json
```

The app has this URL baked in. If you ever move the repo, you will need to rebuild and
redistribute the app with the new URL.
