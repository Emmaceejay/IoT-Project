#pragma once

/**
 * dsgv_config.h — Hardware and protocol constants for the DSGV Hub firmware.
 *
 * Supports: ESP32 (classic), ESP32-C3, ESP32-C6, ESP32-S3.
 *
 * What lives here:
 *   - Chip-specific GPIO pin maps (selected by CONFIG_IDF_TARGET_* at build time)
 *   - MQTT broker defaults, topics, telemetry interval
 *   - LEDC PWM channel assignments
 *   - OTA / Matter / BLE provisioning constants
 *
 * What does NOT live here (moved to Kconfig / device sdkconfig.defaults):
 *   - DSGV_DEVICE_TYPE        → CONFIG_DSGV_DEVICE_TYPE
 *   - DSGV_DEVICE_CAPABILITIES→ CONFIG_DSGV_DEVICE_CAPABILITIES
 *   - Relay count             → CONFIG_DSGV_RELAY_COUNT
 *   - Firmware version        → project(VERSION x.y.z) in device CMakeLists.txt
 *                               read at runtime via esp_app_get_description()->version
 *
 * To configure a device, edit only:
 *   devices/<device_name>/sdkconfig.defaults
 */

// ── Device Identity (from Kconfig — set in each device's sdkconfig.defaults) ─
#define DSGV_DEVICE_TYPE         CONFIG_DSGV_DEVICE_TYPE
#define DSGV_DEVICE_CAPABILITIES CONFIG_DSGV_DEVICE_CAPABILITIES

// ── Firebase Config Gateway ───────────────────────────────────────────────────
// Replace YOUR_PROJECT_ID with your Firebase project ID.
// Find it at: Firebase Console → Project Settings → General → Project ID.
// This URL is not a secret — security is enforced by the auth_token.
#define FIREBASE_GET_CONFIG_URL \
    "https://us-central1-YOUR_PROJECT_ID.cloudfunctions.net/getDeviceConfig"

// How long (ms) to wait for a Firebase response before falling back to NVS cache
#define FIREBASE_TIMEOUT_MS      10000

// ── MQTT Broker (factory default — overridden by Firebase config fetch) ───────
// Must match MqttConfig.factoryDefault.host in mqtt_config.dart
// and FACTORY_CONFIG.broker_host in functions/index.js
#define MQTT_CLOUD_HOST          "mqtt.dsgv.io"
#define MQTT_CLOUD_PORT          8883
#define MQTT_KEEPALIVE_SEC       60
#define MQTT_QOS_AT_LEAST_ONCE   1
#define MQTT_RECONNECT_DELAY_MS  5000

// ── MQTT Topics ───────────────────────────────────────────────────────────────
#define MQTT_TOPIC_STATUS        "devices/%s/status"
#define MQTT_TOPIC_TELEMETRY     "devices/%s/telemetry"
#define MQTT_TOPIC_COMMAND       "devices/%s/command"
#define MQTT_TOPIC_OTA           "devices/%s/ota-trigger"
#define MQTT_TOPIC_ANNOUNCE      "devices/%s/announce"
#define MQTT_TOPIC_CONFIG        "devices/%s/config"
#define MQTT_LWT_PAYLOAD_OFFLINE "offline"
#define MQTT_LWT_PAYLOAD_ONLINE  "online"

// ── NVS namespaces ────────────────────────────────────────────────────────────
#define MQTT_CFG_NVS_NS          "mqtt_cfg"

// ── Telemetry ─────────────────────────────────────────────────────────────────
#define DSGV_TELEMETRY_INTERVAL_MS  30000

// ── Local HTTP Server ─────────────────────────────────────────────────────────
#define HTTP_SERVER_PORT         80
#define HTTP_MAX_RESP_SIZE       768
#define HTTP_MAX_BODY_SIZE       256

// ── GPIO Pin Map (chip-specific hardware constants) ───────────────────────────
// Selected automatically by CONFIG_IDF_TARGET_* at build time.
// Pass target: idf.py -DIDF_TARGET=esp32c3 build
//
//   relay           → DSGV_RELAY_PINS_ALL[0..3]   digital out, SSR / relay coil
//   dimmer PWM      → GPIO_DIMMER_PIN              LEDC ch 0, 5 kHz
//   CCT warm PWM    → GPIO_WARM_PIN                LEDC ch 1
//   CCT cool PWM    → GPIO_COOL_PIN                LEDC ch 2
//   RGB red PWM     → GPIO_RED_PIN                 LEDC ch 3
//   RGB green PWM   → GPIO_GREEN_PIN               LEDC ch 4
//   RGB blue PWM    → GPIO_BLUE_PIN                LEDC ch 5
//   NTC ADC temp    → GPIO_ADC_TEMP_PIN            ADC1, 10 k NTC thermistor
//   PIR motion      → GPIO_MOTION_PIN              digital in, HIGH = motion
//   Reed contact    → GPIO_CONTACT_PIN             digital in, LOW = closed
//   Status LED      → GPIO_STATUS_LED_PIN
//   Factory reset   → GPIO_BUTTON_PIN              hold 5 s
//
// ESP32 classic: input-only GPIOs 34-39 have no internal pull resistors.
//               Use external pull-up / pull-down on those pins.

// Maximum number of relay GPIO pins available on any supported chip.
#define DSGV_MAX_RELAY_COUNT     4

#if defined(CONFIG_IDF_TARGET_ESP32C3) || defined(CONFIG_IDF_TARGET_ESP32C6)
// ESP32-C3 / C6 — RISC-V, 6 LEDC channels (LS only), NimBLE, 22 GPIOs ───────
//
// Relay pin list (CONFIG_DSGV_RELAY_COUNT picks how many to activate):
//   1-gang: relay_pins[0] = GPIO 2
//   2-gang: relay_pins[0..1] = GPIO 2, 3
//   3-gang: relay_pins[0..2] = GPIO 2, 3, 4
//   4-gang: relay_pins[0..3] = GPIO 2, 3, 4, 5
//   Note: gangs 2-4 share pins with dimmer/CCT — do not combine those features.
#  define DSGV_RELAY_PINS_ALL     { GPIO_NUM_2, GPIO_NUM_3, GPIO_NUM_4, GPIO_NUM_5 }
#  define GPIO_DIMMER_PIN          GPIO_NUM_3
#  define GPIO_WARM_PIN            GPIO_NUM_4
#  define GPIO_COOL_PIN            GPIO_NUM_5
#  define GPIO_RED_PIN             GPIO_NUM_6
#  define GPIO_GREEN_PIN           GPIO_NUM_7
#  define GPIO_BLUE_PIN            GPIO_NUM_10
#  define GPIO_ADC_TEMP_PIN        GPIO_NUM_1
#  define GPIO_ADC_TEMP_CHANNEL    ADC_CHANNEL_1
#  define GPIO_MOTION_PIN          GPIO_NUM_11
#  define GPIO_CONTACT_PIN         GPIO_NUM_20
#  define GPIO_STATUS_LED_PIN      GPIO_NUM_8
#  define GPIO_BUTTON_PIN          GPIO_NUM_9

#elif defined(CONFIG_IDF_TARGET_ESP32S3)
// ESP32-S3 — Xtensa dual-core, 8 LEDC channels (LS only), NimBLE, 45 GPIOs ──
//   1-gang: GPIO 4
//   2-gang: GPIO 4, 21
//   3-gang: GPIO 4, 21, 47
//   4-gang: GPIO 4, 21, 47, 48
#  define DSGV_RELAY_PINS_ALL     { GPIO_NUM_4, GPIO_NUM_21, GPIO_NUM_47, GPIO_NUM_48 }
#  define GPIO_DIMMER_PIN          GPIO_NUM_5
#  define GPIO_WARM_PIN            GPIO_NUM_6
#  define GPIO_COOL_PIN            GPIO_NUM_7
#  define GPIO_RED_PIN             GPIO_NUM_15
#  define GPIO_GREEN_PIN           GPIO_NUM_16
#  define GPIO_BLUE_PIN            GPIO_NUM_17
#  define GPIO_ADC_TEMP_PIN        GPIO_NUM_1
#  define GPIO_ADC_TEMP_CHANNEL    ADC_CHANNEL_0
#  define GPIO_MOTION_PIN          GPIO_NUM_18
#  define GPIO_CONTACT_PIN         GPIO_NUM_19
#  define GPIO_STATUS_LED_PIN      GPIO_NUM_2
#  define GPIO_BUTTON_PIN          GPIO_NUM_0

#else
// ESP32 (classic) — Xtensa dual-core, 16 LEDC channels (HS+LS), 34 GPIOs ────
// Input-only GPIOs 34-39: no internal pull resistors; use external resistors.
//   1-gang: GPIO 26
//   2-gang: GPIO 26, 27
//   3-gang: GPIO 26, 27, 25
//   4-gang: GPIO 26, 27, 25, 32
#  define DSGV_RELAY_PINS_ALL     { GPIO_NUM_26, GPIO_NUM_27, GPIO_NUM_25, GPIO_NUM_32 }
#  define GPIO_DIMMER_PIN          GPIO_NUM_27
#  define GPIO_WARM_PIN            GPIO_NUM_14
#  define GPIO_COOL_PIN            GPIO_NUM_12
#  define GPIO_RED_PIN             GPIO_NUM_25
#  define GPIO_GREEN_PIN           GPIO_NUM_32
#  define GPIO_BLUE_PIN            GPIO_NUM_33
#  define GPIO_ADC_TEMP_PIN        GPIO_NUM_34   // ADC1 ch6, input-only
#  define GPIO_ADC_TEMP_CHANNEL    ADC_CHANNEL_6
#  define GPIO_MOTION_PIN          GPIO_NUM_35   // input-only, ext pull-down
#  define GPIO_CONTACT_PIN         GPIO_NUM_36   // input-only (SENSOR_VP), ext pull-up
#  define GPIO_STATUS_LED_PIN      GPIO_NUM_2
#  define GPIO_BUTTON_PIN          GPIO_NUM_0
#endif

// ── LEDC PWM channels ─────────────────────────────────────────────────────────
// Low-speed mode (LS), 5 kHz, 10-bit resolution (duty 0-1023).
#define LEDC_TIMER_FREQ_HZ       5000
#define LEDC_DUTY_RESOLUTION     LEDC_TIMER_10_BIT

#define LEDC_CH_DIMMER           LEDC_CHANNEL_0
#define LEDC_CH_WARM             LEDC_CHANNEL_1
#define LEDC_CH_COOL             LEDC_CHANNEL_2
#define LEDC_CH_RED              LEDC_CHANNEL_3
#define LEDC_CH_GREEN            LEDC_CHANNEL_4
#define LEDC_CH_BLUE             LEDC_CHANNEL_5

// ── OTA ───────────────────────────────────────────────────────────────────────
#define OTA_MIN_SIGNAL_DBMS      -70
#define OTA_TIMEOUT_MS           60000

// ── Matter ────────────────────────────────────────────────────────────────────
#define MATTER_PRODUCT_ID        0x8001  // register with CSA for production
#define MATTER_VENDOR_ID         0xFFF1  // test vendor (replace for production)

// ── BLE WiFi Provisioning ─────────────────────────────────────────────────────
// Device BLE name: DSGV_PROV_DEVICE_NAME_PREFIX + last 3 MAC bytes (hex)
//   e.g. "DSGVHub_A1B2C3"
// GATT Service UUID:  4fafc201-1fb5-459e-8fcc-c5c9c331914b
// Credential char:    beb5483e-36e1-4688-b7f5-ea07361b26a8  (Write JSON creds)
// Status char:        beb5483f-36e1-4688-b7f5-ea07361b26a8  (Read + Notify)
#define DSGV_PROV_DEVICE_NAME_PREFIX  "DSGVHub_"
