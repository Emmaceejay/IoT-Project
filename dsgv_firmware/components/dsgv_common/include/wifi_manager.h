#pragma once
#include "esp_err.h"

/**
 * wifi_manager.h
 * Handles Wi-Fi credential storage in NVS and connection lifecycle.
 * Credentials are received via Matter Commissioning (BLE handshake)
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
 *        Called by Matter commissioning callback after BLE handshake.
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
