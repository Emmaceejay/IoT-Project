#include "nexus_config.h"
#include "wifi_manager.h"
#include "mqtt_client.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "cJSON.h"
#include <stdio.h>
#include <string.h>

static const char *TAG = "nexus_mqtt";
static esp_mqtt_client_handle_t s_client = NULL;
static char s_device_topic_status[64];
static char s_device_topic_telemetry[64];
static char s_device_topic_command[64];
static char s_device_id[18]; // MAC address string

// ── Forward declarations ──────────────────────────────────────────────────────
static void mqtt_event_handler(void *arg, esp_event_base_t base,
                                int32_t event_id, void *event_data);
static void publish_online_status(void);
static void handle_command(const char *payload, int len);

/**
 * Constructs device-specific topics using MAC address as unique device ID.
 * Ensures every device on the fleet has globally unique MQTT topics.
 */
static void build_topics(void) {
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    snprintf(s_device_id, sizeof(s_device_id), "%02X%02X%02X%02X%02X%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);

    snprintf(s_device_topic_status,    sizeof(s_device_topic_status),
             MQTT_TOPIC_STATUS,    s_device_id);
    snprintf(s_device_topic_telemetry, sizeof(s_device_topic_telemetry),
             MQTT_TOPIC_TELEMETRY, s_device_id);
    snprintf(s_device_topic_command,   sizeof(s_device_topic_command),
             MQTT_TOPIC_COMMAND,   s_device_id);
}

/**
 * Initializes and starts the MQTT client.
 * Attempts TLS connection to EMQX Cloud first.
 * TODO: Add mDNS discovery to fall back to local Mosquitto if cloud unreachable.
 */
esp_err_t nexus_mqtt_start(void) {
    build_topics();

    esp_mqtt_client_config_t mqtt_cfg = {
        .broker = {
            .address = {
                .hostname = MQTT_CLOUD_HOST,
                .port     = MQTT_CLOUD_PORT,
                .transport = MQTT_TRANSPORT_OVER_SSL,
            },
        },
        .credentials = {
            .client_id = s_device_id,
        },
        .session = {
            .keepalive   = MQTT_KEEPALIVE_SEC,
            // Last Will and Testament — broker publishes this if device drops
            .last_will = {
                .topic   = s_device_topic_status,
                .msg     = MQTT_LWT_PAYLOAD_OFFLINE,
                .msg_len = sizeof(MQTT_LWT_PAYLOAD_OFFLINE) - 1,
                .qos     = MQTT_QOS_AT_LEAST_ONCE,
                .retain  = true,
            },
        },
    };

    s_client = esp_mqtt_client_init(&mqtt_cfg);
    esp_mqtt_client_register_event(s_client, ESP_EVENT_ANY_ID,
                                    mqtt_event_handler, NULL);
    return esp_mqtt_client_start(s_client);
}

static void mqtt_event_handler(void *arg, esp_event_base_t base,
                                int32_t event_id, void *event_data) {
    esp_mqtt_event_handle_t event = (esp_mqtt_event_handle_t)event_data;

    switch (event->event_id) {
        case MQTT_EVENT_CONNECTED:
            ESP_LOGI(TAG, "MQTT Connected. Device ID: %s", s_device_id);

            // Announce online status (retained — app sees it immediately on subscribe)
            publish_online_status();

            // Subscribe to our command topic to receive app instructions
            esp_mqtt_client_subscribe(s_client, s_device_topic_command,
                                       MQTT_QOS_AT_LEAST_ONCE);

            // Subscribe to OTA trigger topic
            char ota_topic[64];
            snprintf(ota_topic, sizeof(ota_topic), MQTT_TOPIC_OTA, s_device_id);
            esp_mqtt_client_subscribe(s_client, ota_topic, MQTT_QOS_AT_LEAST_ONCE);
            break;

        case MQTT_EVENT_DISCONNECTED:
            ESP_LOGW(TAG, "MQTT Disconnected. Will retry...");
            break;

        case MQTT_EVENT_DATA:
            ESP_LOGI(TAG, "Received on topic: %.*s", event->topic_len, event->topic);
            handle_command(event->data, event->data_len);
            break;

        case MQTT_EVENT_ERROR:
            ESP_LOGE(TAG, "MQTT Error. Broker may be unreachable.");
            // TODO: Trigger mDNS local fallback here
            break;

        default:
            break;
    }
}

static void publish_online_status(void) {
    esp_mqtt_client_publish(s_client, s_device_topic_status,
                             MQTT_LWT_PAYLOAD_ONLINE,
                             sizeof(MQTT_LWT_PAYLOAD_ONLINE) - 1,
                             MQTT_QOS_AT_LEAST_ONCE, /*retain=*/true);
    ESP_LOGI(TAG, "Published: online → %s", s_device_topic_status);
}

/**
 * Publishes a JSON telemetry snapshot to the cloud.
 * Called by GPIO layer whenever sensor data changes.
 */
void nexus_mqtt_publish_telemetry(const char *json_payload) {
    if (!s_client) return;
    esp_mqtt_client_publish(s_client, s_device_topic_telemetry,
                             json_payload, strlen(json_payload),
                             MQTT_QOS_AT_LEAST_ONCE, /*retain=*/false);
}

/**
 * Handles incoming JSON commands from the Nexus Hub app.
 * Example payload: {"power": true, "brightness": 75}
 */
static void handle_command(const char *payload, int len) {
    char buf[256] = {0};
    if (len >= (int)sizeof(buf)) return;
    memcpy(buf, payload, len);

    cJSON *root = cJSON_Parse(buf);
    if (!root) {
        ESP_LOGE(TAG, "Invalid JSON command: %s", buf);
        return;
    }

    cJSON *power = cJSON_GetObjectItemCaseSensitive(root, "power");
    if (cJSON_IsBool(power)) {
        bool on = cJSON_IsTrue(power);
        ESP_LOGI(TAG, "Command: power=%s", on ? "ON" : "OFF");
        // TODO: gpio_relay_set(on);
    }

    cJSON *brightness = cJSON_GetObjectItemCaseSensitive(root, "brightness");
    if (cJSON_IsNumber(brightness)) {
        int pct = (int)brightness->valuedouble;
        ESP_LOGI(TAG, "Command: brightness=%d%%", pct);
        // TODO: gpio_dimmer_set(pct);
    }

    cJSON_Delete(root);
}
