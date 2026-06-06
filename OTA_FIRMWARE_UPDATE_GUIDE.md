# How to Push a Firmware Update to Your Device

**Plain English:** You build a firmware file on your computer, put it online so the device can download it, then tell the app where to find it. That's it.

---

## What You Will Need

- Your computer (already set up with ESP-IDF for building firmware)
- A GitHub account (free — the same one your code is already on)
- The DSGV Hub app installed and connected to the device

---

## Step 1 — Build the Firmware

Open PowerShell, go to the device folder, and build:

```powershell
cd C:\Users\Chijioke\Documents\IoT-Project\dsgv_firmware\devices\1gang_switch
idf.py build
```

Wait for it to finish. When done you will see a file at:

```
build\1gang_switch.bin
```

That `.bin` file is your firmware. Keep the PowerShell window open — you need it for Step 3.

> **Building a different device?** Just change `1gang_switch` to the device folder name, e.g. `2gang_switch`, `dimmer`, `rgb_light`, etc. The `.bin` file will be inside that device's `build\` folder.

---

## Step 2 — Upload the Firmware to GitHub Releases

GitHub Releases is like a free file hosting service built into your repo. It gives you a permanent download link for every file you upload.

1. Open your browser and go to: `https://github.com/Emmaceejay/IoT-Project`
2. Click **Releases** on the right side of the page
3. Click **Draft a new release**
4. In the **Choose a tag** box, type a version number like `v1.0.1` and click **Create new tag: v1.0.1**
5. Give the release a title, e.g. `Firmware v1.0.1`
6. Scroll down and click **Attach binaries by dropping them here or selecting them**
7. Find and select your `.bin` file from the `build` folder
8. Click **Publish release**

Now right-click the `.bin` filename on the release page and select **Copy link address**. It will look something like:

```
https://github.com/Emmaceejay/IoT-Project/releases/download/v1.0.1/1gang_switch.bin
```

Save this URL — you need it in Step 4.

---

## Step 3 — Get the Hash of the Firmware File

A hash is like a fingerprint of the file. The device uses it to confirm the file was not corrupted during download.

In the **same PowerShell window** from Step 1, run this command (replace the path if your build folder is different):

```powershell
Get-FileHash build\1gang_switch.bin -Algorithm SHA256
```

You will see output like:

```
Algorithm  Hash                                                              Path
---------  ----                                                              ----
SHA256     A3F1C2D4E5B6A7C8D9E0F1A2B3C4D5E6F7A8B9C0D1E2F3A4B5C6D7E8F9A0B1C2  build\1gang_switch.bin
```

Copy the long string of letters and numbers under **Hash**. That is your SHA-256 hash.

---

## Step 4 — Enter the Details in the App

1. Open the DSGV Hub app on your phone
2. Tap the **Settings** tab (bottom navigation bar, gear icon)
3. Scroll down until you see the **Firmware Update** section
4. Paste the URL you copied in Step 2 into the **Firmware URL** field
5. Paste the hash you copied in Step 3 into the **SHA-256 Hash** field
6. Tap **Save Firmware Settings** — the button turns green briefly to confirm

You only do Steps 2–4 once per firmware release. The app remembers the settings even after you close it.

---

## Step 5 — Push the Update to a Device

1. On the Dashboard, tap the device you want to update
2. The device must show **Online** — you cannot update an offline device
3. Tap **Push Firmware Update**
4. A progress bar appears. Wait for it to reach 100% and show **Update Complete**
5. The device will reboot automatically and reconnect within about 30 seconds

**Do not close the app while the progress bar is running.**

---

## If Something Goes Wrong

| Problem | What to do |
|---|---|
| Button is greyed out | Device is offline — wait for it to reconnect |
| Orange message about "no firmware configured" | Go back to Settings and complete Step 4 |
| Progress bar gets stuck at 0% | Check that the URL is correct and publicly accessible (paste it in a browser — you should see a download start) |
| Device does not reconnect after reboot | The flash failed — try again. The old firmware is still intact (ESP32 dual-bank OTA is safe) |

---

## Updating Multiple Devices

You can push to each device one at a time from their individual detail pages. The URL and hash stay saved in Settings, so you just open each device and tap **Push Firmware Update** — no re-entering anything.

---

## Quick Reference — Commands Cheat Sheet

| What | Command (PowerShell) |
|---|---|
| Build firmware | `idf.py build` |
| Get SHA-256 hash | `Get-FileHash build\1gang_switch.bin -Algorithm SHA256` |
| Flash via USB (optional) | `idf.py flash monitor` |
| Full erase + flash (clean slate) | `esptool.py --chip esp32c3 erase_flash` then `idf.py flash` |
