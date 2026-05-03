# IoT Master App Design Blueprint

This document is structured as an Anthropic-friendly specification. It uses explicit markup sections so an AI model can reliably parse architecture, requirements, constraints, and workflows before generating code.

```xml
<iot_master_app_blueprint>
  <document_meta>
    <title>IoT Master App Design and Architecture Blueprint</title>
    <purpose>
      Define the architecture, communication model, provisioning flows, and implementation rules for a scalable Flutter-based IoT control application.
    </purpose>
    <target_ai>Anthropic</target_ai>
    <intended_use>
      Use this document as the primary system or project context when generating code, architecture decisions, service implementations, repositories, and UI flows.
    </intended_use>
  </document_meta>

  <project_overview>
    <summary>
      Build a single scalable Flutter application to control a fleet of custom IoT devices including ESP32, ESP8266, and ESP-01. The app must support BLE, MQTT, and SoftAP provisioning without requiring the user to leave the application.
    </summary>
    <goals>
      <goal>Support multiple device families in one app.</goal>
      <goal>Provide dynamic control surfaces based on device capabilities.</goal>
      <goal>Handle provisioning within the app.</goal>
      <goal>Support reliable real-time online and offline device monitoring.</goal>
      <goal>Use a clean, maintainable, production-oriented architecture.</goal>
    </goals>
  </project_overview>

  <architecture_strategy>
    <framework>Flutter latest stable</framework>
    <language>Dart</language>
    <state_management>Riverpod with AsyncNotifier for real-time device streams</state_management>
    <database>Isar - For highly performant offline-first caching of device state.</database>
    <pattern>Repository Pattern with Local Caching Fallback</pattern>
    <layering>Data, Domain, Presentation</layering>

    <architecture_notes>
      <note>
        The app must be offline-resilient. The UI communicates with a DeviceRepository that draws from local Isar cache first, while syncing state via BLE, MQTT, or local HTTP in the background.
      </note>
      <note>
        Communication services should be isolated and injectable so they can be reused across repositories and state notifiers.
      </note>
      <note>
        Security & Multi-Tenant: Architecture should enforce JWT/OAuth tokens injected into network interceptors, supporting device-sharing among multiple users.
      </note>
    </architecture_notes>
  </architecture_strategy>

  <device_abstraction>
    <base_device>
      <description>Abstract base class for all devices.</description>
      <common_properties>
        <property>id</property>
        <property>name</property>
        <property>type</property>
        <property>connectionState</property>
        <property>capabilities</property>
      </common_properties>
    </base_device>

    <device_types>
      <device>
        <name>ESP32MatterDevice</name>
        <description>
          Primary hardware class (requires ESP32, ESP32-C3, or S3). Runs Dual-Stack firmware computing both the Matter CHIP protocol and our native MQTT Client payload.
        </description>
      </device>
    </device_types>
  </device_abstraction>

  <communication_protocols>
    <protocol>
      <name>Matter Commissioning (BLE+IPv6)</name>
      <package>Official OS Matter APIs / flutter_matter</package>
      <purpose>Initial onboarding of new hardware via QR Code scanning. Delegates Wi-Fi credential passing to the OS secure enclave.</purpose>
    </protocol>

    <protocol>
      <name>MQTT</name>
      <package>mqtt_client</package>
      <purpose>Primary remote control and telemetry post-commissioning. Our master app controls devices exclusively via MQTT.</purpose>
      <strategy>Dynamic Broker Strategy: App must handle both Local Mosquitto setups (mDNS discovered) and Cloud Providers (AWS IoT / EMQX). Must enforce mTLS encrypting payloads wherever possible.</strategy>
    </protocol>

    <protocol>
      <name>Firmware OTA</name>
      <purpose>Continuous Over-The-Air deployment capability. Devices fetch signed binary payloads via secure HTTPS or MQTT blocks, orchestrated by the master application.</purpose>
    </protocol>
  </communication_protocols>

  <availability_monitoring>
    <title>Last Will and Testament Logic</title>

    <firmware_requirements>
      <requirement>When connecting to the MQTT broker, the device must define an LWT message.</requirement>
      <requirement>The LWT topic must be devices/{deviceId}/status.</requirement>
      <requirement>The LWT payload must be offline.</requirement>
      <requirement>The LWT message should be retained.</requirement>
      <requirement>Immediately after a successful connection, the device must publish online to the same topic with retain enabled.</requirement>
    </firmware_requirements>

    <app_requirements>
      <requirement>The app must subscribe to the status topic for every device in the fleet.</requirement>
      <requirement>If the broker publishes offline, the corresponding device must immediately be marked offline in app state.</requirement>
      <requirement>Offline devices must have their controls disabled or visually greyed out.</requirement>
      <requirement>Status updates must propagate through reactive state management so the UI updates in real time.</requirement>
    </app_requirements>
  </availability_monitoring>

  <provisioning_workflow>
    <path name="Matter Commissioning Flow (Primary)">
      <step>Invoke the native iOS/Android Matter Commissioning APIs from within Flutter.</step>
      <step>Scan the device's 11-digit Matter QR Code using the device camera.</step>
      <step>Allow the OS (Apple/Google) to perform the secure BLE handshake and pass the Wi-Fi credentials to the ESP32.</step>
      <step>Upon successful OS commissioning, register the device's unique ID into our backend and bind it to the user's MQTT tenant ID.</step>
    </path>
  </provisioning_workflow>

  <observability_and_analytics>
    <metric>Remote crash logging (via Crashlytics/Sentry).</metric>
    <metric>Device provisioning success/failure rate tracking.</metric>
    <metric>Centralize connection dropping reports to evaluate hardware fleet health over time.</metric>
  </observability_and_analytics>

  <ui_behavior>
    <dashboard_rules>
      <rule>The dashboard must render different controls depending on device type and capability.</rule>
      <rule>ESP-01 devices should generally render simple toggle-based controls.</rule>
      <rule>ESP32 devices should support richer widgets such as sensor graphs and multi-control panels.</rule>
      <rule>Offline devices must visibly communicate unavailable state.</rule>
      <rule>The UI should be extensible so future device types can add custom dashboards without major refactoring.</rule>
    </dashboard_rules>
  </ui_behavior>

  <coding_standards>
    <standard>
      <name>Strict Typing</name>
      <rule>Use strong Dart models for JSON parsing and avoid dynamic whenever possible.</rule>
    </standard>

    <standard>
      <name>Service Isolation</name>
      <rule>BLEService, MQTTService, and WifiProvisionService must be independent singletons or injectable services.</rule>
    </standard>

    <standard>
      <name>Security</name>
      <rule>Use flutter_secure_storage for MQTT credentials, tokens, and API keys.</rule>
    </standard>

    <standard>
      <name>Error Handling</name>
      <rule>Implement robust retry logic for hardware timeouts, dropped connections, and transient provisioning failures.</rule>
    </standard>

    <standard>
      <name>Separation of Concerns</name>
      <rule>Keep UI widgets, repositories, protocols, and state logic separated cleanly.</rule>
    </standard>
  </coding_standards>

  <ai_generation_guidance>
    <instruction>Generate production-style Flutter and Dart code, not vague pseudocode.</instruction>
    <instruction>Prefer maintainable abstractions over shortcuts that only work for a single device model.</instruction>
    <instruction>When generating files, preserve the Data, Domain, and Presentation folder structure.</instruction>
    <instruction>When generating state logic, make it compatible with Riverpod.</instruction>
    <instruction>When generating networking logic, include realistic async error handling and typed responses.</instruction>
    <instruction>When generating dashboards, prefer composable widgets and device capability-driven rendering.</instruction>
  </ai_generation_guidance>
</iot_master_app_blueprint>
```

## Usage Note

For best Anthropic results, provide this blueprint as the project context document and pair it with one of the structured prompts in [Implimentation_Prompts.md](/c:/Users/Administrator/Documents/IoT_APP_Design/Implimentation_Prompts.md).
