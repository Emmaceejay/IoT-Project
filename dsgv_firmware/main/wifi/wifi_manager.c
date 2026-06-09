#include "wifi_manager.h"
#include "dsgv_config.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "nvs.h"
#include <string.h>

static const char *TAG = "wifi_manager";

static bool s_connected = false;
static bool s_ap_mode   = false;

static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                                int32_t event_id, void *event_data)
{
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        ESP_LOGW(TAG, "Wi-Fi disconnected. Retrying...");
        s_connected = false;
        esp_wifi_connect();
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
        ESP_LOGI(TAG, "Got IP: " IPSTR, IP2STR(&event->ip_info.ip));
        s_connected = true;

        if (s_ap_mode) {
            esp_wifi_set_mode(WIFI_MODE_STA);
            s_ap_mode = false;
            ESP_LOGI(TAG, "AP stopped — device connected to home Wi-Fi");
        }
    }
}

esp_err_t wifi_manager_connect(void) {
    nvs_handle_t nvs;
    esp_err_t err = nvs_open("wifi_creds", NVS_READONLY, &nvs);

    char ssid[64]      = {0};
    char password[128] = {0};
    bool has_creds = (err == ESP_OK);

    if (has_creds) {
        size_t ssid_len = sizeof(ssid);
        size_t pass_len = sizeof(password);
        nvs_get_str(nvs, "ssid",     ssid,     &ssid_len);
        nvs_get_str(nvs, "password", password, &pass_len);
        nvs_close(nvs);
    } else {
        ESP_LOGW(TAG, "No Wi-Fi credentials in NVS. Entering provisioning mode.");
    }

    wifi_init_config_t wifi_init_cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&wifi_init_cfg));
    esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID,    wifi_event_handler, NULL);
    esp_event_handler_register(IP_EVENT,   IP_EVENT_STA_GOT_IP, wifi_event_handler, NULL);

    if (!has_creds) {
        uint8_t mac[6];
        esp_wifi_get_mac(WIFI_IF_AP, mac);

        wifi_config_t ap_cfg = {
            .ap = {
                .channel        = 1,
                .authmode       = WIFI_AUTH_WPA2_PSK,
                .max_connection = 1,
            },
        };
        snprintf((char *)ap_cfg.ap.ssid, 32, "%s%02X%02X%02X",
                 DSGV_AP_SSID_PREFIX, mac[3], mac[4], mac[5]);
        strlcpy((char *)ap_cfg.ap.password, DSGV_AP_PASSWORD,
                sizeof(ap_cfg.ap.password));

        esp_wifi_set_mode(WIFI_MODE_APSTA);
        esp_wifi_set_config(WIFI_IF_AP, &ap_cfg);
        esp_wifi_start();
        s_ap_mode = true;

        ESP_LOGI(TAG, "AP started: SSID=%s (BLE provisioning also active)",
                 (char *)ap_cfg.ap.ssid);
        return ESP_ERR_NOT_FOUND;
    }

    wifi_config_t wifi_config = {};
    strlcpy((char *)wifi_config.sta.ssid,     ssid,     sizeof(wifi_config.sta.ssid));
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
    nvs_set_str(nvs, "ssid",     ssid);
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

bool wifi_manager_is_ap_mode(void) {
    return s_ap_mode;
}
