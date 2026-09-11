#pragma once

#include "dsgv_device_config.h"
#include "cJSON.h"
#include <stdbool.h>

/**
 * dsgv_config_json.h — one JSON → device config mapping, shared by every
 * provisioning transport.
 *
 * BLE GATT and HTTP POST /provision previously each had their own copy of
 * this parsing. They drifted: the HTTP copy required relay_count >= 1 while
 * BLE accepted 0, which silently made WiFi provisioning unable to configure
 * any sensor SKU. Phase 2 adds a third transport (serial), so the duplication
 * is consolidated here before it can drift again.
 *
 * Accepted shape — every field optional:
 *
 *   {
 *     "device_type":  "Switch",
 *     "capabilities": ["relay", "relay_2"],
 *     "relay_count":  2,
 *     "pins": {
 *       "relay":      [2, 3],        // per gang, index 0 = gang 1
 *       "switch":     [9, 18],       // wall switch per gang
 *       "dimmer":     4,
 *       "warm":       5,
 *       "cool":       6,
 *       "red":        7,
 *       "green":      8,
 *       "blue":       10,
 *       "status_led": 8,
 *       "motion":     11,
 *       "contact":    20,
 *       "button":     9
 *     }
 *   }
 *
 * Any pin may be -1 (GPIO_NUM_NC) to mean "not fitted". Pins that fail
 * DSGV_pin_check() for this chip are logged and skipped, leaving the previous
 * value intact — a bad pin never lands in NVS and never reaches gpio_config().
 */

/**
 * @brief Apply recognised config fields from @p root onto @p cfg.
 * @return true if at least one field was applied, i.e. the caller should
 *         persist @p cfg with DSGV_device_config_save().
 */
bool DSGV_config_apply_json(DSGV_device_config_t *cfg, const cJSON *root);
