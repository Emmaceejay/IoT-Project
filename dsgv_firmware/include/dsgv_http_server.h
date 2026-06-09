#pragma once

#include "esp_err.h"

/**
 * DSGV_http_server.h
 *
 * Local HTTP transport layer — Tasmota-compatible REST API.
 * Activated when the DSGV Hub App is on the same Wi-Fi as the device.
 *
 * Routes:
 *   GET  /api/status     → Full JSON state snapshot
 *   POST /api/cmd        → {"capability": "power", "value": true}
 *   GET  /cm?cmnd=<cmd>  → Tasmota compatibility (Power ON/OFF, Dimmer N, CT N)
 */

/**
 * @brief Start the HTTP server. Call after Wi-Fi is connected.
 *        The server listens on HTTP_SERVER_PORT (default: 80).
 */
esp_err_t DSGV_http_server_start(void);

/**
 * @brief Stop and free the HTTP server (e.g., before deep sleep or OTA).
 */
void DSGV_http_server_stop(void);

/**
 * @brief Notify the HTTP layer whether the device is in softAP provisioning mode.
 *        When true, all endpoints except GET /provision/ping require the header
 *        "X-DSGV-Client: DSGVHub-App" — browsers get 403, the app gets through.
 */
void DSGV_http_set_ap_mode(bool active);
