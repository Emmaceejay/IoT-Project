/**
 * nexus_device_config.c — NVS-backed runtime device configuration
 *
 * Loads per-SKU settings (device type, capabilities, relay count/pins, PWM pins)
 * from NVS namespace "nexus_cfg". If no NVS config is present (fresh flash or
 * after factory reset), falls back transparently to the compile-time defaults
 * in nexus_config.h.
 *
 * nexus_provisioning.c calls nexus_device_config_save() when the app writes a
 * config payload during BLE provisioning, so the same firmware binary adapts to
 * any hardware SKU at first boot.
 */

#include "nexus_device_config.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "esp_log.h"
#include <string.h>

static const char *TAG    = "nexus_cfg";
static const char *NVS_NS = "nexus_cfg";

nexus_device_config_t g_device_config;

esp_err_t nexus_device_config_load(void) {
    // ── Step 1: seed with compile-time defaults ───────────────────────────────
    strlcpy(g_device_config.device_type, NEXUS_DEVICE_TYPE,
            sizeof(g_device_config.device_type));
    strlcpy(g_device_config.capabilities, NEXUS_DEVICE_CAPABILITIES,
            sizeof(g_device_config.capabilities));
    g_device_config.relay_count = NEXUS_RELAY_COUNT;

    // NEXUS_RELAY_PINS_ALL always has NEXUS_MAX_RELAY_COUNT (4) entries per chip
    static const gpio_num_t default_relay_pins[NEXUS_MAX_RELAY_COUNT] =
        NEXUS_RELAY_PINS_ALL;
    for (int i = 0; i < NEXUS_MAX_RELAY_COUNT; i++) {
        g_device_config.relay_pins[i] = default_relay_pins[i];
    }

    g_device_config.dimmer_pin = GPIO_DIMMER_PIN;
    g_device_config.warm_pin   = GPIO_WARM_PIN;
    g_device_config.cool_pin   = GPIO_COOL_PIN;
    g_device_config.red_pin    = GPIO_RED_PIN;
    g_device_config.green_pin  = GPIO_GREEN_PIN;
    g_device_config.blue_pin   = GPIO_BLUE_PIN;

    // ── Step 2: overlay with NVS values (if any) ──────────────────────────────
    nvs_handle_t nvs;
    esp_err_t ret = nvs_open(NVS_NS, NVS_READONLY, &nvs);
    if (ret != ESP_OK) {
        ESP_LOGI(TAG, "No NVS device config — using compile-time defaults "
                      "(type=%s caps=%s relays=%u)",
                 g_device_config.device_type,
                 g_device_config.capabilities,
                 g_device_config.relay_count);
        return ESP_OK;
    }

    size_t len;

    len = sizeof(g_device_config.device_type);
    nvs_get_str(nvs, "dev_type", g_device_config.device_type, &len);

    len = sizeof(g_device_config.capabilities);
    nvs_get_str(nvs, "caps", g_device_config.capabilities, &len);

    uint8_t relay_count = 0;
    if (nvs_get_u8(nvs, "relay_cnt", &relay_count) == ESP_OK) {
        if (relay_count <= NEXUS_MAX_RELAY_COUNT) {
            g_device_config.relay_count = relay_count;
        }
    }

    size_t pins_len = sizeof(g_device_config.relay_pins);
    nvs_get_blob(nvs, "relay_pins", g_device_config.relay_pins, &pins_len);

    int32_t pin;
    if (nvs_get_i32(nvs, "dim_pin",   &pin) == ESP_OK) g_device_config.dimmer_pin = (gpio_num_t)pin;
    if (nvs_get_i32(nvs, "warm_pin",  &pin) == ESP_OK) g_device_config.warm_pin   = (gpio_num_t)pin;
    if (nvs_get_i32(nvs, "cool_pin",  &pin) == ESP_OK) g_device_config.cool_pin   = (gpio_num_t)pin;
    if (nvs_get_i32(nvs, "red_pin",   &pin) == ESP_OK) g_device_config.red_pin    = (gpio_num_t)pin;
    if (nvs_get_i32(nvs, "green_pin", &pin) == ESP_OK) g_device_config.green_pin  = (gpio_num_t)pin;
    if (nvs_get_i32(nvs, "blue_pin",  &pin) == ESP_OK) g_device_config.blue_pin   = (gpio_num_t)pin;

    nvs_close(nvs);

    // Guard against corrupt NVS blobs delivering out-of-range pin numbers.
    // gpio_config() and ledc_channel_config() will hard-fault on invalid GPIOs.
    for (int i = 0; i < (int)g_device_config.relay_count; i++) {
        if ((int)g_device_config.relay_pins[i] < 0 ||
            (int)g_device_config.relay_pins[i] >= GPIO_NUM_MAX) {
            ESP_LOGW(TAG, "relay_pins[%d]=%d invalid — using compile-time default",
                     i, (int)g_device_config.relay_pins[i]);
            g_device_config.relay_pins[i] = default_relay_pins[i];
        }
    }
#define _GUARD_PIN(pin, def) do { \
    if ((int)(pin) < 0 || (int)(pin) >= GPIO_NUM_MAX) { \
        ESP_LOGW(TAG, #pin "=%d invalid — using compile-time default", (int)(pin)); \
        (pin) = (def); \
    } \
} while (0)
    _GUARD_PIN(g_device_config.dimmer_pin, GPIO_DIMMER_PIN);
    _GUARD_PIN(g_device_config.warm_pin,   GPIO_WARM_PIN);
    _GUARD_PIN(g_device_config.cool_pin,   GPIO_COOL_PIN);
    _GUARD_PIN(g_device_config.red_pin,    GPIO_RED_PIN);
    _GUARD_PIN(g_device_config.green_pin,  GPIO_GREEN_PIN);
    _GUARD_PIN(g_device_config.blue_pin,   GPIO_BLUE_PIN);
#undef _GUARD_PIN

    ESP_LOGI(TAG, "NVS config loaded: type=%s caps=%s relay_cnt=%u",
             g_device_config.device_type,
             g_device_config.capabilities,
             g_device_config.relay_count);
    return ESP_OK;
}

esp_err_t nexus_device_config_save(const nexus_device_config_t *cfg) {
    nvs_handle_t nvs;
    esp_err_t ret = nvs_open(NVS_NS, NVS_READWRITE, &nvs);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "nvs_open(RW) failed: %s", esp_err_to_name(ret));
        return ret;
    }

    nvs_set_str(nvs, "dev_type",   cfg->device_type);
    nvs_set_str(nvs, "caps",       cfg->capabilities);
    nvs_set_u8 (nvs, "relay_cnt",  cfg->relay_count);
    nvs_set_blob(nvs, "relay_pins", cfg->relay_pins, sizeof(cfg->relay_pins));
    nvs_set_i32(nvs, "dim_pin",   (int32_t)cfg->dimmer_pin);
    nvs_set_i32(nvs, "warm_pin",  (int32_t)cfg->warm_pin);
    nvs_set_i32(nvs, "cool_pin",  (int32_t)cfg->cool_pin);
    nvs_set_i32(nvs, "red_pin",   (int32_t)cfg->red_pin);
    nvs_set_i32(nvs, "green_pin", (int32_t)cfg->green_pin);
    nvs_set_i32(nvs, "blue_pin",  (int32_t)cfg->blue_pin);

    ret = nvs_commit(nvs);
    nvs_close(nvs);

    if (ret == ESP_OK) {
        g_device_config = *cfg;
        ESP_LOGI(TAG, "NVS config saved: type=%s caps=%s relay_cnt=%u",
                 cfg->device_type, cfg->capabilities, cfg->relay_count);
    } else {
        ESP_LOGE(TAG, "nvs_commit failed: %s", esp_err_to_name(ret));
    }
    return ret;
}
