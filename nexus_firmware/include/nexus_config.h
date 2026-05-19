#pragma once

/**
 * nexus_config.h
 * Central configuration for all Nexus Hub firmware builds.
 * Edit this file to match your deployment environment.
 */

// ── Device Identity & Capabilities ───────────────────────────────────────────
// Change these to build different types of hardware (e.g., "Smart Dimmer")
#define NEXUS_DEVICE_NAME        "Nexus Switch v1"
#define NEXUS_FIRMWARE_VERSION   "1.0.0"

// The capabilities array is sent via MQTT announce so the App knows what UI
// to draw. Options: "relay", "dimmer", "color_temperature",
//                   "temperature_sensor", "hvac_control"
#define NEXUS_DEVICE_CAPABILITIES "[\"relay\"]"

// ── MQTT Broker (Primary: Cloud, Fallback: Local Mosquitto) ──────────────────
#define MQTT_CLOUD_HOST          "your-emqx-endpoint.cloud"  // Replace with real
#define MQTT_CLOUD_PORT          8883                         // TLS port
#define MQTT_LOCAL_HOST          "192.168.1.100"             // LAN Mosquitto IP
#define MQTT_LOCAL_PORT          1883                         // Plain port
#define MQTT_KEEPALIVE_SEC       60
#define MQTT_QOS_AT_LEAST_ONCE   1
#define MQTT_RECONNECT_DELAY_MS  5000  // Delay before retrying local broker

// ── MQTT Topics ───────────────────────────────────────────────────────────────
// Device MAC will be substituted at runtime: devices/{mac}/status
#define MQTT_TOPIC_STATUS        "devices/%s/status"
#define MQTT_TOPIC_TELEMETRY     "devices/%s/telemetry"
#define MQTT_TOPIC_COMMAND       "devices/%s/command"
#define MQTT_TOPIC_OTA           "devices/%s/ota-trigger"
#define MQTT_TOPIC_ANNOUNCE      "devices/%s/announce"   // Published on connect
#define MQTT_LWT_PAYLOAD_OFFLINE "offline"
#define MQTT_LWT_PAYLOAD_ONLINE  "online"

// ── Local HTTP Server ─────────────────────────────────────────────────────────
// The Nexus Hub App uses this when phone and device are on the same Wi-Fi.
// Routes: GET /api/status, POST /api/cmd, GET /cm?cmnd= (Tasmota compat)
#define HTTP_SERVER_PORT         80
#define HTTP_MAX_RESP_SIZE       512
#define HTTP_MAX_BODY_SIZE       256

// ── GPIO Pin Map ──────────────────────────────────────────────────────────────
#define GPIO_RELAY_PIN           GPIO_NUM_2
#define GPIO_STATUS_LED_PIN      GPIO_NUM_8    // Built-in for ESP32-C3
#define GPIO_BUTTON_PIN          GPIO_NUM_9    // Physical factory-reset button

// ── OTA ───────────────────────────────────────────────────────────────────────
#define OTA_MIN_SIGNAL_DBMS      -80  // Abort OTA if Wi-Fi signal weaker than this
#define OTA_TIMEOUT_MS           60000

// ── Matter ────────────────────────────────────────────────────────────────────
#define MATTER_PRODUCT_ID        0x8001  // Register with CSA for production
#define MATTER_VENDOR_ID         0xFFF1  // Test vendor (replace for production)
