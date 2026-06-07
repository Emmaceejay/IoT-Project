#pragma once
#include "esp_err.h"
#include <stdbool.h>

/**
 * wifi_manager.h
 * Handles Wi-Fi credential storage in NVS and connection lifecycle.
 * Credentials are received via BLE provisioning handshake
 * and persisted to NVS so they survive device reboots.
 */

/**
 * @brief Attempt to connect to Wi-Fi using credentials stored in NVS.
 *        If no credentials found, device stays in provisioning mode.
 * @return ESP_OK on connected, ESP_ERR_NOT_FOUND if no saved credentials.
 */
esp_err_t wifi_manager_connect(void);

/**
 * @brief Save new Wi-Fi SSID and password into NVS.
 *        Called by BLE provisioning callback after handshake.
 */
esp_err_t wifi_manager_save_credentials(const char *ssid, const char *password);

/**
 * @brief Erase stored credentials and reboot into provisioning mode.
 *        Triggered by long-press of the physical factory-reset button.
 */
esp_err_t wifi_manager_factory_reset(void);

/**
 * @brief Returns true if device currently has an active Wi-Fi connection.
 */
bool wifi_manager_is_connected(void);

/**
 * @brief Stop automatic reconnection attempts and disconnect from Wi-Fi.
 *        Call before entering BLE provisioning or AP setup mode so the
 *        reconnect loop does not interfere with BLE/WiFi radio coexistence.
 *        Safe to call even if Wi-Fi was never connected.
 */
void wifi_manager_stop_reconnect(void);

/**
 * @brief Stop STA mode and start a setup Access Point named "DSGV_Setup_XXXXXX"
 *        (last 3 bytes of SoftAP MAC).  The AP is open (no password) so any
 *        nearby phone can connect.  Call DSGV_captive_portal_start() after this
 *        to serve the credential entry page at 192.168.4.1.
 * @return ESP_OK on success.
 */
esp_err_t wifi_manager_start_ap(void);

/**
 * @brief Scan for nearby Wi-Fi networks and serialise results as a JSON array.
 *        Initialises the Wi-Fi driver in STA mode if it has not been started yet.
 *        Intended for use during BLE provisioning so the app can present a
 *        network picker instead of requiring the user to type an SSID manually.
 *
 *        Output format (sorted by RSSI, hidden networks omitted):
 *          [{"ssid":"MyNetwork","rssi":-45},{"ssid":"Other","rssi":-72},...]
 *
 * @param json_out  Caller-supplied buffer for the JSON array.
 * @param json_len  Size of json_out in bytes (recommend >= 1024).
 * @return ESP_OK on success.  json_out is always a valid JSON array on return.
 */
esp_err_t wifi_manager_scan_networks(char *json_out, size_t json_len);
