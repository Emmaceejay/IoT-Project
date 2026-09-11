#include "dsgv_serial_config.h"
#include "dsgv_config.h"
#include "dsgv_device_config.h"
#include "dsgv_config_json.h"
#include "dsgv_pin_rules.h"

#include "driver/uart.h"
#include "esp_app_desc.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "cJSON.h"

#include <string.h>
#include <stdio.h>

static const char *TAG = "DSGV_serial";

#define SERIAL_UART        UART_NUM_0
#define RX_RING_BYTES      2048
#define FRAME_HEADER_LEN   8      // magic(4) + ver + type + len_hi + len_lo

static const uint8_t k_magic[4] = { 'D', 'S', 'G', 'V' };

// ── Transmit ──────────────────────────────────────────────────────────────────

static void send_frame(uint8_t type, const char *payload) {
    size_t len = payload ? strlen(payload) : 0;
    if (len > DSGV_SERIAL_MAX_PAYLOAD) len = DSGV_SERIAL_MAX_PAYLOAD;

    uint8_t hdr[FRAME_HEADER_LEN] = {
        k_magic[0], k_magic[1], k_magic[2], k_magic[3],
        DSGV_SERIAL_PROTO_VERSION, type,
        (uint8_t)((len >> 8) & 0xFF), (uint8_t)(len & 0xFF),
    };

    uint32_t sum = 0;
    for (int i = 0; i < FRAME_HEADER_LEN; i++) sum += hdr[i];
    for (size_t i = 0; i < len; i++)           sum += (uint8_t)payload[i];

    uint8_t tail[2] = { (uint8_t)(sum & 0xFF), '\n' };

    uart_write_bytes(SERIAL_UART, (const char *)hdr, FRAME_HEADER_LEN);
    if (len) uart_write_bytes(SERIAL_UART, payload, len);
    uart_write_bytes(SERIAL_UART, (const char *)tail, sizeof(tail));
}

static void send_err(const char *reason) {
    send_frame(DSGV_SERIAL_RESPONSE_ERR, reason);
}

// ── Payload builders ──────────────────────────────────────────────────────────

// Identity the flasher needs to pick the right catalogue entry and to show
// the user which board it is talking to.
static char *build_info_json(void) {
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_WIFI_STA);

    const esp_app_desc_t *app = esp_app_get_description();

    cJSON *o = cJSON_CreateObject();
    if (!o) return NULL;

    char mac_str[13];
    snprintf(mac_str, sizeof(mac_str), "%02X%02X%02X%02X%02X%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);

    cJSON_AddStringToObject(o, "device_id", mac_str);
    cJSON_AddStringToObject(o, "chip",      CONFIG_IDF_TARGET);
    cJSON_AddStringToObject(o, "firmware",  app ? app->version : "unknown");
    cJSON_AddNumberToObject(o, "proto",     DSGV_SERIAL_PROTO_VERSION);
    cJSON_AddNumberToObject(o, "pin_count", DSGV_pin_count());
    cJSON_AddNumberToObject(o, "max_relays", DSGV_MAX_RELAY_COUNT);

    char *s = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    return s;
}

// Mirrors the SET_CONFIG schema so a host can read, edit and write back.
static char *build_config_json(void) {
    const DSGV_device_config_t *c = &g_device_config;

    cJSON *o = cJSON_CreateObject();
    if (!o) return NULL;

    cJSON_AddStringToObject(o, "device_type", c->device_type);
    cJSON_AddNumberToObject(o, "relay_count", c->relay_count);

    // capabilities is stored as a JSON array string; re-parse so the host gets
    // a real array rather than an escaped string. If it fails to parse — which
    // should be impossible now the parser rejects over-long values — fall back
    // to an empty array rather than emitting malformed JSON.
    cJSON *caps = cJSON_Parse(c->capabilities);
    cJSON_AddItemToObject(o, "capabilities", caps ? caps : cJSON_CreateArray());

    cJSON *pins = cJSON_AddObjectToObject(o, "pins");
    if (pins) {
        cJSON *relay = cJSON_AddArrayToObject(pins, "relay");
        cJSON *sw    = cJSON_AddArrayToObject(pins, "switch");
        for (int i = 0; i < DSGV_MAX_RELAY_COUNT; i++) {
            if (relay) cJSON_AddItemToArray(relay, cJSON_CreateNumber(c->relay_pins[i]));
            if (sw)    cJSON_AddItemToArray(sw,    cJSON_CreateNumber(c->switch_pins[i]));
        }
        cJSON_AddNumberToObject(pins, "dimmer",     c->dimmer_pin);
        cJSON_AddNumberToObject(pins, "warm",       c->warm_pin);
        cJSON_AddNumberToObject(pins, "cool",       c->cool_pin);
        cJSON_AddNumberToObject(pins, "red",        c->red_pin);
        cJSON_AddNumberToObject(pins, "green",      c->green_pin);
        cJSON_AddNumberToObject(pins, "blue",       c->blue_pin);
        cJSON_AddNumberToObject(pins, "status_led", c->status_led_pin);
        cJSON_AddNumberToObject(pins, "motion",     c->motion_pin);
        cJSON_AddNumberToObject(pins, "contact",    c->contact_pin);
        cJSON_AddNumberToObject(pins, "button",     c->button_pin);
        cJSON_AddNumberToObject(pins, "adc_temp",   c->adc_temp_pin);
    }

    char *s = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    return s;
}

// ── Request handling ──────────────────────────────────────────────────────────

static void restart_task(void *arg) {
    (void)arg;
    vTaskDelay(pdMS_TO_TICKS(300));   // let the response drain
    esp_restart();
}

static void handle_frame(uint8_t type, const char *payload, size_t len) {
    switch (type) {

    case DSGV_SERIAL_REQUEST_INFO: {
        char *s = build_info_json();
        if (!s) { send_err("out of memory"); return; }
        send_frame(DSGV_SERIAL_RESPONSE_OK, s);
        cJSON_free(s);
        break;
    }

    case DSGV_SERIAL_GET_CONFIG: {
        char *s = build_config_json();
        if (!s) { send_err("out of memory"); return; }
        send_frame(DSGV_SERIAL_RESPONSE_OK, s);
        cJSON_free(s);
        break;
    }

    case DSGV_SERIAL_SET_CONFIG: {
        if (len == 0) { send_err("empty payload"); return; }

        cJSON *root = cJSON_ParseWithLength(payload, len);
        if (!root) { send_err("invalid json"); return; }

        DSGV_device_config_t cfg = g_device_config;
        // Same parser as BLE and HTTP. Individual bad pins are rejected inside
        // it and leave the previous value, so a partly-wrong payload still
        // applies its good fields rather than failing wholesale.
        bool applied = DSGV_config_apply_json(&cfg, root);
        cJSON_Delete(root);

        if (!applied) { send_err("no recognised fields"); return; }

        if (DSGV_device_config_save(&cfg) != ESP_OK) {
            send_err("nvs write failed");
            return;
        }

        char *s = build_config_json();   // echo what actually took effect
        send_frame(DSGV_SERIAL_RESPONSE_OK, s ? s : "{}");
        if (s) cJSON_free(s);
        ESP_LOGI(TAG, "config updated over serial");
        break;
    }

    case DSGV_SERIAL_RESTART:
        send_frame(DSGV_SERIAL_RESPONSE_OK, NULL);
        xTaskCreate(restart_task, "dsgv_rst", 2048, NULL, 5, NULL);
        break;

    default:
        send_err("unknown type");
        break;
    }
}

// ── Receive ───────────────────────────────────────────────────────────────────

static void serial_task(void *arg) {
    (void)arg;

    // Assembled one byte at a time. The port also carries log output, so the
    // reader has to tolerate arbitrary bytes between frames and resynchronise
    // on the magic without ever blocking on a partial frame.
    static uint8_t buf[FRAME_HEADER_LEN + DSGV_SERIAL_MAX_PAYLOAD + 2];
    size_t   have     = 0;
    size_t   expected = 0;     // total frame length once the header is known

    for (;;) {
        uint8_t b;
        int n = uart_read_bytes(SERIAL_UART, &b, 1, pdMS_TO_TICKS(200));
        if (n != 1) continue;

        // Resynchronise on the magic prefix.
        if (have < sizeof(k_magic)) {
            if (b == k_magic[have]) {
                buf[have++] = b;
            } else {
                // Not a continuation. It may still start a new magic.
                have = (b == k_magic[0]) ? 1 : 0;
                if (have) buf[0] = b;
            }
            continue;
        }

        buf[have++] = b;

        if (have == FRAME_HEADER_LEN) {
            if (buf[4] != DSGV_SERIAL_PROTO_VERSION) {
                send_err("unsupported protocol version");
                have = 0;
                continue;
            }
            size_t plen = ((size_t)buf[6] << 8) | buf[7];
            if (plen > DSGV_SERIAL_MAX_PAYLOAD) {
                send_err("payload too large");
                have = 0;
                continue;
            }
            expected = FRAME_HEADER_LEN + plen + 2;   // + checksum + '\n'
            continue;
        }

        if (expected && have == expected) {
            size_t plen     = expected - FRAME_HEADER_LEN - 2;
            uint8_t rx_sum  = buf[expected - 2];
            uint8_t terminator = buf[expected - 1];

            uint32_t sum = 0;
            for (size_t i = 0; i < expected - 2; i++) sum += buf[i];

            if (terminator != '\n') {
                send_err("bad terminator");
            } else if ((uint8_t)(sum & 0xFF) != rx_sum) {
                send_err("bad checksum");
            } else {
                handle_frame(buf[5], (const char *)&buf[FRAME_HEADER_LEN], plen);
            }

            have = 0;
            expected = 0;
        }
    }
}

esp_err_t DSGV_serial_config_start(void) {
    // RX-only driver install. The TX side is left to the existing console so
    // ESP_LOG output keeps working exactly as before; responses are written
    // with uart_write_bytes, which shares that TX path.
    esp_err_t err = uart_driver_install(SERIAL_UART, RX_RING_BYTES, 0, 0, NULL, 0);
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {   // already installed is fine
        ESP_LOGW(TAG, "uart_driver_install failed (%s); serial config disabled",
                 esp_err_to_name(err));
        return err;
    }

    if (xTaskCreate(serial_task, "DSGV_serial", 5120, NULL, 3, NULL) != pdPASS) {
        ESP_LOGW(TAG, "could not start serial config task");
        return ESP_ERR_NO_MEM;
    }

    ESP_LOGI(TAG, "serial config listening on UART%d @ %d baud",
             SERIAL_UART, CONFIG_ESP_CONSOLE_UART_BAUDRATE);
    return ESP_OK;
}
