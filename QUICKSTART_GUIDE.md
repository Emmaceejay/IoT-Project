# The "Idiot-Proof" Quickstart Guide 🚀

Welcome to your new IoT Platform! Because we used professional architecture (Flutter + ESP-IDF), the setup takes a few specific steps. Follow this exactly, and you'll be up and running.

---

## PART 1: Running the Mobile App (Flutter)

You can run this on your Linux/Windows machine connected to an Android Phone (or an Android Emulator).

**Step 1: Install Prerequisites**
1. Download and install the [Flutter SDK](https://docs.flutter.dev/get-started/install).
2. Download and install [Android Studio](https://developer.android.com/studio). (You just need it installed so Flutter has the Android tools).

**Step 2: Connect a Phone**
1. Take your physical Android phone.
2. Go to **Settings > About Phone**. Tap "Build Number" 7 times to unlock Developer Mode.
3. Go back to Settings > **Developer Options**, and turn on **USB Debugging**.
4. Plug the phone into your computer via USB.

**Step 3: Run the App**
Open your terminal (command prompt), and type exactly this:
```bash
cd ~/antigravityWorks/IoT_Project_APP/dsgv_hub_app
flutter pub get
flutter run
```
*Wait a minute or two. The app will magically install and open on your phone!*

---

## PART 2: Flashing the Custom Hardware (ESP32)

We are using **ESP-IDF** (Espressif's official tool) inside **VS Code** because it is the *only* way to get Apple/Google Matter support working.

**Step 1: Prep VS Code**
1. Open **Visual Studio Code**.
2. Go to Extensions (the blocks icon on the left) and search for **Espressif IDF**. Install it.
3. Once installed, press `Ctrl + Shift + P` (or `Cmd + Shift + P` on Mac) and type: `ESP-IDF: Configure ESP-IDF Extension`.
4. Choose **EXPRESS Setup** and let it download all the tools. (This takes a few minutes, go grab a coffee).

**Step 2: Open the Firmware Project**
1. In VS Code, go to **File > Open Folder**.
2. Select EXACTLY this folder: `~/antigravityWorks/IoT_Project_APP/dsgv_firmware`

**Step 3: Select Your Chip**
1. Look at the very bottom blue bar in VS Code.
2. Find the little icon that looks like a chip or says `esp32` (or click `ESP-IDF: Set Espressif device target` from `Ctrl+Shift+P`).
3. Select the exact chip you bought (e.g., `esp32c3` or `esp32s3`).

**Step 4: Plug in your Board**
1. Plug your ESP32 board into your computer with a USB cable (make sure it's a data cable, not just a charging cable!).
2. In the VS Code bottom blue bar, click the **Plug Icon (Select Port)**. Choose the COM / USB port that appeared when you plugged the board in.

**Step 5: The Magic Buttons (Build, Flash, Monitor)**
Look at the bottom blue bar in VS Code again. You will see three icons:
1. ⚙️ **Build** (Click this first. It compiles your C code into a binary. First time takes ~2 mins).
2. ⚡ **Flash** (Click this second. It pushes the binary into the ESP32 chip via the USB cable).
3. 📺 **Monitor** (Click this third. It opens a terminal showing you what the chip is "thinking" in real-time!).

*Shortcut: You can also click the 🛠️⚡📺 icon (Build, Flash, Monitor all-in-one).*

### A Note on Matter (ESP-Matter SDK)
Because Matter is so huge, Espressif requires you to download the `esp-matter` SDK from their GitHub separately before uncommenting the Matter code in `matter_endpoint.c`. 
**My Advice:** Just flash the code *as it is right now* to make sure the board boots, connects to Wi-Fi, and talks to your Flutter App via MQTT. Once you see that working perfectly, you can tackle installing the massive Matter SDK!
