<div align="center">
  <h1>Nexus Hub IoT Platform</h1>
  <p><strong>A Professional, Dual-Layer, Matter-Compliant Smart Ecosystem</strong></p>
</div>

---

## 🌟 Overview

The **Nexus Hub** is an enterprise-grade IoT platform designed for universal device support, absolute network resilience, and modern smart home compatibility. It is split into two perfectly decoupled layers:

1. **Nexus Hub App**: A Flutter/Riverpod mobile application engineered with a **Schema-Driven UI** and an offline-first Isar database.
2. **Nexus Firmware**: An ESP-IDF C/C++ firmware running a **Dual-Stack Architecture** (Matter Protocol + Custom MQTT).

By combining these, devices can be natively commissioned via Apple HomeKit, Google Home, or Amazon Alexa (thanks to Matter), while simultaneously providing complete, custom "Pro" control via the dedicated Nexus Hub MQTT network.

## 🚀 Core Architectural Features

* **Hybrid Dual-Broker MQTT**: Devices connect securely to an EMQX Cloud Broker (via mTLS) but gracefully fail over to a local Mosquitto Hub (discovered via mDNS) if the internet drops. The Flutter App seamlessly follows suit.
* **Schema-Driven UX**: The Flutter App does not hardcode control widgets. Devices broadcast their `capabilities` (e.g., `["relay", "dimmer"]`) on boot, and the app dynamically renders the exact UI required.
* **Matter Commissioning**: Devices are provisioned using OS-level Matter APIs. No custom, insecure SoftAP hacking or tricky BLE credential passing required.
* **Over-The-Air (OTA) Orchestration**: Firmware updates are triggered via MQTT payloads, directing devices to securely fetch signed binaries over HTTPS into a dual-bank partition.

## 📂 Repository Structure

The repository maintains strict separation of concerns between the mobile application and the hardware logic.

```text
IoT_Project_APP/
├── IoT_APP_Design/        # Core architectural whitepapers and AI generation prompts
├── nexus_hub_app/         # The Mobile UI (Dart / Flutter)
└── nexus_firmware/        # The Embedded Code (C / C++ / ESP-IDF)
```

## 🛠️ Getting Started

For a comprehensive, beginner-friendly guide on how to launch the mobile app and flash your physical ESP32 boards, please consult the **[Quickstart Guide](./QUICKSTART_GUIDE.md)** included in this repository.

For technical deep dives into the platform design, state management strategies, and firmware structures, refer to the whitepapers located in the `IoT_APP_Design/` directory.

---
*Built with professional IoT standards prioritizing privacy, speed, and cross-ecosystem interoperability.*
