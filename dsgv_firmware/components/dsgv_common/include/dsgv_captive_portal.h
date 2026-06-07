#pragma once

#include "esp_err.h"

/**
 * dsgv_captive_portal.h
 *
 * Minimal HTTP server that runs on the device's setup Access Point
 * (started by wifi_manager_start_ap()).  Serves an HTML credential form at
 * 192.168.4.1 and handles OS-level captive portal detection probes so the
 * phone's browser opens automatically on Android, iOS, Windows, and Linux.
 *
 * Flow:
 *   1. wifi_manager_start_ap()      — device becomes "DSGV_Setup_XXXXXX" AP
 *   2. DSGV_captive_portal_start()  — start this HTTP server
 *   3. User connects phone to AP; browser opens the setup page
 *   4. User submits SSID + password → server saves creds + reboots device
 */

/**
 * @brief Start the captive portal HTTP server on port 80.
 *        Must be called after wifi_manager_start_ap().
 * @return ESP_OK on success.
 */
esp_err_t DSGV_captive_portal_start(void);
