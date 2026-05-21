#pragma once

/**
 * DSGV_device_config.h — Runtime device configuration
 *
 * Stores device type, capability list, relay count, and all GPIO/LEDC pin
 * assignments in NVS so the same firmware binary can be used for any product
 * SKU. The app sends a config JSON during BLE provisioning; the firmware saves
 * it here. On every subsequent boot this config is loaded before GPIO init.
 *
 * Falls back transparently to compile-time defaults from DSGV_config.h when
 * no NVS config exists (fresh flash or after factory reset).
 */

#include <stdint.h>
#include "esp_err.h"
#include "driver/gpio.h"
#include "dsgv_config.h"

#define DSGV_MAX_RELAY_COUNT  4
#define DSGV_CAPS_BUF_LEN     192
#define DSGV_TYPE_BUF_LEN     24

typedef struct {
    // Human-readable type prefix used in auto-generated device name.
    // e.g. "Switch" → name "Switch_A1B2C3"
    char device_type[DSGV_TYPE_BUF_LEN];

    // JSON array string of capabilities sent in MQTT announce.
    // e.g. "[\"relay\",\"dimmer\"]"
    char capabilities[DSGV_CAPS_BUF_LEN];

    // How many physical relay outputs this unit has (1-4).
    uint8_t relay_count;

    // GPIO pin for each relay gang. relay_pins[0] is gang 1 ("power"),
    // relay_pins[1] is gang 2 ("power_2"), and so on.
    // Unused entries (index >= relay_count) are ignored.
    gpio_num_t relay_pins[DSGV_MAX_RELAY_COUNT];

    // LEDC PWM output pins (used only when the matching capability is set)
    gpio_num_t dimmer_pin;
    gpio_num_t warm_pin;
    gpio_num_t cool_pin;
    gpio_num_t red_pin;
    gpio_num_t green_pin;
    gpio_num_t blue_pin;

    // 32-char hex auth token (128-bit entropy) generated at first boot and
    // stored in NVS. Exchanged over BLE during provisioning and stored in the
    // app. Any MQTT broker-change command must carry this token.
    // Never transmitted over MQTT — BLE only, at provisioning time.
    char auth_token[33];
} DSGV_device_config_t;

// Global instance — populated by DSGV_device_config_load().
// All modules read from this instead of the compile-time macros directly.
extern DSGV_device_config_t g_device_config;

// Populate g_device_config from NVS, falling back to DSGV_config.h defaults.
// Must be called after nvs_flash_init() and before DSGV_gpio_init().
esp_err_t DSGV_device_config_load(void);

// Persist a config struct to NVS so it survives reboot.
// Called by DSGV_provisioning.c when the app sends a config payload.
esp_err_t DSGV_device_config_save(const DSGV_device_config_t *cfg);
