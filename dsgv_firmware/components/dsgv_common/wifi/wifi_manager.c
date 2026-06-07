#include "wifi_manager.h"
#include "dsgv_config.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "nvs.h"
#include <string.h>

static const char *TAG = "wifi_manager";
static bool s_connected      = false;
static bool s_stop_reconnect = false;

static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                                int32_t event_id, void *event_data) {
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        s_connected = false;
        if (!s_stop_reconnect) {
            ESP_LOGW(TAG, "Wi-Fi disconnected. Retrying...");
            esp_wifi_connect();
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
        ESP_LOGI(TAG, "Got IP: " IPSTR, IP2STR(&event->ip_info.ip));
        s_connected = true;
    }
}

esp_err_t wifi_manager_connect(void) {
    nvs_handle_t nvs;
    esp_err_t err = nvs_open("wifi_creds", NVS_READONLY, &nvs);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "No Wi-Fi credentials in NVS. Entering provisioning mode.");
        return ESP_ERR_NOT_FOUND;
    }

    char ssid[64] = {0};
    char password[128] = {0};
    size_t ssid_len = sizeof(ssid);
    size_t pass_len = sizeof(password);

    nvs_get_str(nvs, "ssid", ssid, &ssid_len);
    nvs_get_str(nvs, "password", password, &pass_len);
    nvs_close(nvs);

    // Guard against a corrupt or partially-written NVS record where the key
    // exists but the SSID value is empty — treat it the same as no credentials.
    if (ssid[0] == '\0') {
        ESP_LOGW(TAG, "NVS has a credential record but SSID is empty — treating as unprovisioned.");
        return ESP_ERR_NOT_FOUND;
    }

    // Initialise the Wi-Fi driver. Must be called once before any esp_wifi_*
    // function. WIFI_INIT_CONFIG_DEFAULT() sets conservative stack/buffer sizes
    // suitable for production; adjust via menuconfig if needed.
    wifi_init_config_t wifi_init_cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&wifi_init_cfg));

    // Register event handlers
    esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_event_handler, NULL);
    esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, wifi_event_handler, NULL);

    wifi_config_t wifi_config = {};
    strlcpy((char *)wifi_config.sta.ssid, ssid, sizeof(wifi_config.sta.ssid));
    strlcpy((char *)wifi_config.sta.password, password, sizeof(wifi_config.sta.password));

    esp_wifi_set_mode(WIFI_MODE_STA);
    esp_wifi_set_config(WIFI_IF_STA, &wifi_config);
    esp_wifi_start();
    esp_wifi_connect();

    ESP_LOGI(TAG, "Connecting to SSID: %s", ssid);
    return ESP_OK;
}

esp_err_t wifi_manager_save_credentials(const char *ssid, const char *password) {
    nvs_handle_t nvs;
    ESP_ERROR_CHECK(nvs_open("wifi_creds", NVS_READWRITE, &nvs));
    nvs_set_str(nvs, "ssid", ssid);
    nvs_set_str(nvs, "password", password);
    nvs_commit(nvs);
    nvs_close(nvs);
    ESP_LOGI(TAG, "Wi-Fi credentials saved to NVS for SSID: %s", ssid);
    return ESP_OK;
}

esp_err_t wifi_manager_factory_reset(void) {
    nvs_handle_t nvs;
    if (nvs_open("wifi_creds", NVS_READWRITE, &nvs) == ESP_OK) {
        nvs_erase_all(nvs);
        nvs_commit(nvs);
        nvs_close(nvs);
    }
    ESP_LOGW(TAG, "Factory reset complete. Rebooting...");
    esp_restart();
    return ESP_OK;
}

bool wifi_manager_is_connected(void) {
    return s_connected;
}

void wifi_manager_stop_reconnect(void) {
    s_stop_reconnect = true;
    esp_wifi_disconnect();   // triggers STA_DISCONNECTED, but flag prevents retry
    ESP_LOGI(TAG, "Reconnect loop stopped.");
}

esp_err_t wifi_manager_start_ap(void) {
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP);

    // Stop STA driver cleanly before switching to AP mode
    s_stop_reconnect = true;
    esp_wifi_disconnect();
    esp_wifi_stop();

    char ssid[32];
    snprintf(ssid, sizeof(ssid), "DSGV_Setup_%02X%02X%02X",
             mac[3], mac[4], mac[5]);

    wifi_config_t ap_cfg = {
        .ap = {
            .channel         = 1,
            .authmode        = WIFI_AUTH_OPEN,
            .max_connection  = 4,
            .beacon_interval = 100,
        }
    };
    strlcpy((char *)ap_cfg.ap.ssid, ssid, sizeof(ap_cfg.ap.ssid));
    ap_cfg.ap.ssid_len = (uint8_t)strlen(ssid);

    esp_err_t err;
    err = esp_wifi_set_mode(WIFI_MODE_AP);      if (err != ESP_OK) return err;
    err = esp_wifi_set_config(WIFI_IF_AP, &ap_cfg); if (err != ESP_OK) return err;
    err = esp_wifi_start();                     if (err != ESP_OK) return err;

    ESP_LOGI(TAG, "Setup AP started — SSID: %s  IP: 192.168.4.1", ssid);
    return ESP_OK;
}

// ── Provisioning-time Wi-Fi scan ──────────────────────────────────────────────

// Write a JSON-safe quoted string into buf[off], return new offset.
static size_t _json_str(char *buf, size_t cap, size_t off, const char *s) {
    if (off + 3 >= cap) return off;
    buf[off++] = '"';
    for (; *s && off + 2 < cap; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { buf[off++] = '\\'; buf[off++] = (char)c; }
        else if (c >= 0x20)         { buf[off++] = (char)c; }
        // control chars silently dropped
    }
    buf[off++] = '"';
    return off;
}

esp_err_t wifi_manager_scan_networks(char *json_out, size_t json_len) {
    // Initialise Wi-Fi driver only if it hasn't been started yet.
    wifi_mode_t mode;
    if (esp_wifi_get_mode(&mode) == ESP_ERR_WIFI_NOT_INIT) {
        wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
        esp_err_t err = esp_wifi_init(&cfg);
        if (err != ESP_OK) {
            snprintf(json_out, json_len, "[]");
            return err;
        }
        esp_wifi_set_mode(WIFI_MODE_STA);
        esp_wifi_start();
    }

    ESP_LOGI(TAG, "Scanning for Wi-Fi networks…");
    esp_err_t err = esp_wifi_scan_start(NULL, true); // blocking ~2 s
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Wi-Fi scan failed: %d", err);
        snprintf(json_out, json_len, "[]");
        return err;
    }

    uint16_t count = 15;
    wifi_ap_record_t recs[15];
    esp_wifi_scan_get_ap_records(&count, recs);

    // Serialize to JSON array; deduplicate SSIDs; skip hidden networks.
    size_t off = 0;
    json_out[off++] = '[';
    bool first = true;
    // Keep track of SSIDs already written to avoid duplicates.
    // Points into recs[].ssid which is valid for the lifetime of this function.
    const char *seen[15];
    int seen_n = 0;

    for (int i = 0; i < (int)count && off < json_len - 64; i++) {
        const char *ssid = (const char *)recs[i].ssid;
        if (ssid[0] == '\0') continue;      // hidden network — skip

        bool dup = false;
        for (int j = 0; j < seen_n; j++) {
            if (strcmp(seen[j], ssid) == 0) { dup = true; break; }
        }
        if (dup) continue;
        if (seen_n < 15) seen[seen_n++] = ssid;

        if (!first) json_out[off++] = ',';
        first = false;

        memcpy(json_out + off, "{\"ssid\":", 8); off += 8;
        off = _json_str(json_out, json_len - 16, off, ssid);
        off += snprintf(json_out + off, json_len - off, ",\"rssi\":%d}", recs[i].rssi);
    }
    json_out[off++] = ']';
    json_out[off]   = '\0';

    ESP_LOGI(TAG, "Wi-Fi scan complete: %d network(s) → %zu bytes JSON", seen_n, off);
    return ESP_OK;
}
