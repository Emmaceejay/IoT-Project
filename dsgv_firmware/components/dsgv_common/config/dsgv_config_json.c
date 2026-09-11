#include "dsgv_config_json.h"
#include "dsgv_pin_rules.h"
#include "esp_log.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>

static const char *TAG = "DSGV_cfgjson";

// ── Scalar pin fields ─────────────────────────────────────────────────────────
// offsetof keeps this a table rather than a dozen near-identical if-blocks,
// so adding a pin is one line and cannot be half-implemented.

typedef struct {
    const char *key;
    size_t      off;    // byte offset of the gpio_num_t within the config
    bool        out;    // true if the pin must be able to drive an output
} pin_field_t;

#define PF(k, member, o) { (k), offsetof(DSGV_device_config_t, member), (o) }

static const pin_field_t k_pin_fields[] = {
    PF("dimmer",     dimmer_pin,     true),
    PF("warm",       warm_pin,       true),
    PF("cool",       cool_pin,       true),
    PF("red",        red_pin,        true),
    PF("green",      green_pin,      true),
    PF("blue",       blue_pin,       true),
    PF("status_led", status_led_pin, true),
    PF("motion",     motion_pin,     false),
    PF("contact",    contact_pin,    false),
    PF("button",     button_pin,     false),
};

#undef PF

static gpio_num_t *pin_at(DSGV_device_config_t *cfg, size_t off) {
    return (gpio_num_t *)((char *)cfg + off);
}

// Validate and assign one pin. Returns true if the value was applied.
static bool apply_pin(const char *role, const cJSON *item,
                      gpio_num_t *dst, bool need_output) {
    if (!cJSON_IsNumber(item)) return false;

    int pin = (int)item->valuedouble;
    DSGV_pin_status_t st = DSGV_pin_check(pin, need_output);
    if (st != DSGV_PIN_OK && st != DSGV_PIN_DISABLED) {
        ESP_LOGW(TAG, "pin '%s'=%d rejected: %s (keeping %d)",
                 role, pin, DSGV_pin_status_str(st), (int)*dst);
        return false;
    }
    if (DSGV_pin_is_console(pin)) {
        ESP_LOGW(TAG, "pin '%s'=%d is the UART0 console — serial logging and "
                 "serial provisioning will stop working on this device",
                 role, pin);
    } else if (DSGV_pin_is_strapping(pin)) {
        ESP_LOGW(TAG, "pin '%s'=%d is a boot strapping pin; an attached load "
                 "may prevent the device booting", role, pin);
    }

    *dst = (gpio_num_t)pin;
    return true;
}

// Apply an array of per-gang pins ("relay" / "switch").
static int apply_pin_array(const char *role, const cJSON *arr,
                           gpio_num_t *dst, bool need_output) {
    if (!cJSON_IsArray(arr)) return 0;

    int applied = 0, idx = 0;
    const cJSON *item = NULL;
    cJSON_ArrayForEach(item, arr) {
        if (idx >= DSGV_MAX_RELAY_COUNT) {
            ESP_LOGW(TAG, "pin array '%s' has more than %d entries; extra ignored",
                     role, DSGV_MAX_RELAY_COUNT);
            break;
        }
        char label[24];
        snprintf(label, sizeof(label), "%s[%d]", role, idx);
        if (apply_pin(label, item, &dst[idx], need_output)) applied++;
        idx++;
    }
    return applied;
}

// ── Duplicate detection ───────────────────────────────────────────────────────
// Not an error: the shipped C3 and ESP32 pin maps deliberately overlap relay
// gangs 2-4 with the dimmer/CCT/RGB channels, on the documented understanding
// that those features are not combined. Warning is the right level here — the
// flasher UI is where a genuinely invalid combination gets blocked, because
// only it knows which capabilities the user actually selected.

typedef struct { const char *role; int pin; } used_pin_t;

static void warn_on_duplicates(const DSGV_device_config_t *cfg) {
    used_pin_t used[2 * DSGV_MAX_RELAY_COUNT + 10];
    int n = 0;

    for (int i = 0; i < cfg->relay_count && i < DSGV_MAX_RELAY_COUNT; i++) {
        used[n++] = (used_pin_t){ "relay",  (int)cfg->relay_pins[i]  };
    }
    for (int i = 0; i < cfg->relay_count && i < DSGV_MAX_RELAY_COUNT; i++) {
        used[n++] = (used_pin_t){ "switch", (int)cfg->switch_pins[i] };
    }
    for (size_t i = 0; i < sizeof(k_pin_fields) / sizeof(k_pin_fields[0]); i++) {
        const gpio_num_t *p =
            (const gpio_num_t *)((const char *)cfg + k_pin_fields[i].off);
        used[n++] = (used_pin_t){ k_pin_fields[i].key, (int)*p };
    }

    for (int i = 0; i < n; i++) {
        if (used[i].pin < 0) continue;          // not fitted
        for (int j = i + 1; j < n; j++) {
            if (used[i].pin == used[j].pin) {
                ESP_LOGW(TAG, "GPIO %d assigned to both '%s' and '%s' — "
                         "these features cannot be used together",
                         used[i].pin, used[i].role, used[j].role);
            }
        }
    }
}

// ── Public entry point ────────────────────────────────────────────────────────

bool DSGV_config_apply_json(DSGV_device_config_t *cfg, const cJSON *root) {
    if (!cfg || !root) return false;

    bool applied = false;

    const cJSON *type = cJSON_GetObjectItemCaseSensitive(root, "device_type");
    if (cJSON_IsString(type) && type->valuestring) {
        strlcpy(cfg->device_type, type->valuestring, sizeof(cfg->device_type));
        applied = true;
    }

    const cJSON *caps = cJSON_GetObjectItemCaseSensitive(root, "capabilities");
    if (cJSON_IsArray(caps)) {
        char *s = cJSON_PrintUnformatted(caps);
        if (s) {
            if (strlen(s) >= sizeof(cfg->capabilities)) {
                // Truncating here would emit invalid JSON in the MQTT announce
                // and break the app's parse, so reject instead.
                ESP_LOGW(TAG, "capabilities too long (%u bytes, max %u) — ignored",
                         (unsigned)strlen(s), (unsigned)sizeof(cfg->capabilities) - 1);
            } else {
                strlcpy(cfg->capabilities, s, sizeof(cfg->capabilities));
                applied = true;
            }
            cJSON_free(s);
        }
    }

    const cJSON *rc = cJSON_GetObjectItemCaseSensitive(root, "relay_count");
    if (cJSON_IsNumber(rc)) {
        int v = (int)rc->valuedouble;
        // 0 is valid: the sensor SKUs and the thermostat have no relays.
        if (v >= 0 && v <= DSGV_MAX_RELAY_COUNT) {
            cfg->relay_count = (uint8_t)v;
            applied = true;
        } else {
            ESP_LOGW(TAG, "relay_count=%d out of range 0-%d — ignored",
                     v, DSGV_MAX_RELAY_COUNT);
        }
    }

    const cJSON *pins = cJSON_GetObjectItemCaseSensitive(root, "pins");
    if (cJSON_IsObject(pins)) {
        if (apply_pin_array("relay",
                            cJSON_GetObjectItemCaseSensitive(pins, "relay"),
                            cfg->relay_pins, true) > 0) applied = true;
        if (apply_pin_array("switch",
                            cJSON_GetObjectItemCaseSensitive(pins, "switch"),
                            cfg->switch_pins, false) > 0) applied = true;

        for (size_t i = 0; i < sizeof(k_pin_fields) / sizeof(k_pin_fields[0]); i++) {
            const cJSON *item =
                cJSON_GetObjectItemCaseSensitive(pins, k_pin_fields[i].key);
            if (apply_pin(k_pin_fields[i].key, item,
                          pin_at(cfg, k_pin_fields[i].off),
                          k_pin_fields[i].out)) {
                applied = true;
            }
        }

        // adc_temp is handled separately: being a valid digital input is not
        // sufficient, it must be routed to ADC1 on this particular chip.
        const cJSON *adc = cJSON_GetObjectItemCaseSensitive(pins, "adc_temp");
        if (cJSON_IsNumber(adc)) {
            int p = (int)adc->valuedouble;
            if (p == GPIO_NUM_NC) {
                cfg->adc_temp_pin = GPIO_NUM_NC;
                applied = true;
            } else if (DSGV_pin_to_adc1_channel(p) < 0) {
                ESP_LOGW(TAG, "pin 'adc_temp'=%d has no ADC1 channel on this "
                         "chip (keeping %d)", p, (int)cfg->adc_temp_pin);
            } else {
                cfg->adc_temp_pin = (gpio_num_t)p;
                applied = true;
            }
        }
    }

    if (applied) warn_on_duplicates(cfg);
    return applied;
}
