#include "dsgv_config.h"
#include "esp_https_ota.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "esp_wifi.h"
#include "esp_crt_bundle.h"
#include "cJSON.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <stdio.h>
#include <string.h>

static const char *TAG = "DSGV_ota";

// Declared in dsgv_mqtt.c — publish progress telemetry during OTA.
extern void DSGV_mqtt_publish_telemetry(const char *json_payload);

// Verifies the just-written OTA partition's SHA-256 against the hex digest
// the app supplied. Uses esp_partition_get_sha256() (esp_partition.h) rather
// than hand-rolling mbedtls calls: it's image-aware (hashes the actual app
// image content, not the whole partition's flash capacity — matters since a
// partition is bigger than any real image) and validates the image structure
// as a side effect, returning ESP_ERR_IMAGE_INVALID for a malformed image.
// Runs AFTER esp_https_ota_is_complete_data_received() but BEFORE
// esp_https_ota_finish() — finish() is what marks a partition bootable, so a
// mismatch here must route to esp_https_ota_abort() instead, never finish(),
// or a bad image could still end up active on reboot.
static bool image_sha256_matches(const esp_partition_t *partition,
                                  const char *expected_hex) {
    if (!partition || strlen(expected_hex) != 64) {
        return false;
    }

    uint8_t digest[32];
    esp_err_t err = esp_partition_get_sha256(partition, digest);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "OTA: esp_partition_get_sha256 failed: %s", esp_err_to_name(err));
        return false;
    }

    char digest_hex[65];
    for (int i = 0; i < 32; i++) {
        snprintf(digest_hex + i * 2, 3, "%02x", digest[i]);
    }

    // Case-insensitive compare — app may send either case.
    char expected_lower[65];
    for (int i = 0; i < 64; i++) {
        char c = expected_hex[i];
        expected_lower[i] = (char)((c >= 'A' && c <= 'F') ? c + 32 : c);
    }
    expected_lower[64] = '\0';

    return memcmp(digest_hex, expected_lower, 64) == 0;
}

/**
 * Triggered by receiving a payload on the OTA topic (dsgv_mqtt.c's handle_ota(),
 * which verifies auth_token before ever calling this — this function trusts
 * that check has already happened and does not re-verify it).
 *
 * Payload format expected from DSGV Hub App:
 * {"auth_token": "<32hex>",
 *  "url": "https://your-bucket.s3.amazonaws.com/firmware/v1.2.0.bin",
 *  "hash": "sha256-of-binary"}
 *
 * Safety checks:
 * 1. Wi-Fi signal must be stronger than OTA_MIN_SIGNAL_DBMS
 * 2. Uses chunked download API so the app receives live ota_progress (0-100)
 * 3. Uses dual-bank partition: if new firmware crashes, auto-rolls back
 * 4. "hash" is REQUIRED and verified against the downloaded image's actual
 *    SHA-256 before the image is ever marked bootable — a mismatch aborts
 *    the OTA and the current firmware stays active.
 * 5. Download TLS is verified against ESP-IDF's public CA bundle
 *    (esp_crt_bundle_attach — same pattern dsgv_gateway.c uses for its own
 *    HTTPS calls); this is not pinning to one specific certificate, but it is
 *    real server authentication, which this code previously had none of.
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

    cJSON *hash_item = cJSON_GetObjectItemCaseSensitive(root, "hash");
    if (!cJSON_IsString(hash_item) || !hash_item->valuestring ||
        strlen(hash_item->valuestring) != 64) {
        ESP_LOGE(TAG, "OTA: Missing or invalid 'hash' field (must be 64-char SHA-256 hex).");
        cJSON_Delete(root);
        return ESP_ERR_INVALID_ARG;
    }
    char expected_hash[65];
    strlcpy(expected_hash, hash_item->valuestring, sizeof(expected_hash));

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
        .url               = firmware_url,
        .timeout_ms        = OTA_TIMEOUT_MS,
        .keep_alive_enable = true,
        .crt_bundle_attach = esp_crt_bundle_attach,
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

    // ── Verify SHA-256 BEFORE finish() can mark this image bootable ──────────
    const esp_partition_t *update_partition = esp_ota_get_next_update_partition(NULL);
    if (!image_sha256_matches(update_partition, expected_hash)) {
        ESP_LOGE(TAG, "OTA: SHA-256 mismatch — rejecting image, current firmware stays active.");
        esp_https_ota_abort(ota_handle);
        DSGV_mqtt_publish_telemetry("{\"ota_progress\":-1}");
        cJSON_Delete(root);
        return ESP_ERR_INVALID_CRC;
    }
    ESP_LOGI(TAG, "OTA: SHA-256 verified OK.");

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
