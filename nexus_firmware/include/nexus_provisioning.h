#pragma once
#include "esp_err.h"

/**
 * nexus_provisioning.h
 * BLE GATT-based Wi-Fi provisioning for Nexus Hub firmware.
 *
 * Provisioning flow (triggered on first boot or after factory reset):
 *
 *   1. Firmware calls nexus_provisioning_start() when no Wi-Fi
 *      credentials are found in NVS.
 *
 *   2. Device starts a NimBLE GATT server advertising as "NexusHub_XXXXXX"
 *      (last 3 bytes of the BT MAC address in hex).
 *
 *   3. User scans a QR code on the device label or serial output:
 *        nexus://provision?name=NexusHub_XXXXXX
 *
 *   4. Nexus Hub App (Flutter) connects via BLE, discovers the provisioning
 *      service, and writes Wi-Fi credentials as JSON to the credential
 *      characteristic:
 *        {"ssid":"YourNetwork","password":"YourPass"}
 *
 *   5. Firmware saves credentials to NVS and reboots.
 *      On next boot, wifi_manager_connect() finds the saved credentials
 *      and connects normally — provisioning is complete.
 *
 * BLE Service UUID:    4fafc201-1fb5-459e-8fcc-c5c9c331914b
 * Credential char:     beb5483e-36e1-4688-b7f5-ea07361b26a8  (Write)
 * Status char:         beb5483f-36e1-4688-b7f5-ea07361b26a8  (Read + Notify)
 *   Status values: "idle" | "connecting" | "success" | "failed:<reason>"
 */

/**
 * @brief Start BLE provisioning mode.
 *
 * Initialises the NimBLE stack, registers the custom GATT service, and
 * begins advertising. Returns immediately — provisioning runs in a
 * background FreeRTOS task managed by the NimBLE port.
 *
 * The device reboots automatically once valid Wi-Fi credentials are
 * written to the credential characteristic. main() should call
 * vTaskSuspend(NULL) after this function so the main task does not exit.
 *
 * @return ESP_OK if BLE stack initialised successfully,
 *         ESP_FAIL on BLE initialisation error.
 */
esp_err_t nexus_provisioning_start(void);
