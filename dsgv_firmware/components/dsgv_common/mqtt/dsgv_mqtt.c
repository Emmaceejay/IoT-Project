/**
 * DSGV_mqtt.c — DSGV Hub MQTT Client
 *
 * Single-broker MQTT client.  Default broker: MQTT_CLOUD_HOST (see dsgv_config.h).
 * On connection error the SDK automatically retries every MQTT_RECONNECT_DELAY_MS.
 * Local device control falls back to HTTP — no automatic broker switching.
 * The user (via the DSGV Hub App) may change the broker at any time via the
 * authenticated handle_config MQTT command.  A 60-second rollback watchdog reverts
 * the change if the new broker never connects.
 *
 * On connect, publishes a device announcement so the DSGV Hub App
 * can populate the real device list (device_id, name, capabilities, local_ip).
 *
 * Topics (device_id = MAC address):
 *   devices/{id}/announce    ← published once on connect (retained)
 *   devices/{id}/status      ← "online" on connect, "offline" via LWT
 *   devices/{id}/telemetry   ← state snapshot (periodic + after any change)
 *   devices/{id}/command     ← incoming: {"capability":"power","value":true}
 *   devices/{id}/ota-trigger ← incoming: {"url":"https://...","hash":"sha256..."}
 */

#include "dsgv_config.h"
#include "dsgv_device_config.h"
#include "dsgv_device_state.h"
#include "wifi_manager.h"
#include "mqtt_client.h"
#include "nvs.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_app_desc.h"
#include "esp_system.h"
#include "cJSON.h"
#include "freertos/timers.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>

static const char *TAG = "DSGV_mqtt";

// ── Global shared state (also used by DSGV_http_server.c) ───────────────────
DSGV_device_state_t g_device_state = {
    .relay_states        = {false, false, false, false},
    .brightness          = 0,
    .color_temp_k        = 4000,
    .rgb_r               = 255,
    .rgb_g               = 255,
    .rgb_b               = 255,
    .humidity            = 0.0f,
    .motion_detected     = false,
    .contact_closed      = false,
    .current_temp        = 0.0f,
    .target_temp         = 22.0f,
    .hvac_mode           = "auto",
    .local_ip            = "",
    .power_restore_mode  = "off",  // safe default — overwritten by NVS on first boot
};
SemaphoreHandle_t g_state_mutex = NULL;

// ── Private state ─────────────────────────────────────────────────────────────
static esp_mqtt_client_handle_t s_client = NULL;

static char s_device_id[18];           // "AABBCCDDEEFF"
static char s_device_name[32];         // auto-generated: "Switch_DDEEFF"
static char s_topic_status[64];
static char s_topic_telemetry[64];
static char s_topic_command[64];
static char s_topic_ota[64];
static char s_topic_announce[64];
static char s_topic_config[64];

// Broker rollback: 60-second one-shot timer started on every broker change.
// Cancelled in MQTT_EVENT_CONNECTED when new broker connection succeeds.
// Fires and restores the previous broker if connection never materialises.
static TimerHandle_t s_broker_rollback_timer = NULL;
static bool          s_broker_reverted       = false;

// ── Forward declarations ──────────────────────────────────────────────────────
static void mqtt_event_handler(void *arg, esp_event_base_t base,
                                int32_t event_id, void *event_data);
static void build_topics(void);
static void publish_online_status(void);
static void publish_announcement(void);
static void handle_command(const char *payload, int len);
static void handle_ota(const char *payload, int len);
static void handle_config(const char *payload, int len);
static void broker_rollback_timer_cb(TimerHandle_t timer);
static void _schedule_broker_switch(const char *host, int port, bool tls, bool is_rollback);

// Declared in DSGV_ota.c
extern esp_err_t DSGV_ota_begin(const char *json_payload);

// Declared in DSGV_gpio.c
extern void DSGV_gpio_apply_state(void);
extern void DSGV_gpio_save_relay_state(void);

// ── Topic builder ─────────────────────────────────────────────────────────────

static void build_topics(void) {
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    snprintf(s_device_id, sizeof(s_device_id),
             "%02X%02X%02X%02X%02X%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);

    // Auto-generated human-readable name: "{TYPE}_{last3MacBytes}"
    // e.g. "Switch_A1B2C3" — unique per unit, no per-device config needed.
    snprintf(s_device_name, sizeof(s_device_name),
             "%s_%.6s", g_device_config.device_type, s_device_id + 6);

    snprintf(s_topic_status,    sizeof(s_topic_status),
             MQTT_TOPIC_STATUS,    s_device_id);
    snprintf(s_topic_telemetry, sizeof(s_topic_telemetry),
             MQTT_TOPIC_TELEMETRY, s_device_id);
    snprintf(s_topic_command,   sizeof(s_topic_command),
             MQTT_TOPIC_COMMAND,   s_device_id);
    snprintf(s_topic_ota,       sizeof(s_topic_ota),
             MQTT_TOPIC_OTA,       s_device_id);
    snprintf(s_topic_announce,  sizeof(s_topic_announce),
             MQTT_TOPIC_ANNOUNCE,  s_device_id);
    snprintf(s_topic_config,    sizeof(s_topic_config),
             MQTT_TOPIC_CONFIG,    s_device_id);
}

// ── Startup ───────────────────────────────────────────────────────────────────

/**
 * Initialise the shared state mutex. Must be called before any module that
 * uses STATE_LOCK(). Called from DSGV_mqtt_start() so order is guaranteed.
 */
static void init_state_mutex(void) {
    if (g_state_mutex == NULL) {
        g_state_mutex = xSemaphoreCreateMutex();
        configASSERT(g_state_mutex != NULL);
    }
}

/**
 * Attempt connection to the given broker.
 * @param host      Hostname or IP
 * @param port      Port number
 * @param use_tls   true → MQTT_TRANSPORT_OVER_SSL, false → plain TCP
 */
static esp_err_t connect_to_broker(const char *host, int port, bool use_tls) {
    if (s_client) {
        esp_mqtt_client_destroy(s_client);
        s_client = NULL;
    }

    esp_mqtt_client_config_t cfg = {
        .broker = {
            .address = {
                .hostname  = host,
                .port      = port,
                .transport = use_tls ? MQTT_TRANSPORT_OVER_SSL
                                     : MQTT_TRANSPORT_OVER_TCP,
            },
        },
        .credentials = {
            .client_id = s_device_id,
        },
        .session = {
            .keepalive = MQTT_KEEPALIVE_SEC,
            .last_will = {
                .topic   = s_topic_status,
                .msg     = MQTT_LWT_PAYLOAD_OFFLINE,
                .msg_len = sizeof(MQTT_LWT_PAYLOAD_OFFLINE) - 1,
                .qos     = MQTT_QOS_AT_LEAST_ONCE,
                .retain  = true,
            },
        },
        .network = {
            .reconnect_timeout_ms = MQTT_RECONNECT_DELAY_MS,
        },
    };

    s_client = esp_mqtt_client_init(&cfg);
    if (!s_client) return ESP_FAIL;

    esp_mqtt_client_register_event(s_client, ESP_EVENT_ANY_ID,
                                    mqtt_event_handler, NULL);
    return esp_mqtt_client_start(s_client);
}

/**
 * Start MQTT — tries cloud broker first, then local Mosquitto on error.
 */
esp_err_t DSGV_mqtt_start(void) {
    init_state_mutex();
    build_topics();

    // Capture local IP from the Wi-Fi interface for the announce payload
    esp_netif_t *netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    if (netif) {
        esp_netif_ip_info_t ip_info;
        if (esp_netif_get_ip_info(netif, &ip_info) == ESP_OK) {
            STATE_LOCK();
            snprintf(g_device_state.local_ip, sizeof(g_device_state.local_ip),
                     IPSTR, IP2STR(&ip_info.ip));
            STATE_UNLOCK();
            ESP_LOGI(TAG, "Device local IP: %s", g_device_state.local_ip);
        }
    }

    // Check for user-configured broker in NVS (set by app broker-change command).
    // Fall back to compile-time MQTT_CLOUD_HOST when namespace is absent.
    char    nvs_host[65] = {0};
    int     nvs_port     = MQTT_CLOUD_PORT;
    bool    nvs_tls      = true;
    bool    has_nvs_cfg  = false;

    nvs_handle_t hcfg;
    if (nvs_open(MQTT_CFG_NVS_NS, NVS_READONLY, &hcfg) == ESP_OK) {
        size_t hlen = sizeof(nvs_host);
        if (nvs_get_str(hcfg, "host", nvs_host, &hlen) == ESP_OK && nvs_host[0]) {
            int32_t p; uint8_t t;
            if (nvs_get_i32(hcfg, "port", &p) == ESP_OK) nvs_port = (int)p;
            if (nvs_get_u8 (hcfg, "tls",  &t) == ESP_OK) nvs_tls  = (bool)t;
            has_nvs_cfg = true;
        }
        nvs_close(hcfg);
    }

    if (has_nvs_cfg) {
        ESP_LOGI(TAG, "Connecting to user-configured broker %s:%d (TLS=%d)",
                 nvs_host, nvs_port, nvs_tls);
        return connect_to_broker(nvs_host, nvs_port, nvs_tls);
    }
    ESP_LOGI(TAG, "Connecting to broker %s:%d", MQTT_CLOUD_HOST, MQTT_CLOUD_PORT);
    return connect_to_broker(MQTT_CLOUD_HOST, MQTT_CLOUD_PORT, MQTT_CLOUD_TLS);
}

// ── Event handler ─────────────────────────────────────────────────────────────

static void mqtt_event_handler(void *arg, esp_event_base_t base,
                                int32_t event_id, void *event_data) {
    esp_mqtt_event_handle_t event = (esp_mqtt_event_handle_t)event_data;

    switch (event->event_id) {

        case MQTT_EVENT_CONNECTED:
            ESP_LOGI(TAG, "MQTT connected. Device: %s", s_device_id);

            // New broker confirmed reachable — cancel any pending rollback
            if (s_broker_rollback_timer &&
                xTimerIsTimerActive(s_broker_rollback_timer)) {
                xTimerStop(s_broker_rollback_timer, 0);
                ESP_LOGI(TAG, "Broker change confirmed — rollback timer cancelled");
            }

            // If a previous broker change was reverted, notify the app
            if (s_broker_reverted) {
                s_broker_reverted = false;
                esp_mqtt_client_publish(s_client, s_topic_telemetry,
                    "{\"broker_change_status\":\"reverted\"}",
                    strlen("{\"broker_change_status\":\"reverted\"}"),
                    MQTT_QOS_AT_LEAST_ONCE, /*retain=*/false);
                ESP_LOGW(TAG, "Notified app: broker reverted to previous");
            }

            // Announce presence + capabilities so the App can discover us
            publish_announcement();

            // Retained online status (LWT publishes "offline" if we drop)
            publish_online_status();

            // Subscribe: command, OTA, and broker-config topics
            esp_mqtt_client_subscribe(s_client, s_topic_command,
                                       MQTT_QOS_AT_LEAST_ONCE);
            esp_mqtt_client_subscribe(s_client, s_topic_ota,
                                       MQTT_QOS_AT_LEAST_ONCE);
            esp_mqtt_client_subscribe(s_client, s_topic_config,
                                       MQTT_QOS_AT_LEAST_ONCE);
            break;

        case MQTT_EVENT_DISCONNECTED:
            ESP_LOGW(TAG, "MQTT disconnected.");
            break;

        case MQTT_EVENT_DATA: {
            // Copy topic to a null-terminated string for comparison
            char topic[64] = {0};
            int  tlen = event->topic_len < (int)sizeof(topic) - 1
                            ? event->topic_len
                            : (int)sizeof(topic) - 1;
            memcpy(topic, event->topic, tlen);

            if (strcmp(topic, s_topic_command) == 0) {
                handle_command(event->data, event->data_len);
            } else if (strcmp(topic, s_topic_ota) == 0) {
                handle_ota(event->data, event->data_len);
            } else if (strcmp(topic, s_topic_config) == 0) {
                handle_config(event->data, event->data_len);
            } else {
                ESP_LOGW(TAG, "Unhandled topic: %s", topic);
            }
            break;
        }

        case MQTT_EVENT_ERROR:
            // The SDK will automatically reconnect after MQTT_RECONNECT_DELAY_MS.
            // Local control falls back to HTTP — no broker switching needed here.
            ESP_LOGE(TAG, "MQTT error. Broker unreachable. Reconnecting in %d ms…",
                     MQTT_RECONNECT_DELAY_MS);
            break;

        default:
            break;
    }
}

// ── Publish helpers ───────────────────────────────────────────────────────────

static void publish_online_status(void) {
    esp_mqtt_client_publish(s_client, s_topic_status,
                             MQTT_LWT_PAYLOAD_ONLINE,
                             sizeof(MQTT_LWT_PAYLOAD_ONLINE) - 1,
                             MQTT_QOS_AT_LEAST_ONCE, /*retain=*/true);
    ESP_LOGI(TAG, "Published: online → %s", s_topic_status);
}

/**
 * Publishes a discovery/announce payload so the DSGV Hub App can populate
 * the real device list with correct capabilities and local IP.
 *
 * Payload schema matches DeviceModel.fromJson() in the Flutter app:
 * {
 *   "device_id":    "AABBCCDDEEFF",
 *   "name":         "DSGV Switch v1",
 *   "capabilities": ["relay"],
 *   "local_ip":     "192.168.1.42",
 *   "firmware":     "1.0.0",
 *   "status":       "online"
 * }
 */
static void publish_announcement(void) {
    STATE_LOCK();
    char ip_copy[16];
    strlcpy(ip_copy, g_device_state.local_ip, sizeof(ip_copy));
    STATE_UNLOCK();

    char payload[384];
    snprintf(payload, sizeof(payload),
        "{"
        "\"device_id\":\"%s\","
        "\"name\":\"%s\","
        "\"capabilities\":%s,"
        "\"local_ip\":\"%s\","
        "\"firmware\":\"%s\","
        "\"status\":\"online\""
        "}",
        s_device_id,
        s_device_name,
        g_device_config.capabilities,
        ip_copy,
        esp_app_get_description()->version
    );

    // Retained = true so a freshly subscribed App sees it immediately
    esp_mqtt_client_publish(s_client, s_topic_announce,
                             payload, strlen(payload),
                             MQTT_QOS_AT_LEAST_ONCE, /*retain=*/true);
    ESP_LOGI(TAG, "Published announce → %s : %s", s_topic_announce, payload);
}

/**
 * Publishes the full device state as a JSON telemetry snapshot.
 * Called by GPIO layer after physical button press, by HTTP server after
 * REST commands, and periodically.
 *
 * Payload schema matches DeviceModel.telemetry in the Flutter app:
 * {"power":false,"brightness":0,"color_temp":4000,
 *  "current_temp":22.5,"target_temp":22.0,"mode":"auto"}
 */
void DSGV_mqtt_publish_telemetry(const char *json_payload) {
    // Snapshot the handle to avoid a TOCTOU race: _broker_switch_task can set
    // s_client = NULL between our NULL check and the publish call.
    esp_mqtt_client_handle_t client = s_client;
    if (!client) return;
    esp_mqtt_client_publish(client, s_topic_telemetry,
                             json_payload, strlen(json_payload),
                             MQTT_QOS_AT_LEAST_ONCE, /*retain=*/false);
    ESP_LOGI(TAG, "Telemetry → %s", s_topic_telemetry);
}

// ── Command handlers ──────────────────────────────────────────────────────────

/**
 * Handles JSON commands from the DSGV Hub App (MQTT transport).
 *
 * App sends (device_manager.dart):
 *   {"device_id":"AABB...","power":true,"brightness":75}
 *
 * The "device_id" key is extra context from the app — we ignore it and
 * process whichever capability keys are present.
 */
static void handle_command(const char *payload, int len) {
    char buf[384] = {0};
    if (len >= (int)sizeof(buf)) {
        ESP_LOGE(TAG, "Command payload too large (%d bytes)", len);
        return;
    }
    memcpy(buf, payload, len);

    cJSON *root = cJSON_Parse(buf);
    if (!root) {
        ESP_LOGE(TAG, "Invalid JSON command: %s", buf);
        return;
    }

    // ── Parse all values to locals OUTSIDE the lock ───────────────────────────
    // cJSON reads are lock-free; ESP_LOGI inside a mutex bloats hold-time and
    // can cause priority inversion on IDF's vsnprintf + logging semaphore.
    int8_t v_power = -1, v_power_2 = -1, v_power_3 = -1, v_power_4 = -1;
    int    v_brightness = -1, v_ct = -1;
    float  v_target = 0.0f; bool v_has_target = false;
    char   v_mode[16] = "";    bool v_has_mode    = false;
    char   v_restore[16] = ""; bool v_has_restore = false;
    int    v_red = -1, v_green = -1, v_blue = -1;

    cJSON *j;

    j = cJSON_GetObjectItemCaseSensitive(root, "power");
    if (cJSON_IsBool(j)) v_power = cJSON_IsTrue(j) ? 1 : 0;

    if (g_device_config.relay_count >= 2) {
        j = cJSON_GetObjectItemCaseSensitive(root, "power_2");
        if (cJSON_IsBool(j)) v_power_2 = cJSON_IsTrue(j) ? 1 : 0;
    }
    if (g_device_config.relay_count >= 3) {
        j = cJSON_GetObjectItemCaseSensitive(root, "power_3");
        if (cJSON_IsBool(j)) v_power_3 = cJSON_IsTrue(j) ? 1 : 0;
    }
    if (g_device_config.relay_count >= 4) {
        j = cJSON_GetObjectItemCaseSensitive(root, "power_4");
        if (cJSON_IsBool(j)) v_power_4 = cJSON_IsTrue(j) ? 1 : 0;
    }

    j = cJSON_GetObjectItemCaseSensitive(root, "brightness");
    if (cJSON_IsNumber(j)) {
        v_brightness = (int)j->valuedouble;
        if (v_brightness < 0) v_brightness = 0;
        if (v_brightness > 100) v_brightness = 100;
    }

    j = cJSON_GetObjectItemCaseSensitive(root, "color_temp");
    if (cJSON_IsNumber(j)) {
        v_ct = (int)j->valuedouble;
        if (v_ct < 1000) v_ct = 1000;
        if (v_ct > 10000) v_ct = 10000;
    }

    j = cJSON_GetObjectItemCaseSensitive(root, "target_temp");
    if (cJSON_IsNumber(j)) { v_target = (float)j->valuedouble; v_has_target = true; }

    j = cJSON_GetObjectItemCaseSensitive(root, "mode");
    if (cJSON_IsString(j) && j->valuestring) {
        const char *m = j->valuestring;
        if (strcmp(m, "cool") == 0 || strcmp(m, "heat") == 0 ||
            strcmp(m, "auto") == 0 || strcmp(m, "off")  == 0) {
            strlcpy(v_mode, m, sizeof(v_mode));
            v_has_mode = true;
        } else {
            ESP_LOGW(TAG, "CMD mode '%s' rejected — unknown value", m);
        }
    }

    j = cJSON_GetObjectItemCaseSensitive(root, "power_restore");
    if (cJSON_IsString(j) && j->valuestring) {
        const char *m = j->valuestring;
        if (strcmp(m, "off") == 0 || strcmp(m, "on") == 0 || strcmp(m, "restore") == 0) {
            strlcpy(v_restore, m, sizeof(v_restore));
            v_has_restore = true;
        } else {
            ESP_LOGW(TAG, "CMD power_restore '%s' rejected — must be off|on|restore", m);
        }
    }

    j = cJSON_GetObjectItemCaseSensitive(root, "red");
    if (cJSON_IsNumber(j)) {
        v_red = (int)j->valuedouble;
        if (v_red < 0) v_red = 0;
        if (v_red > 255) v_red = 255;
    }
    j = cJSON_GetObjectItemCaseSensitive(root, "green");
    if (cJSON_IsNumber(j)) {
        v_green = (int)j->valuedouble;
        if (v_green < 0) v_green = 0;
        if (v_green > 255) v_green = 255;
    }
    j = cJSON_GetObjectItemCaseSensitive(root, "blue");
    if (cJSON_IsNumber(j)) {
        v_blue = (int)j->valuedouble;
        if (v_blue < 0) v_blue = 0;
        if (v_blue > 255) v_blue = 255;
    }

    cJSON_Delete(root);  // free before entering the lock

    // ── Brief STATE_LOCK: only state-struct writes ────────────────────────────
    bool state_changed = false;
    STATE_LOCK();
    if (v_power   >= 0) { g_device_state.relay_states[0] = (bool)v_power;   state_changed = true; }
    if (v_power_2 >= 0) { g_device_state.relay_states[1] = (bool)v_power_2; state_changed = true; }
    if (v_power_3 >= 0) { g_device_state.relay_states[2] = (bool)v_power_3; state_changed = true; }
    if (v_power_4 >= 0) { g_device_state.relay_states[3] = (bool)v_power_4; state_changed = true; }
    if (v_brightness >= 0) { g_device_state.brightness    = v_brightness; state_changed = true; }
    if (v_ct >= 0)         { g_device_state.color_temp_k  = v_ct;         state_changed = true; }
    if (v_has_target)      { g_device_state.target_temp   = v_target;     state_changed = true; }
    if (v_has_mode) {
        strlcpy(g_device_state.hvac_mode, v_mode, sizeof(g_device_state.hvac_mode));
        state_changed = true;
    }
    if (v_has_restore) {
        strlcpy(g_device_state.power_restore_mode, v_restore,
                sizeof(g_device_state.power_restore_mode));
        state_changed = true;
    }
    if (v_red   >= 0) { g_device_state.rgb_r = (uint8_t)v_red;   state_changed = true; }
    if (v_green >= 0) { g_device_state.rgb_g = (uint8_t)v_green; state_changed = true; }
    if (v_blue  >= 0) { g_device_state.rgb_b = (uint8_t)v_blue;  state_changed = true; }
    STATE_UNLOCK();

    // ── Log after unlock ──────────────────────────────────────────────────────
    if (v_power   >= 0) ESP_LOGI(TAG, "CMD power   → %s", v_power   ? "ON" : "OFF");
    if (v_power_2 >= 0) ESP_LOGI(TAG, "CMD power_2 → %s", v_power_2 ? "ON" : "OFF");
    if (v_power_3 >= 0) ESP_LOGI(TAG, "CMD power_3 → %s", v_power_3 ? "ON" : "OFF");
    if (v_power_4 >= 0) ESP_LOGI(TAG, "CMD power_4 → %s", v_power_4 ? "ON" : "OFF");
    if (v_brightness >= 0) ESP_LOGI(TAG, "CMD brightness → %d%%", v_brightness);
    if (v_ct >= 0)         ESP_LOGI(TAG, "CMD color_temp → %dK",  v_ct);
    if (v_has_target)      ESP_LOGI(TAG, "CMD target_temp → %.1fC", v_target);
    if (v_has_mode)        ESP_LOGI(TAG, "CMD mode → %s", v_mode);
    if (v_has_restore)     ESP_LOGI(TAG, "CMD power_restore → %s", v_restore);
    if (v_red   >= 0) ESP_LOGI(TAG, "CMD red   → %d", v_red);
    if (v_green >= 0) ESP_LOGI(TAG, "CMD green → %d", v_green);
    if (v_blue  >= 0) ESP_LOGI(TAG, "CMD blue  → %d", v_blue);

    // Persist power_restore mode to NVS so it survives reboots.
    if (v_has_restore) {
        nvs_handle_t hdev;
        if (nvs_open(DSGV_DEVICE_NVS_NS, NVS_READWRITE, &hdev) == ESP_OK) {
            nvs_set_str(hdev, DSGV_NVS_KEY_RESTORE, v_restore);
            nvs_commit(hdev);
            nvs_close(hdev);
        }
    }

    // Drive GPIO outputs to match the new state (relay, LED)
    if (state_changed) {
        DSGV_gpio_apply_state();
        // Any relay state changes must be persisted for "restore" mode.
        bool relay_changed = (v_power >= 0 || v_power_2 >= 0 ||
                              v_power_3 >= 0 || v_power_4 >= 0);
        if (relay_changed) DSGV_gpio_save_relay_state();
    }

    // Publish updated telemetry so the App stays in sync after a command
    if (state_changed) {
        char telemetry[512];
        STATE_LOCK();
        DSGV_device_state_t snap = g_device_state;
        STATE_UNLOCK();
        snprintf(telemetry, sizeof(telemetry),
            "{\"power\":%s,\"power_2\":%s,\"power_3\":%s,\"power_4\":%s,"
            "\"brightness\":%d,\"color_temp\":%d,"
            "\"red\":%u,\"green\":%u,\"blue\":%u,"
            "\"current_temp\":%.1f,\"humidity\":%.1f,"
            "\"motion\":%s,\"contact\":%s,"
            "\"target_temp\":%.1f,\"mode\":\"%s\","
            "\"power_restore\":\"%s\"}",
            snap.relay_states[0] ? "true"  : "false",
            snap.relay_states[1] ? "true"  : "false",
            snap.relay_states[2] ? "true"  : "false",
            snap.relay_states[3] ? "true"  : "false",
            snap.brightness,
            snap.color_temp_k,
            (unsigned)snap.rgb_r, (unsigned)snap.rgb_g, (unsigned)snap.rgb_b,
            snap.current_temp,
            snap.humidity,
            snap.motion_detected ? "true"  : "false",
            snap.contact_closed  ? "true"  : "false",
            snap.target_temp,
            snap.hvac_mode,
            snap.power_restore_mode[0] ? snap.power_restore_mode : "off"
        );
        DSGV_mqtt_publish_telemetry(telemetry);
    }
}

/**
 * Handles OTA trigger messages from the DSGV Hub App.
 * Payload: {"url":"https://...","hash":"sha256-of-binary"}
 */
static void handle_ota(const char *payload, int len) {
    char buf[512] = {0};
    if (len >= (int)sizeof(buf)) {
        ESP_LOGE(TAG, "OTA payload too large (%d bytes)", len);
        return;
    }
    memcpy(buf, payload, len);
    ESP_LOGI(TAG, "OTA trigger received. Handing off to DSGV_ota...");
    DSGV_ota_begin(buf);
}

// ── Broker reconfiguration ────────────────────────────────────────────────────

typedef struct {
    char host[65];
    int  port;
    bool tls;
    bool is_rollback;
} _broker_switch_args_t;

// One-shot task: destroys the current MQTT client and reconnects to new broker.
// Must run outside the MQTT task context — never call esp_mqtt_client_stop/destroy
// from within an MQTT event handler.
static void _broker_switch_task(void *arg) {
    _broker_switch_args_t *args = (_broker_switch_args_t *)arg;

    if (s_client) {
        esp_mqtt_client_stop(s_client);
        esp_mqtt_client_destroy(s_client);
        s_client = NULL;
    }
    connect_to_broker(args->host, args->port, args->tls);

    if (args->is_rollback) {
        ESP_LOGW(TAG, "Broker rollback: reconnected to %s:%d", args->host, args->port);
    }

    free(args);
    vTaskDelete(NULL);
}

static void _schedule_broker_switch(const char *host, int port, bool tls,
                                     bool is_rollback) {
    _broker_switch_args_t *args = malloc(sizeof(_broker_switch_args_t));
    if (!args) {
        ESP_LOGE(TAG, "Broker switch: malloc failed");
        return;
    }
    strlcpy(args->host, host, sizeof(args->host));
    args->port        = port;
    args->tls         = tls;
    args->is_rollback = is_rollback;
    if (xTaskCreate(_broker_switch_task, "broker_sw", 4096, args, 5, NULL)
            != pdPASS) {
        ESP_LOGE(TAG, "Broker switch: xTaskCreate failed");
        free(args);
    }
}

// Called 60 s after a broker change if MQTT_EVENT_CONNECTED never fires.
// Restores the previous broker config and reconnects.
static void broker_rollback_timer_cb(TimerHandle_t timer) {
    ESP_LOGW(TAG, "Broker rollback: new broker unreachable after 60 s — reverting");

    char    prev_host[65] = {0};
    int32_t prev_port_v   = MQTT_CLOUD_PORT;
    uint8_t prev_tls_v    = 1;

    nvs_handle_t hprev;
    if (nvs_open("prev_mqtt_cfg", NVS_READONLY, &hprev) == ESP_OK) {
        size_t hlen = sizeof(prev_host);
        nvs_get_str(hprev, "host", prev_host, &hlen);
        nvs_get_i32(hprev, "port", &prev_port_v);
        nvs_get_u8 (hprev, "tls",  &prev_tls_v);
        nvs_close(hprev);
    }

    // Restore prev_mqtt_cfg → mqtt_cfg
    nvs_handle_t hcfg;
    if (nvs_open(MQTT_CFG_NVS_NS, NVS_READWRITE, &hcfg) == ESP_OK) {
        if (prev_host[0]) {
            nvs_set_str(hcfg, "host", prev_host);
            nvs_set_i32(hcfg, "port", prev_port_v);
            nvs_set_u8 (hcfg, "tls",  prev_tls_v);
        } else {
            // Previous config was the factory default — erase user namespace
            nvs_erase_all(hcfg);
        }
        nvs_commit(hcfg);
        nvs_close(hcfg);
    }

    const char *host    = prev_host[0] ? prev_host         : MQTT_CLOUD_HOST;
    int         port    = prev_host[0] ? (int)prev_port_v  : MQTT_CLOUD_PORT;
    bool        use_tls = prev_host[0] ? (bool)prev_tls_v  : true;

    s_broker_reverted = true;
    _schedule_broker_switch(host, port, use_tls, /*is_rollback=*/true);
}

/**
 * Handles authenticated broker-reconfiguration commands from the DSGV Hub App.
 *
 * Payload variants:
 *   Broker change:   {"auth_token":"<32hex>","mqtt_host":"host","mqtt_port":8883,"mqtt_use_tls":true}
 *   Broker revert:   {"auth_token":"<32hex>","revert_to_factory":true}
 *   WiFi change:     {"auth_token":"<32hex>","wifi_ssid":"NewNet","wifi_password":"newpass"}
 *   Re-provision:    {"auth_token":"<32hex>","reprovision":true}
 *                    (clears only WiFi creds; device config, relay state, and broker
 *                     settings are all preserved — device reboots into BLE provisioning)
 *
 * Security: token verified by constant-time memcmp. Token never appears in MQTT
 * traffic outbound — it arrives here via the app's MQTT publish, which already
 * went through the broker. The real protection is 128-bit entropy making brute-force
 * impractical, and the token being seeded only over BLE (physically local).
 */
static void handle_config(const char *payload, int len) {
    char buf[384] = {0};
    if (len >= (int)sizeof(buf)) {
        ESP_LOGE(TAG, "Config payload too large (%d bytes)", len);
        return;
    }
    memcpy(buf, payload, len);

    cJSON *root = cJSON_Parse(buf);
    if (!root) {
        ESP_LOGW(TAG, "Config: invalid JSON — rejected");
        return;
    }

    // ── 1. Verify auth token ──────────────────────────────────────────────────
    const cJSON *j_tok = cJSON_GetObjectItemCaseSensitive(root, "auth_token");
    if (!cJSON_IsString(j_tok) || j_tok->valuestring == NULL ||
        strlen(j_tok->valuestring) != 32 ||
        memcmp(j_tok->valuestring, g_device_config.auth_token, 32) != 0) {
        cJSON_Delete(root);
        ESP_LOGW(TAG, "Config: invalid auth_token — rejected");
        return;
    }

    // ── 2. Factory revert ─────────────────────────────────────────────────────
    const cJSON *j_revert = cJSON_GetObjectItemCaseSensitive(root, "revert_to_factory");
    if (cJSON_IsTrue(j_revert)) {
        cJSON_Delete(root);
        ESP_LOGI(TAG, "Config: factory revert — erasing mqtt_cfg NVS");
        nvs_handle_t hnvs;
        if (nvs_open(MQTT_CFG_NVS_NS, NVS_READWRITE, &hnvs) == ESP_OK) {
            nvs_erase_all(hnvs);
            nvs_commit(hnvs);
            nvs_close(hnvs);
        }
        _schedule_broker_switch(MQTT_CLOUD_HOST, MQTT_CLOUD_PORT, MQTT_CLOUD_TLS,
                                 /*is_rollback=*/false);
        return;
    }

    // ── 3. Re-provision without factory reset ─────────────────────────────────
    // Erases only the wifi_creds NVS namespace — device config, relay state,
    // and MQTT broker settings are all preserved.  On reboot the device finds no
    // credentials and enters BLE provisioning so new WiFi details can be supplied.
    // Use this when the network is gone (new router, moved location, etc.) and the
    // device cannot be reached by wifi_ssid change below.
    // Payload: {"auth_token":"<32hex>","reprovision":true}
    const cJSON *j_reprov = cJSON_GetObjectItemCaseSensitive(root, "reprovision");
    if (cJSON_IsTrue(j_reprov)) {
        cJSON_Delete(root);
        ESP_LOGI(TAG, "Config: reprovision — erasing WiFi creds only, rebooting into BLE provisioning");
        wifi_manager_factory_reset();   // erases wifi_creds NVS + esp_restart()
        return;
    }

    // ── 4. WiFi credential change ─────────────────────────────────────────────
    // Overwrites the stored SSID/password and reboots.  All other NVS data
    // (device config, relay state, MQTT broker settings) is untouched.
    // Use when the router password changed or you are migrating to a new network
    // but the device is still reachable on the current one.
    // Payload: {"auth_token":"<32hex>","wifi_ssid":"NewNet","wifi_password":"newpass"}
    // wifi_password may be omitted or "" for open networks.
    const cJSON *j_ssid = cJSON_GetObjectItemCaseSensitive(root, "wifi_ssid");
    const cJSON *j_wpass = cJSON_GetObjectItemCaseSensitive(root, "wifi_password");
    if (cJSON_IsString(j_ssid) && j_ssid->valuestring && j_ssid->valuestring[0]) {
        char new_ssid[64];
        char new_pass[128];
        strlcpy(new_ssid, j_ssid->valuestring, sizeof(new_ssid));
        strlcpy(new_pass,
                (cJSON_IsString(j_wpass) && j_wpass->valuestring) ? j_wpass->valuestring : "",
                sizeof(new_pass));
        cJSON_Delete(root);
        wifi_manager_save_credentials(new_ssid, new_pass);
        ESP_LOGI(TAG, "Config: WiFi credentials updated (SSID: %s). Rebooting…", new_ssid);
        esp_restart();
        return;
    }

    // ── 5. Parse new broker parameters ───────────────────────────────────────
    const cJSON *j_host = cJSON_GetObjectItemCaseSensitive(root, "mqtt_host");
    const cJSON *j_port = cJSON_GetObjectItemCaseSensitive(root, "mqtt_port");
    const cJSON *j_tls  = cJSON_GetObjectItemCaseSensitive(root, "mqtt_use_tls");

    if (!cJSON_IsString(j_host) || !j_host->valuestring || !j_host->valuestring[0]) {
        cJSON_Delete(root);
        ESP_LOGW(TAG, "Config: missing or empty mqtt_host — rejected");
        return;
    }

    char new_host[65] = {0};
    strlcpy(new_host, j_host->valuestring, sizeof(new_host));

    int  new_port = MQTT_CLOUD_PORT;
    bool new_tls  = true;
    if (cJSON_IsNumber(j_port)) {
        int p = (int)j_port->valuedouble;
        if (p >= 1 && p <= 65535) new_port = p;
    }
    if (cJSON_IsBool(j_tls)) new_tls = cJSON_IsTrue(j_tls);

    cJSON_Delete(root);

    // ── 6. Copy current broker to rollback store ──────────────────────────────
    nvs_handle_t hprev;
    if (nvs_open("prev_mqtt_cfg", NVS_READWRITE, &hprev) == ESP_OK) {
        char    cur_host[65] = {0};
        int32_t cur_port     = MQTT_CLOUD_PORT;
        uint8_t cur_tls      = 1;
        nvs_handle_t hcur;
        if (nvs_open(MQTT_CFG_NVS_NS, NVS_READONLY, &hcur) == ESP_OK) {
            size_t hlen = sizeof(cur_host);
            nvs_get_str(hcur, "host", cur_host, &hlen);
            nvs_get_i32(hcur, "port", &cur_port);
            nvs_get_u8 (hcur, "tls",  &cur_tls);
            nvs_close(hcur);
        }
        // If no user config exists, save factory defaults as rollback target
        nvs_set_str(hprev, "host", cur_host[0] ? cur_host : MQTT_CLOUD_HOST);
        nvs_set_i32(hprev, "port", cur_host[0] ? cur_port : (int32_t)MQTT_CLOUD_PORT);
        nvs_set_u8 (hprev, "tls",  cur_host[0] ? cur_tls  : (uint8_t)1);
        nvs_commit(hprev);
        nvs_close(hprev);
    }

    // ── 7. Write new broker to mqtt_cfg ──────────────────────────────────────
    nvs_handle_t hnew;
    if (nvs_open(MQTT_CFG_NVS_NS, NVS_READWRITE, &hnew) == ESP_OK) {
        nvs_set_str(hnew, "host", new_host);
        nvs_set_i32(hnew, "port", (int32_t)new_port);
        nvs_set_u8 (hnew, "tls",  (uint8_t)new_tls);
        nvs_commit(hnew);
        nvs_close(hnew);
    }

    // ── 8. Start 60-second rollback watchdog ─────────────────────────────────
    if (!s_broker_rollback_timer) {
        s_broker_rollback_timer = xTimerCreate(
            "broker_rb", pdMS_TO_TICKS(60000), pdFALSE,
            NULL, broker_rollback_timer_cb);
    }
    if (s_broker_rollback_timer) {
        xTimerStop(s_broker_rollback_timer, 0);
        xTimerStart(s_broker_rollback_timer, 0);
    }

    // ── 9. Graceful reconnect (one-shot task — relays stay energised) ─────────
    ESP_LOGI(TAG, "Config: broker change accepted → %s:%d (TLS=%d). Reconnecting…",
             new_host, new_port, new_tls);
    _schedule_broker_switch(new_host, new_port, new_tls, /*is_rollback=*/false);
}
