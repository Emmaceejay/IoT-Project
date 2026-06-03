/**
 * dsgv_firebase.c — Firebase HTTPS config fetch
 *
 * On every boot (after WiFi connects), this module calls the Firebase
 * Cloud Function to retrieve the latest broker config for this device.
 * The result is persisted to NVS so dsgv_mqtt.c always connects to the
 * correct broker, even after a firmware update that resets flash.
 *
 * Authentication: device_id (WiFi MAC) + auth_token (hardware entropy,
 * generated on first boot, never transmitted over MQTT).
 *
 * Dependencies (add to your CMakeLists.txt REQUIRES list):
 *   esp_http_client  json  nvs_flash  esp_wifi  mbedtls
 *
 * sdkconfig.defaults must include:
 *   CONFIG_ESP_HTTP_CLIENT_ENABLE_HTTPS=y
 *   CONFIG_MBEDTLS_CERTIFICATE_BUNDLE=y
 */

#include "dsgv_firebase.h"
#include "dsgv_config.h"
#include "dsgv_device_config.h"

#include "esp_http_client.h"
#include "esp_crt_bundle.h"
#include "esp_log.h"
#include "esp_wifi.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "cJSON.h"

#include <string.h>
#include <stdio.h>
#include <stdbool.h>

static const char *TAG = "DSGV_Firebase";

// Response buffer — 512 bytes is enough for the JSON config payload
#define RESP_BUF_SIZE 512
static char  s_resp_buf[RESP_BUF_SIZE];
static int   s_resp_len = 0;

// ── HTTP event handler ────────────────────────────────────────────────────────

static esp_err_t _http_event_cb(esp_http_client_event_t *evt)
{
    switch (evt->event_id) {
    case HTTP_EVENT_ON_DATA:
        if (!esp_http_client_is_chunked_response(evt->client)) {
            int copy = evt->data_len;
            if (s_resp_len + copy >= RESP_BUF_SIZE - 1) {
                copy = RESP_BUF_SIZE - 1 - s_resp_len;
            }
            if (copy > 0) {
                memcpy(s_resp_buf + s_resp_len, evt->data, copy);
                s_resp_len += copy;
                s_resp_buf[s_resp_len] = '\0';
            }
        }
        break;
    case HTTP_EVENT_ON_FINISH:
    case HTTP_EVENT_DISCONNECTED:
    case HTTP_EVENT_ERROR:
    default:
        break;
    }
    return ESP_OK;
}

// ── Public API ────────────────────────────────────────────────────────────────

esp_err_t dsgv_firebase_fetch_config(void)
{
    // Need auth token to authenticate
    if (g_device_config.auth_token[0] == '\0') {
        ESP_LOGW(TAG, "Auth token not set — skipping Firebase fetch");
        return ESP_FAIL;
    }

    // Derive device_id from WiFi station MAC (12 uppercase hex chars)
    uint8_t mac[6];
    if (esp_wifi_get_mac(WIFI_IF_STA, mac) != ESP_OK) {
        ESP_LOGE(TAG, "Failed to read WiFi MAC");
        return ESP_FAIL;
    }
    char device_id[13];
    snprintf(device_id, sizeof(device_id),
             "%02X%02X%02X%02X%02X%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);

    // Build JSON payload: {"device_id":"AABBCCDDEEFF","auth_token":"ABC123..."}
    cJSON *body = cJSON_CreateObject();
    cJSON_AddStringToObject(body, "device_id",  device_id);
    cJSON_AddStringToObject(body, "auth_token", g_device_config.auth_token);
    char *payload = cJSON_PrintUnformatted(body);
    cJSON_Delete(body);
    if (!payload) {
        return ESP_ERR_NO_MEM;
    }

    // Reset response buffer
    s_resp_len = 0;
    memset(s_resp_buf, 0, sizeof(s_resp_buf));

    // HTTPS POST with ESP-IDF built-in certificate bundle (covers Google/Firebase CAs)
    esp_http_client_config_t cfg = {
        .url               = FIREBASE_GET_CONFIG_URL,
        .event_handler     = _http_event_cb,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .timeout_ms        = FIREBASE_TIMEOUT_MS,
        .method            = HTTP_METHOD_POST,
    };

    esp_http_client_handle_t client = esp_http_client_init(&cfg);
    if (!client) {
        free(payload);
        ESP_LOGE(TAG, "HTTP client init failed");
        return ESP_FAIL;
    }

    esp_http_client_set_header(client, "Content-Type", "application/json");
    esp_http_client_set_post_field(client, payload, strlen(payload));
    free(payload);

    esp_err_t err       = esp_http_client_perform(client);
    int       http_code = esp_http_client_get_status_code(client);
    esp_http_client_cleanup(client);

    if (err != ESP_OK) {
        ESP_LOGW(TAG, "HTTPS request failed: %s — using cached config",
                 esp_err_to_name(err));
        return ESP_FAIL;
    }

    if (http_code != 200) {
        ESP_LOGW(TAG, "Firebase returned HTTP %d — using cached config", http_code);
        return ESP_FAIL;
    }

    // ── Parse JSON response ───────────────────────────────────────────────────

    cJSON *resp = cJSON_Parse(s_resp_buf);
    if (!resp) {
        ESP_LOGW(TAG, "Failed to parse Firebase response: %s", s_resp_buf);
        return ESP_FAIL;
    }

    cJSON *j_host = cJSON_GetObjectItem(resp, "broker_host");
    cJSON *j_port = cJSON_GetObjectItem(resp, "broker_port");
    cJSON *j_tls  = cJSON_GetObjectItem(resp, "broker_tls");
    cJSON *j_user = cJSON_GetObjectItem(resp, "broker_username");
    cJSON *j_pass = cJSON_GetObjectItem(resp, "broker_password");

    if (!cJSON_IsString(j_host) || !cJSON_IsNumber(j_port)) {
        ESP_LOGW(TAG, "Incomplete config in Firebase response");
        cJSON_Delete(resp);
        return ESP_FAIL;
    }

    const char *broker_host = j_host->valuestring;
    int         broker_port = (int)j_port->valuedouble;
    bool        broker_tls  = cJSON_IsTrue(j_tls);
    const char *broker_user = cJSON_IsString(j_user) ? j_user->valuestring : "";
    const char *broker_pass = cJSON_IsString(j_pass) ? j_pass->valuestring : "";

    // ── Persist to NVS (mqtt_cfg namespace — read by dsgv_mqtt.c on connect) ──

    nvs_handle_t nvs;
    esp_err_t    ret = nvs_open(MQTT_CFG_NVS_NS, NVS_READWRITE, &nvs);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "NVS open failed: %s", esp_err_to_name(ret));
        cJSON_Delete(resp);
        return ret;
    }

    nvs_set_str(nvs, "host",     broker_host);
    nvs_set_i32(nvs, "port",     broker_port);
    nvs_set_u8 (nvs, "tls",      broker_tls ? 1 : 0);
    nvs_set_str(nvs, "username", broker_user);
    nvs_set_str(nvs, "password", broker_pass);
    ret = nvs_commit(nvs);
    nvs_close(nvs);

    cJSON_Delete(resp);

    if (ret == ESP_OK) {
        ESP_LOGI(TAG, "Broker config updated: %s:%d (TLS=%d)",
                 broker_host, broker_port, (int)broker_tls);
    } else {
        ESP_LOGE(TAG, "NVS commit failed: %s", esp_err_to_name(ret));
    }

    return ret;
}
