/**
 * nexus_mqtt.c — Nexus Hub MQTT Client
 *
 * Dual-broker strategy (mirrors the Flutter app):
 *   1. Connect to MQTT_CLOUD_HOST (TLS, port 8883)
 *   2. On error → retry with MQTT_LOCAL_HOST (plain, port 1883)
 *
 * On connect, publishes a device announcement so the Nexus Hub App
 * can populate the real device list (device_id, name, capabilities, local_ip).
 *
 * Topics (device_id = MAC address):
 *   devices/{id}/announce    ← published once on connect (retained)
 *   devices/{id}/status      ← "online" on connect, "offline" via LWT
 *   devices/{id}/telemetry   ← state snapshot (periodic + after any change)
 *   devices/{id}/command     ← incoming: {"capability":"power","value":true}
 *   devices/{id}/ota-trigger ← incoming: {"url":"https://...","hash":"sha256..."}
 */

#include "nexus_config.h"
#include "nexus_device_config.h"
#include "nexus_device_state.h"
#include "wifi_manager.h"
#include "mqtt_client.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "cJSON.h"
#include <stdio.h>
#include <string.h>

static const char *TAG = "nexus_mqtt";

// ── Global shared state (also used by nexus_http_server.c) ───────────────────
nexus_device_state_t g_device_state = {
    .relay_states    = {false, false, false, false},
    .brightness      = 0,
    .color_temp_k    = 4000,
    .rgb_r           = 255,
    .rgb_g           = 255,
    .rgb_b           = 255,
    .humidity        = 0.0f,
    .motion_detected = false,
    .contact_closed  = false,
    .current_temp    = 0.0f,
    .target_temp     = 22.0f,
    .hvac_mode       = "auto",
    .local_ip        = "",
};
SemaphoreHandle_t g_state_mutex = NULL;

// ── Private state ─────────────────────────────────────────────────────────────
static esp_mqtt_client_handle_t s_client = NULL;
static bool s_using_local_broker = false;

static char s_device_id[18];           // "AABBCCDDEEFF"
static char s_device_name[32];         // auto-generated: "Switch_DDEEFF"
static char s_topic_status[64];
static char s_topic_telemetry[64];
static char s_topic_command[64];
static char s_topic_ota[64];
static char s_topic_announce[64];

// ── Forward declarations ──────────────────────────────────────────────────────
static void mqtt_event_handler(void *arg, esp_event_base_t base,
                                int32_t event_id, void *event_data);
static void build_topics(void);
static void publish_online_status(void);
static void publish_announcement(void);
static void handle_command(const char *payload, int len);
static void handle_ota(const char *payload, int len);

// Declared in nexus_ota.c
extern esp_err_t nexus_ota_begin(const char *json_payload);

// Declared in nexus_gpio.c
extern void nexus_gpio_apply_state(void);

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
}

// ── Startup ───────────────────────────────────────────────────────────────────

/**
 * Initialise the shared state mutex. Must be called before any module that
 * uses STATE_LOCK(). Called from nexus_mqtt_start() so order is guaranteed.
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
esp_err_t nexus_mqtt_start(void) {
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

    s_using_local_broker = false;
    ESP_LOGI(TAG, "Connecting to cloud broker %s:%d (TLS)",
             MQTT_CLOUD_HOST, MQTT_CLOUD_PORT);
    return connect_to_broker(MQTT_CLOUD_HOST, MQTT_CLOUD_PORT, true);
}

// ── Event handler ─────────────────────────────────────────────────────────────

static void mqtt_event_handler(void *arg, esp_event_base_t base,
                                int32_t event_id, void *event_data) {
    esp_mqtt_event_handle_t event = (esp_mqtt_event_handle_t)event_data;

    switch (event->event_id) {

        case MQTT_EVENT_CONNECTED:
            ESP_LOGI(TAG, "MQTT connected (%s). Device: %s",
                     s_using_local_broker ? "local" : "cloud", s_device_id);

            // Announce presence + capabilities so the App can discover us
            publish_announcement();

            // Retained online status (LWT publishes "offline" if we drop)
            publish_online_status();

            // Subscribe: command and OTA topics
            esp_mqtt_client_subscribe(s_client, s_topic_command,
                                       MQTT_QOS_AT_LEAST_ONCE);
            esp_mqtt_client_subscribe(s_client, s_topic_ota,
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
            } else {
                ESP_LOGW(TAG, "Unhandled topic: %s", topic);
            }
            break;
        }

        case MQTT_EVENT_ERROR:
            ESP_LOGE(TAG, "MQTT error. Broker unreachable.");
            if (!s_using_local_broker) {
                // Cloud broker failed → fall back to local Mosquitto
                s_using_local_broker = true;
                ESP_LOGW(TAG, "Retrying with local broker %s:%d (plain)",
                         MQTT_LOCAL_HOST, MQTT_LOCAL_PORT);
                connect_to_broker(MQTT_LOCAL_HOST, MQTT_LOCAL_PORT, false);
            }
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
 * Publishes a discovery/announce payload so the Nexus Hub App can populate
 * the real device list with correct capabilities and local IP.
 *
 * Payload schema matches MatterDevice.fromJson() in the Flutter app:
 * {
 *   "device_id":    "AABBCCDDEEFF",
 *   "name":         "Nexus Switch v1",
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
        NEXUS_FIRMWARE_VERSION
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
 * Payload schema matches MatterDevice.telemetry in the Flutter app:
 * {"power":false,"brightness":0,"color_temp":4000,
 *  "current_temp":22.5,"target_temp":22.0,"mode":"auto"}
 */
void nexus_mqtt_publish_telemetry(const char *json_payload) {
    if (!s_client) return;
    esp_mqtt_client_publish(s_client, s_topic_telemetry,
                             json_payload, strlen(json_payload),
                             MQTT_QOS_AT_LEAST_ONCE, /*retain=*/false);
    ESP_LOGI(TAG, "Telemetry → %s", s_topic_telemetry);
}

// ── Command handlers ──────────────────────────────────────────────────────────

/**
 * Handles JSON commands from the Nexus Hub App (MQTT transport).
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
    char   v_mode[16] = ""; bool v_has_mode = false;
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
        strlcpy(v_mode, j->valuestring, sizeof(v_mode));
        v_has_mode = true;
    }

    j = cJSON_GetObjectItemCaseSensitive(root, "red");
    if (cJSON_IsNumber(j)) {
        v_red = (int)j->valuedouble;
        if (v_red < 0) v_red = 0; if (v_red > 255) v_red = 255;
    }
    j = cJSON_GetObjectItemCaseSensitive(root, "green");
    if (cJSON_IsNumber(j)) {
        v_green = (int)j->valuedouble;
        if (v_green < 0) v_green = 0; if (v_green > 255) v_green = 255;
    }
    j = cJSON_GetObjectItemCaseSensitive(root, "blue");
    if (cJSON_IsNumber(j)) {
        v_blue = (int)j->valuedouble;
        if (v_blue < 0) v_blue = 0; if (v_blue > 255) v_blue = 255;
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
    if (v_red   >= 0) ESP_LOGI(TAG, "CMD red   → %d", v_red);
    if (v_green >= 0) ESP_LOGI(TAG, "CMD green → %d", v_green);
    if (v_blue  >= 0) ESP_LOGI(TAG, "CMD blue  → %d", v_blue);

    // Drive GPIO outputs to match the new state (relay, LED)
    if (state_changed) {
        nexus_gpio_apply_state();
    }

    // Publish updated telemetry so the App stays in sync after a command
    if (state_changed) {
        char telemetry[512];
        STATE_LOCK();
        nexus_device_state_t snap = g_device_state;
        STATE_UNLOCK();
        snprintf(telemetry, sizeof(telemetry),
            "{\"power\":%s,\"power_2\":%s,\"power_3\":%s,\"power_4\":%s,"
            "\"brightness\":%d,\"color_temp\":%d,"
            "\"red\":%u,\"green\":%u,\"blue\":%u,"
            "\"current_temp\":%.1f,\"humidity\":%.1f,"
            "\"motion\":%s,\"contact\":%s,"
            "\"target_temp\":%.1f,\"mode\":\"%s\"}",
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
            snap.hvac_mode
        );
        nexus_mqtt_publish_telemetry(telemetry);
    }
}

/**
 * Handles OTA trigger messages from the Nexus Hub App.
 * Payload: {"url":"https://...","hash":"sha256-of-binary"}
 */
static void handle_ota(const char *payload, int len) {
    char buf[512] = {0};
    if (len >= (int)sizeof(buf)) {
        ESP_LOGE(TAG, "OTA payload too large (%d bytes)", len);
        return;
    }
    memcpy(buf, payload, len);
    ESP_LOGI(TAG, "OTA trigger received. Handing off to nexus_ota...");
    nexus_ota_begin(buf);
}
