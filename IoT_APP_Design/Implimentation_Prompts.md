# Anthropic AI Implementation Prompts

This file contains structured prompts formatted for use with Anthropic models. Each prompt uses explicit markup blocks so the model can separate context, constraints, tasks, and deliverables more reliably.

---

## Prompt 1: Foundation

```xml
<prompt_document>
  <prompt_id>iot-master-app-foundation</prompt_id>
  <objective>
    Build the project foundation for a commercial IoT Master App using Flutter and Riverpod.
  </objective>

  <project_context>
    The application must support a fleet of custom IoT devices including ESP32, ESP8266, and ESP-01.
    The architecture should be scalable, production-oriented, and based on a clean separation of Data, Domain, and Presentation layers.
  </project_context>

  <tech_stack>
    <framework>Flutter</framework>
    <language>Dart</language>
    <state_management>Riverpod</state_management>
    <architecture>Clean Architecture with Data, Domain, and Presentation layers</architecture>
  </tech_stack>

  <requirements>
    <requirement>Create a clean folder structure for Data, Domain, and Presentation.</requirement>
    <requirement>Define an offline-first Isar Database wrapper for the main device data cache.</requirement>
    <requirement>Define a DeviceModel that includes connection states: Connected, Disconnected, and Provisioning.</requirement>
    <requirement>Create an abstract CommunicationProtocol interface.</requirement>
    <requirement>Create service stubs for Auth, BLE, MQTT, SoftAP, and OTA communication.</requirement>
    <requirement>Keep the code strongly typed and ready for future expansion.</requirement>
  </requirements>

  <implementation_constraints>
    <constraint>Use idiomatic Flutter and Dart conventions.</constraint>
    <constraint>Use Riverpod-friendly patterns so services and repositories can later be exposed as providers.</constraint>
    <constraint>Ensure the DeviceRepository serves data from Isar first, then syncs externally.</constraint>
    <constraint>Avoid placeholder architecture that would need major restructuring later.</constraint>
    <constraint>Prefer extensible abstractions over device-specific hardcoding.</constraint>
  </implementation_constraints>

  <expected_output>
    <item>Recommended folder structure</item>
    <item>Isar collection boilerplate for Device caching</item>
    <item>Dart code for the DeviceModel and connection state enum</item>
    <item>Dart code for the CommunicationProtocol interface</item>
    <item>Auth, BLE, MQTT, and SoftAP service stubs</item>
    <item>Short explanation of how the pieces connect securely</item>
  </expected_output>

  <instruction>
    Generate the foundation code and structure for this app. Return production-style starter code, not pseudocode.
  </instruction>
</prompt_document>
```

---

## Prompt 2: Provisioning Logic

```xml
<prompt_document>
  <prompt_id>iot-master-app-provisioning</prompt_id>
  <objective>
    Implement the two in-app provisioning flows for ESP32 and ESP8266/ESP-01 devices in Flutter.
  </objective>

  <project_context>
    The application must provision devices without forcing the user to leave the app. ESP32 devices use BLE for provisioning. ESP8266 and ESP-01 devices use a SoftAP workflow.
  </project_context>

  <tech_requirements>
    <package>flutter_blue_plus</package>
    <package>wifi_iot</package>
    <package>http or dio</package>
  </tech_requirements>

  <provisioning_paths>
    <path name="Matter Commissioning Protocol">
      <step>Trigger OS-level Matter Commissioning APIs (iOS HomeKit / Google Play Services) via Flutter platform channels or Matter plugin.</step>
      <step>Capture QR code data or manual 11-digit pairing code.</step>
      <step>Delegate the BLE secure exchange and Wi-Fi delegation entirely to the underlying OS.</step>
      <step>Once the device is physically on the network, execute a secondary MQTT verification ping to ensure our EMQX broker identifies the new node.</step>
      <step>Map the confirmed device metadata to the user's local Isar Auth cache.</step>
    </path>
  </provisioning_paths>

  <implementation_constraints>
    <constraint>Use clear separation between UI state, provisioning logic, and network services.</constraint>
    <constraint>Include Android-specific handling for Wi-Fi routing.</constraint>
    <constraint>Include proper async error handling and loading states.</constraint>
    <constraint>Write code that can be integrated into a Riverpod architecture.</constraint>
  </implementation_constraints>

  <expected_output>
    <item>Dart implementation for the BLE provisioning flow</item>
    <item>Dart implementation for the SoftAP provisioning flow</item>
    <item>Any supporting models or service methods required</item>
    <item>Notes about Android-specific behavior and networking caveats</item>
  </expected_output>

  <instruction>
    Implement both provisioning paths in usable Flutter code. Prefer realistic service-layer code over abstract descriptions.
  </instruction>
</prompt_document>
```

---

## Prompt 3: MQTT and LWT Logic

```xml
<prompt_document>
  <prompt_id>iot-master-app-mqtt-lwt-dashboard</prompt_id>
  <objective>
    Build the MQTT communication layer, Last Will and Testament logic, and a dynamic dashboard for multiple device types.
  </objective>

  <project_context>
    The app manages multiple IoT devices and must react in real time to online and offline state changes. The UI should adapt based on the type and capabilities of each device.
  </project_context>

  <tech_requirements>
    <package>mqtt_client</package>
    <package>Flutter</package>
    <package>Riverpod</package>
  </tech_requirements>

  <mqtt_requirements>
    <requirement>Implement MQTT connectivity using mqtt_client with mTLS support via bundled certificates.</requirement>
    <requirement>Support Dynamic Broker switching (e.g. fallback from user's AWS IoT / Cloud connection to a local standard Mosquitto broker if specified).</requirement>
    <requirement>Subscribe to status topics for all registered devices.</requirement>
    <requirement>Fallback to local Isar cache when the application encounters network unavailability.</requirement>
    <requirement>Handle LWT-based offline messages.</requirement>
    <requirement>If a device status payload is offline, update the Isar cache and inform Riverpod listeners accordingly.</requirement>
  </mqtt_requirements>

  <topic_convention>
    <status_topic>devices/{deviceId}/status</status_topic>
  </topic_convention>

  <ui_requirements>
    <requirement>Create a dynamic dashboard that renders controls based on the device model.</requirement>
    <requirement>Show toggle controls for ESP-01 devices.</requirement>
    <requirement>Show graphs or richer telemetry widgets for ESP32 devices.</requirement>
    <requirement>Grey out or disable controls when a device is offline.</requirement>
  </ui_requirements>

  <implementation_constraints>
    <constraint>Use strongly typed device models and state objects.</constraint>
    <constraint>Keep MQTT handling isolated from UI rendering concerns.</constraint>
    <constraint>Design the dashboard so adding future device types is straightforward.</constraint>
  </implementation_constraints>

  <expected_output>
    <item>MQTT service implementation</item>
    <item>LWT subscription and status-handling logic</item>
    <item>Riverpod-compatible state flow for device status updates</item>
    <item>Dynamic dashboard widget structure for multiple device types</item>
    <item>Short explanation of how the dashboard chooses the correct UI per device</item>
  </expected_output>

  <instruction>
    Generate implementation-oriented Flutter code for the MQTT layer and adaptive dashboard. Avoid vague pseudocode.
  </instruction>
</prompt_document>
```

---

## Prompt 4: Firmware OTA & Telemetry Strategy

```xml
<prompt_document>
  <prompt_id>iot-master-app-ota-telemetry</prompt_id>
  <objective>
    Implement an Over-The-Air (OTA) update orchestrator and observability suite.
  </objective>

  <project_context>
    A professional IoT App must manage remote firmware updates reliably and centralize logging to detect hardware/software failures in the fleet.
  </project_context>

  <requirements>
    <requirement>Implement an OTA orchestrator service that streams binaries or pointers to securely signed firmware via HTTPS or MQTT blocks.</requirement>
    <requirement>Implement a UI to display progress bars when a fleet device is actively flashing/rebooting.</requirement>
    <requirement>Implement a crash reporting and logging singleton (conceptual wrapper around Sentry/Crashlytics) for recording dropped provisions and MQTT disconnects.</requirement>
  </requirements>

  <expected_output>
    <item>OTA Orchestrator Service methods</item>
    <item>Widgets demonstrating OTA firmware upgrade progress</item>
    <item>Telemetry service stub used globally for trapping network failures</item>
  </expected_output>

  <instruction>
    Write the Flutter code to reliably push firmware updates to the devices, including safety checks (e.g., preventing upgrades if device battery/signal is too weak).
  </instruction>
</prompt_document>
```
