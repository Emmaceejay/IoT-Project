/**
 * DSGV_device_config.c — NVS-backed runtime device configuration
 *
 * Loads per-SKU settings (device type, capabilities, relay count/pins, PWM pins)
 * from NVS namespace "DSGV_cfg". If no NVS config is present (fresh flash or
 * after factory reset), falls back transparently to the compile-time defaults
 * in DSGV_config.h.
 *
 * DSGV_provisioning.c calls DSGV_device_config_save() when the app writes a
 * config payload during BLE provisioning, so the same firmware binary adapts to
 * any hardware SKU at first boot.
 */

#include "dsgv_device_config.h"
#include "dsgv_pin_rules.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "esp_log.h"
#include "esp_random.h"
#include <string.h>
#include <stdio.h>
// PRIX32 etc. uint32_t is 'unsigned long' on RISC-V targets (C3/C6) but
// 'unsigned int' on Xtensa, so plain %X is only correct on some chips.
#include <inttypes.h>

static const char *TAG    = "DSGV_cfg";
static const char *NVS_NS = "DSGV_cfg";

DSGV_device_config_t g_device_config;

// ── Capability mask ───────────────────────────────────────────────────────────
// Derived from g_device_config.capabilities, never stored separately: the
// string remains the single persisted form so the MQTT announce and mDNS TXT
// record keep echoing exactly what was provisioned.

static uint32_t s_cap_mask = 0;

// Matches a whole quoted token, so "color_temp" cannot satisfy a search for
// "temp" and "relay" legitimately matches "relay_2" only because the caller
// asks for "relay" — gang count comes from relay_count, not the string.
static bool cap_present(const char *caps, const char *name) {
    char needle[40];
    snprintf(needle, sizeof(needle), "\"%s\"", name);
    return strstr(caps, needle) != NULL;
}

void DSGV_capabilities_refresh(void) {
    const char *c = g_device_config.capabilities;
    uint32_t m = 0;
    if (cap_present(c, "relay"))       m |= DSGV_CAP_RELAY;
    if (cap_present(c, "brightness"))  m |= DSGV_CAP_BRIGHTNESS;
    if (cap_present(c, "color_temp"))  m |= DSGV_CAP_COLOR_TEMP;
    if (cap_present(c, "rgb"))         m |= DSGV_CAP_RGB;
    if (cap_present(c, "temperature")) m |= DSGV_CAP_TEMPERATURE;
    if (cap_present(c, "humidity"))    m |= DSGV_CAP_HUMIDITY;
    if (cap_present(c, "motion"))      m |= DSGV_CAP_MOTION;
    if (cap_present(c, "contact"))     m |= DSGV_CAP_CONTACT;
    if (cap_present(c, "hvac_mode"))   m |= DSGV_CAP_HVAC_MODE;
    s_cap_mask = m;
}

bool DSGV_has_cap(DSGV_cap_t cap) {
    return (s_cap_mask & (uint32_t)cap) != 0;
}

// Generates a 32-char uppercase hex token from 16 bytes of hardware entropy.
static void _gen_token(char out[33]) {
    for (int i = 0; i < 4; i++) {
        uint32_t r = esp_random();
        snprintf(out + i * 8, 9, "%08" PRIX32, r);
    }
}

esp_err_t DSGV_device_config_load(void) {
    // ── Step 1: seed with compile-time defaults (from Kconfig / sdkconfig) ──────
    strlcpy(g_device_config.device_type, CONFIG_DSGV_DEVICE_TYPE,
            sizeof(g_device_config.device_type));
    strlcpy(g_device_config.capabilities, CONFIG_DSGV_DEVICE_CAPABILITIES,
            sizeof(g_device_config.capabilities));
    g_device_config.relay_count = CONFIG_DSGV_RELAY_COUNT;

    // DSGV_RELAY_PINS_ALL always has DSGV_MAX_RELAY_COUNT (4) entries per chip
    static const gpio_num_t default_relay_pins[DSGV_MAX_RELAY_COUNT] =
        DSGV_RELAY_PINS_ALL;
    for (int i = 0; i < DSGV_MAX_RELAY_COUNT; i++) {
        g_device_config.relay_pins[i] = default_relay_pins[i];
    }

    static const gpio_num_t default_switch_pins[DSGV_MAX_RELAY_COUNT] =
        GPIO_WALL_SWITCH_PINS_ALL;
    for (int i = 0; i < DSGV_MAX_RELAY_COUNT; i++) {
        g_device_config.switch_pins[i] = default_switch_pins[i];
    }

    g_device_config.dimmer_pin     = GPIO_DIMMER_PIN;
    g_device_config.warm_pin       = GPIO_WARM_PIN;
    g_device_config.cool_pin       = GPIO_COOL_PIN;
    g_device_config.red_pin        = GPIO_RED_PIN;
    g_device_config.green_pin      = GPIO_GREEN_PIN;
    g_device_config.blue_pin       = GPIO_BLUE_PIN;
    g_device_config.status_led_pin = GPIO_STATUS_LED_PIN;
    g_device_config.motion_pin     = GPIO_MOTION_PIN;
    g_device_config.contact_pin    = GPIO_CONTACT_PIN;
    g_device_config.button_pin     = GPIO_BUTTON_PIN;
    g_device_config.adc_temp_pin   = GPIO_ADC_TEMP_PIN;
    g_device_config.auth_token[0]  = '\0';

    // ── Step 2: overlay with NVS values (if any) ──────────────────────────────
    bool need_new_token = false;
    nvs_handle_t nvs;
    esp_err_t ret = nvs_open(NVS_NS, NVS_READONLY, &nvs);
    if (ret != ESP_OK) {
        ESP_LOGI(TAG, "No NVS device config — using compile-time defaults "
                      "(type=%s caps=%s relays=%u)",
                 g_device_config.device_type,
                 g_device_config.capabilities,
                 g_device_config.relay_count);
        need_new_token = true;
    } else {
        size_t len;

        len = sizeof(g_device_config.device_type);
        nvs_get_str(nvs, "dev_type", g_device_config.device_type, &len);

        len = sizeof(g_device_config.capabilities);
        nvs_get_str(nvs, "caps", g_device_config.capabilities, &len);

        uint8_t relay_count = 0;
        if (nvs_get_u8(nvs, "relay_cnt", &relay_count) == ESP_OK) {
            if (relay_count <= DSGV_MAX_RELAY_COUNT) {
                g_device_config.relay_count = relay_count;
            }
        }

        size_t pins_len = sizeof(g_device_config.relay_pins);
        nvs_get_blob(nvs, "relay_pins", g_device_config.relay_pins, &pins_len);

        // Wall switch pins. Only applied if the stored blob is exactly the
        // expected size — a short read would leave later entries holding the
        // compile-time defaults while earlier ones came from NVS, which is a
        // confusing half-applied state.
        size_t sw_len = sizeof(g_device_config.switch_pins);
        if (nvs_get_blob(nvs, "sw_pins", g_device_config.switch_pins, &sw_len) == ESP_OK &&
            sw_len != sizeof(g_device_config.switch_pins)) {
            ESP_LOGW(TAG, "sw_pins blob is %u bytes, expected %u — ignoring",
                     (unsigned)sw_len, (unsigned)sizeof(g_device_config.switch_pins));
            for (int i = 0; i < DSGV_MAX_RELAY_COUNT; i++) {
                g_device_config.switch_pins[i] = default_switch_pins[i];
            }
        }

        int32_t pin;
        if (nvs_get_i32(nvs, "dim_pin",     &pin) == ESP_OK) g_device_config.dimmer_pin     = (gpio_num_t)pin;
        if (nvs_get_i32(nvs, "warm_pin",    &pin) == ESP_OK) g_device_config.warm_pin       = (gpio_num_t)pin;
        if (nvs_get_i32(nvs, "cool_pin",    &pin) == ESP_OK) g_device_config.cool_pin       = (gpio_num_t)pin;
        if (nvs_get_i32(nvs, "red_pin",     &pin) == ESP_OK) g_device_config.red_pin        = (gpio_num_t)pin;
        if (nvs_get_i32(nvs, "green_pin",   &pin) == ESP_OK) g_device_config.green_pin      = (gpio_num_t)pin;
        if (nvs_get_i32(nvs, "blue_pin",    &pin) == ESP_OK) g_device_config.blue_pin       = (gpio_num_t)pin;
        if (nvs_get_i32(nvs, "led_pin",     &pin) == ESP_OK) g_device_config.status_led_pin = (gpio_num_t)pin;
        if (nvs_get_i32(nvs, "motion_pin",  &pin) == ESP_OK) g_device_config.motion_pin     = (gpio_num_t)pin;
        if (nvs_get_i32(nvs, "contact_pin", &pin) == ESP_OK) g_device_config.contact_pin    = (gpio_num_t)pin;
        if (nvs_get_i32(nvs, "button_pin",  &pin) == ESP_OK) g_device_config.button_pin     = (gpio_num_t)pin;
        if (nvs_get_i32(nvs, "adc_pin",     &pin) == ESP_OK) g_device_config.adc_temp_pin   = (gpio_num_t)pin;

        len = sizeof(g_device_config.auth_token);
        if (nvs_get_str(nvs, "auth_tok", g_device_config.auth_token, &len) != ESP_OK) {
            need_new_token = true;
        }

        nvs_close(nvs);

        // Guard against corrupt or mistyped pin numbers arriving from NVS.
        // DSGV_pin_check() is chip-aware: the old flat "0 <= pin < GPIO_NUM_MAX"
        // test accepted the SPI flash pins (which hang the chip on the next
        // flash access) and ESP32's input-only 34-39 as relay outputs (which
        // silently never actuate).
        //
        // Validate the whole relay_pins array, not just the first relay_count
        // entries: a later config that raises relay_count without rewriting the
        // blob would otherwise promote unvalidated garbage into use.
        for (int i = 0; i < DSGV_MAX_RELAY_COUNT; i++) {
            DSGV_pin_status_t st =
                DSGV_pin_check(g_device_config.relay_pins[i], /*need_output=*/true);
            if (st != DSGV_PIN_OK && st != DSGV_PIN_DISABLED) {
                ESP_LOGW(TAG, "relay_pins[%d]=%d rejected (%s) — reverting to default %d",
                         i, (int)g_device_config.relay_pins[i],
                         DSGV_pin_status_str(st), (int)default_relay_pins[i]);
                g_device_config.relay_pins[i] = default_relay_pins[i];
            }
        }

        // PWM pins are outputs. GPIO_NUM_NC (-1) is preserved rather than
        // overwritten: the header documents it as "feature not fitted", and the
        // old guard silently replaced it with the default, making it impossible
        // to actually disable a channel.
#define _GUARD_PIN(pin, def) do { \
    DSGV_pin_status_t _st = DSGV_pin_check((pin), /*need_output=*/true); \
    if (_st != DSGV_PIN_OK && _st != DSGV_PIN_DISABLED) { \
        ESP_LOGW(TAG, #pin "=%d rejected (%s) — reverting to default %d", \
                 (int)(pin), DSGV_pin_status_str(_st), (int)(def)); \
        (pin) = (def); \
    } \
} while (0)
        _GUARD_PIN(g_device_config.dimmer_pin, GPIO_DIMMER_PIN);
        _GUARD_PIN(g_device_config.warm_pin,   GPIO_WARM_PIN);
        _GUARD_PIN(g_device_config.cool_pin,   GPIO_COOL_PIN);
        _GUARD_PIN(g_device_config.red_pin,    GPIO_RED_PIN);
        _GUARD_PIN(g_device_config.green_pin,  GPIO_GREEN_PIN);
        _GUARD_PIN(g_device_config.blue_pin,   GPIO_BLUE_PIN);
        _GUARD_PIN(g_device_config.status_led_pin, GPIO_STATUS_LED_PIN);
#undef _GUARD_PIN

        // Inputs: validated with need_output=false so ESP32's input-only
        // 34-39 stay legal here, unlike for relays and PWM.
#define _GUARD_IN(pin, def) do { \
    DSGV_pin_status_t _st = DSGV_pin_check((pin), /*need_output=*/false); \
    if (_st != DSGV_PIN_OK && _st != DSGV_PIN_DISABLED) { \
        ESP_LOGW(TAG, #pin "=%d rejected (%s) — reverting to default %d", \
                 (int)(pin), DSGV_pin_status_str(_st), (int)(def)); \
        (pin) = (def); \
    } \
} while (0)
        _GUARD_IN(g_device_config.motion_pin,  GPIO_MOTION_PIN);
        _GUARD_IN(g_device_config.contact_pin, GPIO_CONTACT_PIN);
        _GUARD_IN(g_device_config.button_pin,  GPIO_BUTTON_PIN);
#undef _GUARD_IN

        // The ADC pin has a stricter rule than the other inputs: it must be
        // wired to ADC1 on this chip. A pin that is a perfectly good digital
        // input is still useless for the thermistor.
        if (g_device_config.adc_temp_pin != GPIO_NUM_NC &&
            DSGV_pin_to_adc1_channel(g_device_config.adc_temp_pin) < 0) {
            ESP_LOGW(TAG, "adc_temp_pin=%d has no ADC1 channel on this chip — "
                     "reverting to default %d",
                     (int)g_device_config.adc_temp_pin, (int)GPIO_ADC_TEMP_PIN);
            g_device_config.adc_temp_pin = GPIO_ADC_TEMP_PIN;
        }

#define _GUARD_IN(pin, def) do { \
    DSGV_pin_status_t _st = DSGV_pin_check((pin), /*need_output=*/false); \
    if (_st != DSGV_PIN_OK && _st != DSGV_PIN_DISABLED) { \
        ESP_LOGW(TAG, #pin "=%d rejected (%s) — reverting to default %d", \
                 (int)(pin), DSGV_pin_status_str(_st), (int)(def)); \
        (pin) = (def); \
    } \
} while (0)
        for (int i = 0; i < DSGV_MAX_RELAY_COUNT; i++) {
            _GUARD_IN(g_device_config.switch_pins[i], default_switch_pins[i]);
        }
#undef _GUARD_IN

        ESP_LOGI(TAG, "NVS config loaded: type=%s caps=%s relay_cnt=%u",
                 g_device_config.device_type,
                 g_device_config.capabilities,
                 g_device_config.relay_count);
    }

    // ── Step 3: Generate auth token if not already in NVS ─────────────────────
    // Happens on first boot after a fresh flash or factory reset.
    if (need_new_token) {
        _gen_token(g_device_config.auth_token);
        nvs_handle_t nvs_rw;
        if (nvs_open(NVS_NS, NVS_READWRITE, &nvs_rw) == ESP_OK) {
            nvs_set_str(nvs_rw, "auth_tok", g_device_config.auth_token);
            nvs_commit(nvs_rw);
            nvs_close(nvs_rw);
        }
        ESP_LOGI(TAG, "Auth token generated and persisted to NVS (first boot)");
    }

    DSGV_capabilities_refresh();
    return ESP_OK;
}

esp_err_t DSGV_device_config_save(const DSGV_device_config_t *cfg) {
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
    nvs_set_blob(nvs, "sw_pins",    cfg->switch_pins, sizeof(cfg->switch_pins));
    nvs_set_i32(nvs, "dim_pin",     (int32_t)cfg->dimmer_pin);
    nvs_set_i32(nvs, "warm_pin",    (int32_t)cfg->warm_pin);
    nvs_set_i32(nvs, "cool_pin",    (int32_t)cfg->cool_pin);
    nvs_set_i32(nvs, "red_pin",     (int32_t)cfg->red_pin);
    nvs_set_i32(nvs, "green_pin",   (int32_t)cfg->green_pin);
    nvs_set_i32(nvs, "blue_pin",    (int32_t)cfg->blue_pin);
    nvs_set_i32(nvs, "led_pin",     (int32_t)cfg->status_led_pin);
    nvs_set_i32(nvs, "motion_pin",  (int32_t)cfg->motion_pin);
    nvs_set_i32(nvs, "contact_pin", (int32_t)cfg->contact_pin);
    nvs_set_i32(nvs, "button_pin",  (int32_t)cfg->button_pin);
    nvs_set_i32(nvs, "adc_pin",     (int32_t)cfg->adc_temp_pin);
    // Preserve the auth_token already in NVS — do not overwrite with empty string
    if (cfg->auth_token[0] != '\0') {
        nvs_set_str(nvs, "auth_tok", cfg->auth_token);
    }

    ret = nvs_commit(nvs);
    nvs_close(nvs);

    if (ret == ESP_OK) {
        g_device_config = *cfg;
        DSGV_capabilities_refresh();
        ESP_LOGI(TAG, "NVS config saved: type=%s caps=%s relay_cnt=%u",
                 cfg->device_type, cfg->capabilities, cfg->relay_count);
    } else {
        ESP_LOGE(TAG, "nvs_commit failed: %s", esp_err_to_name(ret));
    }
    return ret;
}
