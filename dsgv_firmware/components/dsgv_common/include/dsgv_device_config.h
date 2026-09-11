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

    // GPIO input pin for the latching wall switch of each relay gang.
    // On every state change (either edge) the corresponding relay toggles.
    // The relay state is independent of switch position — only edges matter.
    // Set to GPIO_NUM_NC (-1) to disable the wall switch for that gang.
    gpio_num_t switch_pins[DSGV_MAX_RELAY_COUNT];

    // LEDC PWM output pins (used only when the matching capability is set)
    gpio_num_t dimmer_pin;
    gpio_num_t warm_pin;
    gpio_num_t cool_pin;
    gpio_num_t red_pin;
    gpio_num_t green_pin;
    gpio_num_t blue_pin;

    // Fixed-function pins. These were compile-time macros until the web
    // flasher needed them selectable per board: a user picking "motion sensor
    // on GPIO 7" cannot rebuild firmware to say so.
    // Any of these may be GPIO_NUM_NC (-1) to mean "not fitted".
    gpio_num_t status_led_pin;   // lit in parallel with relay gang 1
    gpio_num_t motion_pin;       // PIR input, HIGH-active
    gpio_num_t contact_pin;      // reed switch input, LOW-active = closed
    gpio_num_t button_pin;       // factory-reset button

    // NTC thermistor input. Must be an ADC1-capable pin on this chip — the
    // channel is derived via DSGV_pin_to_adc1_channel() rather than stored,
    // so the pin and channel can never disagree.
    gpio_num_t adc_temp_pin;

    // 32-char hex auth token (128-bit entropy) generated at first boot and
    // stored in NVS. Exchanged over BLE during provisioning and stored in the
    // app. Any MQTT broker-change command must carry this token.
    // Never transmitted over MQTT — BLE only, at provisioning time.
    char auth_token[33];
} DSGV_device_config_t;

/**
 * Capability flags, derived from the capabilities string.
 *
 * The string itself stays the stored form (it is echoed verbatim in the MQTT
 * announce and the mDNS TXT record). This mask is the queryable form, so init
 * code can ask "does this device do RGB" without re-scanning a string.
 *
 * Gating matters for the universal binary: without it every device configures
 * all six PWM channels and both sensor ISRs, so a unit provisioned as a plain
 * 1-gang switch would still claim the dimmer, CCT and RGB pins — pins the user
 * may well have assigned to something else.
 */
typedef enum {
    DSGV_CAP_RELAY       = 1u << 0,
    DSGV_CAP_BRIGHTNESS  = 1u << 1,   // LEDC dimmer channel
    DSGV_CAP_COLOR_TEMP  = 1u << 2,   // LEDC warm + cool channels
    DSGV_CAP_RGB         = 1u << 3,   // LEDC red + green + blue channels
    DSGV_CAP_TEMPERATURE = 1u << 4,   // SOC sensor and/or NTC ADC
    DSGV_CAP_HUMIDITY    = 1u << 5,
    DSGV_CAP_MOTION      = 1u << 6,   // PIR input + ISR
    DSGV_CAP_CONTACT     = 1u << 7,   // reed input + ISR
    DSGV_CAP_HVAC_MODE   = 1u << 8,
} DSGV_cap_t;

/** @brief True if the current config declares @p cap. */
bool DSGV_has_cap(DSGV_cap_t cap);

/**
 * @brief Recompute the capability mask from g_device_config.capabilities.
 *        Called automatically by load and save; exposed for tests.
 */
void DSGV_capabilities_refresh(void);

// Global instance — populated by DSGV_device_config_load().
// All modules read from this instead of the compile-time macros directly.
extern DSGV_device_config_t g_device_config;

// Populate g_device_config from NVS, falling back to DSGV_config.h defaults.
// Must be called after nvs_flash_init() and before DSGV_gpio_init().
esp_err_t DSGV_device_config_load(void);

// Persist a config struct to NVS so it survives reboot.
// Called by DSGV_provisioning.c when the app sends a config payload.
esp_err_t DSGV_device_config_save(const DSGV_device_config_t *cfg);
