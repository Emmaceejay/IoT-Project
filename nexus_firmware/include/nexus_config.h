#pragma once

/**
 * nexus_config.h
 * Central configuration for all Nexus Hub firmware builds.
 * Supports: ESP32 (classic), ESP32-C3, ESP32-C6, ESP32-S3.
 * Edit this file to match your deployment environment.
 */

// ── Device Identity & Capabilities ───────────────────────────────────────────
// NEXUS_DEVICE_TYPE is used as a prefix in the auto-generated device name.
// The full name is built at runtime: "{TYPE}_{last3MacBytes}", e.g. "Switch_A1B2C3".
// No need to change this per-unit — every device gets a unique name from its MAC.
#define NEXUS_DEVICE_TYPE        "Switch"   // Switch | Dimmer | Sensor | Thermostat | RGB
#define NEXUS_FIRMWARE_VERSION   "1.0.0"

// The capabilities array is sent via MQTT announce so the App renders the
// correct controls. Choose the subset that matches your hardware build.
// Options:
//   "relay"              — on/off output (SSR or relay coil)
//   "dimmer"             — single-channel PWM brightness (0-100 %)
//   "color_temperature"  — dual-channel CCT (warm + cool PWM)
//   "rgb_light"          — three-channel RGB (red + green + blue PWM)
//   "temperature_sensor" — current_temp via SOC internal sensor or NTC ADC
//   "humidity_sensor"    — humidity % via external I²C sensor (SHT30, DHT22…)
//   "motion_sensor"      — PIR digital input (HIGH = motion)
//   "contact_sensor"     — reed-switch digital input (LOW = closed)
//   "hvac_control"       — thermostat (target_temp + mode: cool/heat/auto/off)
#define NEXUS_DEVICE_CAPABILITIES "[\"relay\"]"

// ── MQTT Broker (Primary: Cloud TLS, Fallback: Local Mosquitto) ───────────────
#define MQTT_CLOUD_HOST          "your-emqx-endpoint.cloud"  // replace with real
#define MQTT_CLOUD_PORT          8883
#define MQTT_LOCAL_HOST          "192.168.1.100"
#define MQTT_LOCAL_PORT          1883
#define MQTT_KEEPALIVE_SEC       60
#define MQTT_QOS_AT_LEAST_ONCE   1
#define MQTT_RECONNECT_DELAY_MS  5000

// ── MQTT Topics ───────────────────────────────────────────────────────────────
#define MQTT_TOPIC_STATUS        "devices/%s/status"
#define MQTT_TOPIC_TELEMETRY     "devices/%s/telemetry"
#define MQTT_TOPIC_COMMAND       "devices/%s/command"
#define MQTT_TOPIC_OTA           "devices/%s/ota-trigger"
#define MQTT_TOPIC_ANNOUNCE      "devices/%s/announce"
#define MQTT_LWT_PAYLOAD_OFFLINE "offline"
#define MQTT_LWT_PAYLOAD_ONLINE  "online"

// ── Telemetry ─────────────────────────────────────────────────────────────────
// Interval between periodic sensor reads + MQTT telemetry publishes (ms).
#define NEXUS_TELEMETRY_INTERVAL_MS  30000

// ── Local HTTP Server ─────────────────────────────────────────────────────────
#define HTTP_SERVER_PORT         80
#define HTTP_MAX_RESP_SIZE       768   // large enough for full telemetry + local_ip
#define HTTP_MAX_BODY_SIZE       256

// ── GPIO Pin Map (per-chip defaults) ─────────────────────────────────────────
// Selected automatically by CONFIG_IDF_TARGET_* at build time.
// Pass target on the command line: idf.py -DIDF_TARGET=esp32c3 build
//
// Hardware signal → GPIO mapping:
//   relay           → GPIO_RELAY_PIN        digital out, drives SSR / relay coil
//   dimmer PWM      → GPIO_DIMMER_PIN       LEDC ch 0, 5 kHz
//   CCT warm PWM    → GPIO_WARM_PIN         LEDC ch 1
//   CCT cool PWM    → GPIO_COOL_PIN         LEDC ch 2
//   RGB red PWM     → GPIO_RED_PIN          LEDC ch 3
//   RGB green PWM   → GPIO_GREEN_PIN        LEDC ch 4
//   RGB blue PWM    → GPIO_BLUE_PIN         LEDC ch 5
//   NTC ADC temp    → GPIO_ADC_TEMP_PIN     ADC1, 10 k NTC thermistor (fallback)
//   PIR motion      → GPIO_MOTION_PIN       digital in, HIGH = motion detected
//   Reed contact    → GPIO_CONTACT_PIN      digital in, LOW = closed
//   Status LED      → GPIO_STATUS_LED_PIN
//   Factory reset   → GPIO_BUTTON_PIN       hold 5 s
//
// Note: Original ESP32 input-only GPIOs 34-39 have no internal pull resistors.
//       Use external pull-up / pull-down resistors for those pins.

#if defined(CONFIG_IDF_TARGET_ESP32C3) || defined(CONFIG_IDF_TARGET_ESP32C6)
// ESP32-C3 / C6 — RISC-V, 6 LEDC channels (LS only), NimBLE, 22 GPIOs ───────
//
// Multi-gang relay config (edit NEXUS_RELAY_COUNT + NEXUS_RELAY_PINS together):
//   1-gang:  COUNT=1  PINS={ GPIO_NUM_2 }
//   2-gang:  COUNT=2  PINS={ GPIO_NUM_2, GPIO_NUM_3 }
//   3-gang:  COUNT=3  PINS={ GPIO_NUM_2, GPIO_NUM_3, GPIO_NUM_4 }
//   4-gang:  COUNT=4  PINS={ GPIO_NUM_2, GPIO_NUM_3, GPIO_NUM_4, GPIO_NUM_5 }
//   (Note: gangs 2-4 share pins with dimmer/CCT — don't mix relay_N and those
//    capabilities in the same build.)
#  define NEXUS_RELAY_COUNT        1
#  define NEXUS_RELAY_PINS         { GPIO_NUM_2 }
#  define NEXUS_RELAY_PINS_ALL     { GPIO_NUM_2, GPIO_NUM_3, GPIO_NUM_4, GPIO_NUM_5 }
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
//   1-gang:  COUNT=1  PINS={ GPIO_NUM_4 }
//   2-gang:  COUNT=2  PINS={ GPIO_NUM_4, GPIO_NUM_21 }
//   3-gang:  COUNT=3  PINS={ GPIO_NUM_4, GPIO_NUM_21, GPIO_NUM_47 }
//   4-gang:  COUNT=4  PINS={ GPIO_NUM_4, GPIO_NUM_21, GPIO_NUM_47, GPIO_NUM_48 }
#  define NEXUS_RELAY_COUNT        1
#  define NEXUS_RELAY_PINS         { GPIO_NUM_4 }
#  define NEXUS_RELAY_PINS_ALL     { GPIO_NUM_4, GPIO_NUM_21, GPIO_NUM_47, GPIO_NUM_48 }
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
//   1-gang:  COUNT=1  PINS={ GPIO_NUM_26 }
//   2-gang:  COUNT=2  PINS={ GPIO_NUM_26, GPIO_NUM_27 }
//   3-gang:  COUNT=3  PINS={ GPIO_NUM_26, GPIO_NUM_27, GPIO_NUM_25 }
//   4-gang:  COUNT=4  PINS={ GPIO_NUM_26, GPIO_NUM_27, GPIO_NUM_25, GPIO_NUM_32 }
#  define NEXUS_RELAY_COUNT        1
#  define NEXUS_RELAY_PINS         { GPIO_NUM_26 }
#  define NEXUS_RELAY_PINS_ALL     { GPIO_NUM_26, GPIO_NUM_27, GPIO_NUM_25, GPIO_NUM_32 }
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
// All targets: low-speed mode (LS), 5 kHz, 10-bit resolution (duty 0-1023).
// ESP32 classic supports high-speed channels too, but LS is available on all.
#define LEDC_TIMER_FREQ_HZ       5000
#define LEDC_DUTY_RESOLUTION     LEDC_TIMER_10_BIT   // 0-1023

#define LEDC_CH_DIMMER           LEDC_CHANNEL_0
#define LEDC_CH_WARM             LEDC_CHANNEL_1
#define LEDC_CH_COOL             LEDC_CHANNEL_2
#define LEDC_CH_RED              LEDC_CHANNEL_3
#define LEDC_CH_GREEN            LEDC_CHANNEL_4
#define LEDC_CH_BLUE             LEDC_CHANNEL_5

// ── OTA ───────────────────────────────────────────────────────────────────────
#define OTA_MIN_SIGNAL_DBMS      -80
#define OTA_TIMEOUT_MS           60000

// ── Matter ────────────────────────────────────────────────────────────────────
#define MATTER_PRODUCT_ID        0x8001  // register with CSA for production
#define MATTER_VENDOR_ID         0xFFF1  // test vendor (replace for production)

// ── BLE WiFi Provisioning ─────────────────────────────────────────────────────
// Device BLE name:  NEXUS_PROV_DEVICE_NAME_PREFIX + last 3 MAC bytes (hex)
//   e.g. "NexusHub_A1B2C3"
// QR on device label: nexus://provision?name=NexusHub_A1B2C3
//
// GATT Service UUID:  4fafc201-1fb5-459e-8fcc-c5c9c331914b
// Credential char:    beb5483e-36e1-4688-b7f5-ea07361b26a8  (Write JSON creds)
// Status char:        beb5483f-36e1-4688-b7f5-ea07361b26a8  (Read + Notify)
#define NEXUS_PROV_DEVICE_NAME_PREFIX  "NexusHub_"
