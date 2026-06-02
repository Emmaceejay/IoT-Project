#include "dsgv_config.h"
#include "esp_https_ota.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_wifi.h"
#include "cJSON.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <string.h>

static const char *TAG = "DSGV_ota";

// Declared in dsgv_mqtt.c — publish progress telemetry during OTA.
extern void DSGV_mqtt_publish_telemetry(const char *json_payload);

/**
 * Triggered by receiving a payload on the OTA topic.
 *
 * Payload format expected from DSGV Hub App:
 * {"url": "https://your-bucket.s3.amazonaws.com/firmware/v1.2.0.bin",
 *  "hash": "sha256-of-binary"}
 *
 * Safety checks:
 * 1. Wi-Fi signal must be stronger than OTA_MIN_SIGNAL_DBMS
 * 2. Uses chunked download API so the app receives live ota_progress (0-100)
 * 3. Uses dual-bank partition: if new firmware crashes, auto-rolls back
 *
 * NOTE: SHA256 hash field is accepted in the payload for future validation.
 * Full hash verification requires enabling secure boot (sdkconfig).
 */
esp_err_t DSGV_ota_begin(const char *json_payload) {
    cJSON *root = cJSON_Parse(json_payload);
    if (!root) {
        ESP_LOGE(TAG, "OTA: Invalid JSON payload.");
        return ESP_ERR_INVALID_ARG;
    }

    cJSON *url_item = cJSON_GetObjectItemCaseSensitive(root, "url");
    if (!cJSON_IsString(url_item) || !url_item->valuestring) {
        ESP_LOGE(TAG, "OTA: Missing or invalid 'url' field.");
        cJSON_Delete(root);
        return ESP_ERR_INVALID_ARG;
    }

    const char *firmware_url = url_item->valuestring;
    ESP_LOGI(TAG, "OTA: Initiating download from: %s", firmware_url);

    // ── Safety check: Wi-Fi signal strength ───────────────────────────────────
    wifi_ap_record_t ap;
    if (esp_wifi_sta_get_ap_info(&ap) == ESP_OK) {
        if (ap.rssi < OTA_MIN_SIGNAL_DBMS) {
            ESP_LOGE(TAG, "OTA aborted: Signal too weak (%d dBm, min %d dBm)",
                     ap.rssi, OTA_MIN_SIGNAL_DBMS);
            cJSON_Delete(root);
            return ESP_ERR_INVALID_STATE;
        }
        ESP_LOGI(TAG, "OTA: Signal OK (%d dBm)", ap.rssi);
    }

    // ── Chunked HTTPS OTA with live progress reporting ────────────────────────
    esp_http_client_config_t http_config = {
        .url             = firmware_url,
        .timeout_ms      = OTA_TIMEOUT_MS,
        .keep_alive_enable = true,
        // .cert_pem     = server_cert_pem_start, // Pin S3/CDN cert for production
    };

    esp_https_ota_config_t ota_config = {
        .http_config = &http_config,
    };

    esp_https_ota_handle_t ota_handle = NULL;
    esp_err_t err = esp_https_ota_begin(&ota_config, &ota_handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "OTA: esp_https_ota_begin failed: %s", esp_err_to_name(err));
        cJSON_Delete(root);
        return err;
    }

    int last_reported_pct = -1;

    // Download firmware in chunks; publish progress after each 5% increment.
    while ((err = esp_https_ota_perform(ota_handle)) == ESP_ERR_HTTPS_OTA_IN_PROGRESS) {
        int bytes_read  = esp_https_ota_get_image_len_read(ota_handle);
        int total_bytes = esp_https_ota_get_image_size(ota_handle);

        if (total_bytes > 0) {
            int pct = (bytes_read * 100) / total_bytes;
            if (pct >= last_reported_pct + 5) {
                last_reported_pct = pct;
                char progress_json[64];
                snprintf(progress_json, sizeof(progress_json),
                         "{\"ota_progress\":%d}", pct);
                DSGV_mqtt_publish_telemetry(progress_json);
                ESP_LOGI(TAG, "OTA: %d%% (%d / %d bytes)", pct, bytes_read, total_bytes);
            }
        }
    }

    if (!esp_https_ota_is_complete_data_received(ota_handle)) {
        ESP_LOGE(TAG, "OTA: Incomplete data received.");
        esp_https_ota_abort(ota_handle);
        cJSON_Delete(root);
        return ESP_FAIL;
    }

    err = esp_https_ota_finish(ota_handle);
    cJSON_Delete(root);

    if (err == ESP_OK) {
        // Publish 100% before rebooting so the app shows completion.
        DSGV_mqtt_publish_telemetry("{\"ota_progress\":100}");
        ESP_LOGI(TAG, "OTA: Success! Rebooting to new firmware...");
        // Small delay so the telemetry publish drains before reboot.
        vTaskDelay(pdMS_TO_TICKS(500));
        esp_restart();
    } else {
        ESP_LOGE(TAG, "OTA: Finish failed: %s", esp_err_to_name(err));
        DSGV_mqtt_publish_telemetry("{\"ota_progress\":-1}");
    }

    return err;
}
