#pragma once

#include "esp_err.h"

/**
 * dsgv_firebase.h — Firebase config fetch for DSGV Hub firmware.
 *
 * Fetches the device's MQTT broker config from the Firebase Cloud Function
 * over HTTPS using the device's auth_token for authentication.
 * On success, the fetched config is written to NVS (mqtt_cfg namespace) so
 * dsgv_mqtt.c picks it up on the next connection attempt.
 *
 * Call dsgv_firebase_fetch_config() once after WiFi connects, before
 * starting the MQTT client.
 *
 * On any error (network unreachable, invalid token, bad JSON) the function
 * returns ESP_FAIL and the existing NVS config (or compile-time factory
 * defaults) is used unchanged — the device always boots with a valid config.
 */

/**
 * Fetch broker config from Firebase and write to NVS.
 *
 * @return ESP_OK   Config fetched and persisted to NVS.
 *         ESP_FAIL Fetch failed — caller should use cached NVS config.
 */
esp_err_t dsgv_firebase_fetch_config(void);
