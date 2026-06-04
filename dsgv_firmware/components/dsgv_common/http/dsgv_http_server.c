/**
 * DSGV_http_server.c — Local HTTP Transport (Tasmota-Compatible REST API)
 *
 * Activated when the DSGV Hub App detects it is on the same Wi-Fi network
 * as the device. Provides two-way control without any broker or internet.
 *
 * Endpoints:
 *   GET  /api/status     → Full JSON state snapshot (read by App)
 *   POST /api/cmd        → {"capability":"power","value":true}
 *   GET  /cm?cmnd=<cmd>  → Tasmota compatibility layer
 *                          Supported: Power ON/OFF, Dimmer N, CT N (mired)
 *
 * After any state change the updated state is published via MQTT telemetry
 * so the cloud/local broker view stays in sync with direct-HTTP changes.
 */

#include "dsgv_http_server.h"
#include "dsgv_config.h"
#include "dsgv_device_state.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "cJSON.h"
#include <string.h>
#include <stdlib.h>

static const char *TAG = "DSGV_http";
static httpd_handle_t s_server = NULL;

// Forward declarations
static esp_err_t handle_status_get(httpd_req_t *req);
static esp_err_t handle_cmd_post(httpd_req_t *req);
static esp_err_t handle_tasmota_get(httpd_req_t *req);
static void apply_capability(const char *capability, cJSON *value);
static void apply_tasmota_cmd(const char *cmnd);
static void build_status_json(char *buf, size_t buf_size);

// Declared in DSGV_mqtt.c — call after local HTTP changes state so broker
// view stays in sync.
extern void DSGV_mqtt_publish_telemetry(const char *json_payload);
extern void DSGV_gpio_apply_state(void);

// ── Route table ──────────────────────────────────────────────────────────────

static const httpd_uri_t s_routes[] = {
    {
        .uri     = "/api/status",
        .method  = HTTP_GET,
        .handler = handle_status_get,
    },
    {
        .uri     = "/api/cmd",
        .method  = HTTP_POST,
        .handler = handle_cmd_post,
    },
    {
        .uri     = "/cm",
        .method  = HTTP_GET,
        .handler = handle_tasmota_get,
    },
};

// ── Public API ───────────────────────────────────────────────────────────────

esp_err_t DSGV_http_server_start(void) {
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.server_port   = HTTP_SERVER_PORT;
    config.stack_size    = 8192;

    esp_err_t err = httpd_start(&s_server, &config);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to start HTTP server: %s", esp_err_to_name(err));
        return err;
    }

    for (int i = 0; i < sizeof(s_routes) / sizeof(s_routes[0]); i++) {
        httpd_register_uri_handler(s_server, &s_routes[i]);
    }

    ESP_LOGI(TAG, "HTTP server started on port %d", HTTP_SERVER_PORT);
    return ESP_OK;
}

void DSGV_http_server_stop(void) {
    if (s_server) {
        httpd_stop(s_server);
        s_server = NULL;
        ESP_LOGI(TAG, "HTTP server stopped.");
    }
}

// ── GET /api/status ───────────────────────────────────────────────────────────

static esp_err_t handle_status_get(httpd_req_t *req) {
    char buf[HTTP_MAX_RESP_SIZE];
    build_status_json(buf, sizeof(buf));

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_sendstr(req, buf);

    ESP_LOGI(TAG, "GET /api/status → %s", buf);
    return ESP_OK;
}

// ── POST /api/cmd ─────────────────────────────────────────────────────────────

static esp_err_t handle_cmd_post(httpd_req_t *req) {
    char body[HTTP_MAX_BODY_SIZE] = {0};
    int  received = httpd_req_recv(req, body,
                                   sizeof(body) - 1 < (size_t)req->content_len
                                       ? sizeof(body) - 1
                                       : req->content_len);
    if (received <= 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Empty body");
        return ESP_FAIL;
    }
    body[received] = '\0';

    // Parse: {"capability": "power", "value": true}
    cJSON *root = cJSON_Parse(body);
    if (!root) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid JSON");
        return ESP_FAIL;
    }

    cJSON *cap = cJSON_GetObjectItemCaseSensitive(root, "capability");
    cJSON *val = cJSON_GetObjectItemCaseSensitive(root, "value");

    if (!cJSON_IsString(cap) || !val) {
        cJSON_Delete(root);
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST,
                            "Missing 'capability' or 'value'");
        return ESP_FAIL;
    }

    char cap_name[32];
    strlcpy(cap_name, cap->valuestring, sizeof(cap_name));

    apply_capability(cap_name, val);
    cJSON_Delete(root);

    // Publish updated state via MQTT so broker view stays in sync
    char telemetry[HTTP_MAX_RESP_SIZE];
    build_status_json(telemetry, sizeof(telemetry));
    DSGV_mqtt_publish_telemetry(telemetry);

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_sendstr(req, "{\"ok\":true}");

    ESP_LOGI(TAG, "POST /api/cmd capability=%s", cap_name);
    return ESP_OK;
}

// ── GET /cm?cmnd=<tasmota_command> ───────────────────────────────────────────
// Tasmota compatibility: Power ON/OFF, Dimmer N, CT N (mired)

static esp_err_t handle_tasmota_get(httpd_req_t *req) {
    char query[128] = {0};
    if (httpd_req_get_url_query_str(req, query, sizeof(query)) != ESP_OK) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing query string");
        return ESP_FAIL;
    }

    char cmnd[64] = {0};
    if (httpd_query_key_value(query, "cmnd", cmnd, sizeof(cmnd)) != ESP_OK) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing 'cmnd' param");
        return ESP_FAIL;
    }

    // URL-decode: %20 → space (minimal decode for common cases)
    for (char *p = cmnd; *p; p++) {
        if (*p == '+') *p = ' ';
    }
    // Full percent-decode of %XX sequences
    char decoded[64] = {0};
    size_t j = 0;
    for (size_t i = 0; cmnd[i] && j < sizeof(decoded) - 1; i++) {
        if (cmnd[i] == '%' && cmnd[i+1] && cmnd[i+2]) {
            char hex[3] = {cmnd[i+1], cmnd[i+2], '\0'};
            decoded[j++] = (char)strtol(hex, NULL, 16);
            i += 2;
        } else {
            decoded[j++] = cmnd[i];
        }
    }
    decoded[j] = '\0';

    apply_tasmota_cmd(decoded);

    // Publish updated state via MQTT
    char telemetry[HTTP_MAX_RESP_SIZE];
    build_status_json(telemetry, sizeof(telemetry));
    DSGV_mqtt_publish_telemetry(telemetry);

    // Respond in Tasmota-compatible JSON
    char resp[HTTP_MAX_RESP_SIZE];
    build_status_json(resp, sizeof(resp));
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_sendstr(req, resp);

    ESP_LOGI(TAG, "GET /cm?cmnd=%s", decoded);
    return ESP_OK;
}

// ── Internal helpers ──────────────────────────────────────────────────────────

/**
 * Builds the current device state as a JSON string.
 * Format matches the device telemetry schema in the Flutter app.
 */
static void build_status_json(char *buf, size_t buf_size) {
    STATE_LOCK();
    DSGV_device_state_t snap = g_device_state;
    STATE_UNLOCK();

    snprintf(buf, buf_size,
        "{"
        "\"power\":%s,"
        "\"power_2\":%s,"
        "\"power_3\":%s,"
        "\"power_4\":%s,"
        "\"brightness\":%d,"
        "\"color_temp\":%d,"
        "\"red\":%u,"
        "\"green\":%u,"
        "\"blue\":%u,"
        "\"current_temp\":%.1f,"
        "\"humidity\":%.1f,"
        "\"motion\":%s,"
        "\"contact\":%s,"
        "\"target_temp\":%.1f,"
        "\"mode\":\"%s\","
        "\"local_ip\":\"%s\""
        "}",
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
        snap.local_ip
    );
}

/**
 * Applies a DSGV capability command to g_device_state and drives GPIO.
 * Mirrors LocalHttpService._toTasmotaCommand() on the app side.
 */
static void apply_capability(const char *capability, cJSON *value) {
    STATE_LOCK();

    if (strcmp(capability, "power") == 0 && cJSON_IsBool(value)) {
        g_device_state.relay_states[0] = cJSON_IsTrue(value);
    } else if (strcmp(capability, "power_2") == 0 && cJSON_IsBool(value)) {
        g_device_state.relay_states[1] = cJSON_IsTrue(value);
    } else if (strcmp(capability, "power_3") == 0 && cJSON_IsBool(value)) {
        g_device_state.relay_states[2] = cJSON_IsTrue(value);
    } else if (strcmp(capability, "power_4") == 0 && cJSON_IsBool(value)) {
        g_device_state.relay_states[3] = cJSON_IsTrue(value);
    } else if (strcmp(capability, "brightness") == 0 && cJSON_IsNumber(value)) {
        int pct = (int)value->valuedouble;
        if (pct < 0) pct = 0;
        if (pct > 100) pct = 100;
        g_device_state.brightness = pct;
    } else if (strcmp(capability, "color_temp") == 0 && cJSON_IsNumber(value)) {
        // App sends Kelvin
        int k = (int)value->valuedouble;
        if (k < 1000) k = 1000;
        if (k > 10000) k = 10000;
        g_device_state.color_temp_k = k;
    } else if (strcmp(capability, "target_temp") == 0 && cJSON_IsNumber(value)) {
        g_device_state.target_temp = (float)value->valuedouble;
        ESP_LOGI(TAG, "HTTP target_temp: %.1f C", g_device_state.target_temp);
    } else if (strcmp(capability, "mode") == 0 && cJSON_IsString(value)) {
        const char *m = value->valuestring;
        if (strcmp(m, "cool") == 0 || strcmp(m, "heat") == 0 ||
            strcmp(m, "auto") == 0 || strcmp(m, "off")  == 0) {
            strlcpy(g_device_state.hvac_mode, m, sizeof(g_device_state.hvac_mode));
            ESP_LOGI(TAG, "HTTP hvac_mode: %s", g_device_state.hvac_mode);
        } else {
            ESP_LOGW(TAG, "HTTP mode '%s' rejected — unknown value", m);
        }
    } else if (strcmp(capability, "red") == 0 && cJSON_IsNumber(value)) {
        int v = (int)value->valuedouble;
        if (v < 0) v = 0;
        if (v > 255) v = 255;
        g_device_state.rgb_r = (uint8_t)v;
    } else if (strcmp(capability, "green") == 0 && cJSON_IsNumber(value)) {
        int v = (int)value->valuedouble;
        if (v < 0) v = 0;
        if (v > 255) v = 255;
        g_device_state.rgb_g = (uint8_t)v;
    } else if (strcmp(capability, "blue") == 0 && cJSON_IsNumber(value)) {
        int v = (int)value->valuedouble;
        if (v < 0) v = 0;
        if (v > 255) v = 255;
        g_device_state.rgb_b = (uint8_t)v;
    } else {
        ESP_LOGW(TAG, "Unknown capability: %s", capability);
    }

    STATE_UNLOCK();

    DSGV_gpio_apply_state();
}

/**
 * Parses Tasmota cmnd syntax and maps to g_device_state.
 *   Power ON/OFF  → power
 *   Dimmer N      → brightness (0-100)
 *   CT N          → color_temp_k (mired→Kelvin: 1 000 000/N)
 */
static void apply_tasmota_cmd(const char *cmnd) {
    STATE_LOCK();

    if (strncasecmp(cmnd, "Power ON", 8) == 0) {
        g_device_state.relay_states[0] = true;
    } else if (strncasecmp(cmnd, "Power OFF", 9) == 0) {
        g_device_state.relay_states[0] = false;
    } else if (strncasecmp(cmnd, "Dimmer ", 7) == 0) {
        int pct = atoi(cmnd + 7);
        if (pct < 0) pct = 0;
        if (pct > 100) pct = 100;
        g_device_state.brightness = pct;
    } else if (strncasecmp(cmnd, "CT ", 3) == 0) {
        int mired = atoi(cmnd + 3);
        if (mired > 0) {
            g_device_state.color_temp_k = 1000000 / mired;
        }
    } else if (strncasecmp(cmnd, "TempTarget ", 11) == 0) {
        g_device_state.target_temp = (float)atof(cmnd + 11);
    } else {
        ESP_LOGW(TAG, "Unknown Tasmota cmnd: %s", cmnd);
    }

    STATE_UNLOCK();
    DSGV_gpio_apply_state();
}
