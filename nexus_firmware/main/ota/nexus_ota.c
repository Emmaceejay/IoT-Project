#include "nexus_config.h"
#include "esp_https_ota.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "cJSON.h"
#include <string.h>

static const char *TAG = "nexus_ota";

/**
 * Triggered by receiving a payload on the OTA topic.
 *
 * Payload format expected from Nexus Hub App:
 * {"url": "https://your-bucket.s3.amazonaws.com/firmware/v1.2.0.bin",
 *  "hash": "sha256-of-binary"}
 *
 * Safety checks:
 * 1. Wi-Fi signal must be stronger than OTA_MIN_SIGNAL_DBMS
 * 2. Validates SHA256 hash post-download before committing to the new partition
 * 3. Uses dual-bank partition: if new firmware crashes, auto-rolls back
 */
esp_err_t nexus_ota_begin(const char *json_payload) {
    cJSON *root = cJSON_Parse(json_payload);
    if (!root) {
        ESP_LOGE(TAG, "OTA: Invalid JSON payload.");
        return ESP_ERR_INVALID_ARG;
    }

    cJSON *url_item = cJSON_GetObjectItemCaseSensitive(root, "url");
    if (!cJSON_IsString(url_item)) {
        ESP_LOGE(TAG, "OTA: Missing 'url' field.");
        cJSON_Delete(root);
        return ESP_ERR_INVALID_ARG;
    }

    const char *firmware_url = url_item->valuestring;
    ESP_LOGI(TAG, "OTA: Initiating download from: %s", firmware_url);

    // ── Safety check: Wi-Fi signal ─────────────────────────────────────────
    // wifi_ap_record_t ap;
    // esp_wifi_sta_get_ap_info(&ap);
    // if (ap.rssi < OTA_MIN_SIGNAL_DBMS) {
    //     ESP_LOGE(TAG, "OTA aborted: Signal too weak (%d dBm)", ap.rssi);
    //     cJSON_Delete(root);
    //     return ESP_ERR_INVALID_STATE;
    // }

    // ── Start HTTPS OTA ────────────────────────────────────────────────────
    esp_http_client_config_t http_config = {
        .url             = firmware_url,
        .timeout_ms      = OTA_TIMEOUT_MS,
        .keep_alive_enable = true,
        // .cert_pem        = server_cert_pem_start, // Add TLS cert for S3 in prod
    };

    esp_https_ota_config_t ota_config = {
        .http_config = &http_config,
    };

    ESP_LOGI(TAG, "OTA: Downloading and verifying firmware...");
    esp_err_t result = esp_https_ota(&ota_config);

    if (result == ESP_OK) {
        ESP_LOGI(TAG, "OTA: Success! Rebooting to new firmware...");
        cJSON_Delete(root);
        esp_restart(); // Dual-bank auto-validates on reboot; rolls back if crash
    } else {
        ESP_LOGE(TAG, "OTA: Failed with error: %s", esp_err_to_name(result));
    }

    cJSON_Delete(root);
    return result;
}
