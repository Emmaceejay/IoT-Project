#pragma once

#include "esp_err.h"

/**
 * dsgv_gateway.h — DSGV Hub device-config gateway fetch.
 *
 * Fetches the device's MQTT broker config from the DSGV Hub gateway
 * (cloudflare_gateway/ — see that directory for the backend) over HTTPS
 * using the device's auth_token for authentication.
 * On success, the fetched config is written to NVS (mqtt_cfg namespace) so
 * dsgv_mqtt.c picks it up on the next connection attempt.
 *
 * Call dsgv_gateway_fetch_config() once after WiFi connects, before
 * starting the MQTT client.
 *
 * On any error (network unreachable, invalid token, bad JSON) the function
 * returns ESP_FAIL and the existing NVS config (if any) is used unchanged —
 * there is no compile-time broker credential fallback, by design (see
 * dsgv_config.h).
 */

/**
 * Fetch broker config from the gateway and write it to NVS.
 *
 * @return ESP_OK   Config fetched and persisted to NVS.
 *         ESP_FAIL Fetch failed — caller should use cached NVS config.
 */
esp_err_t dsgv_gateway_fetch_config(void);
