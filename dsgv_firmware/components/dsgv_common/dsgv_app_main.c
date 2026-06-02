/**
 * dsgv_app_main.c — DSGV Hub firmware initialization sequence.
 *
 * Called by the thin app_main() stub in each device project.
 * Device identity (type, capabilities, relay count) is set at build time
 * via CONFIG_DSGV_* Kconfig options in the device's sdkconfig.defaults,
 * and can be overridden at runtime via BLE provisioning + NVS.
 *
 * Startup sequence:
 *   1. NVS init
 *   2. Device config load (compile-time defaults → NVS overlay)
 *   3. TCP/IP stack + default event loop
 *   4. GPIO init (relays, LEDC PWM, ADC, sensors)
 *   5. Wi-Fi connect — enters BLE provisioning mode if no credentials found
 *   6. HTTP server (Tasmota-compatible REST API, port 80)
 *   7. MQTT client (cloud TLS → local Mosquitto fallback)
 */

#include "nvs_flash.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_app_desc.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "dsgv_config.h"
#include "dsgv_device_state.h"
#include "dsgv_device_config.h"
#include "wifi_manager.h"
#include "dsgv_http_server.h"
#include "dsgv_provisioning.h"

esp_err_t DSGV_mqtt_start(void);
void      DSGV_gpio_init(void);

static const char *TAG = "DSGV_main";

void dsgv_app_main(void)
{
    const esp_app_desc_t *app_desc = esp_app_get_description();
    ESP_LOGI(TAG, "=== DSGV Hub Firmware v%s Booting ===", app_desc->version);

    // ── Step 1: NVS ──────────────────────────────────────────────────────────
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    // Load per-SKU device config (NVS overlay on top of CONFIG_DSGV_* defaults)
    ESP_ERROR_CHECK(DSGV_device_config_load());

    // ── Step 2: TCP/IP stack + Event Loop ────────────────────────────────────
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    // ── Step 3: GPIO ─────────────────────────────────────────────────────────
    DSGV_gpio_init();

    // ── Step 4: Wi-Fi ────────────────────────────────────────────────────────
    esp_err_t wifi_err = wifi_manager_connect();

    if (wifi_err == ESP_ERR_NOT_FOUND) {
        ESP_LOGW(TAG, "No Wi-Fi credentials — entering BLE provisioning mode.");
        ESP_ERROR_CHECK(DSGV_provisioning_start());
        vTaskSuspend(NULL);
        return;
    }

    vTaskDelay(pdMS_TO_TICKS(3000));

    if (!wifi_manager_is_connected()) {
        ESP_LOGE(TAG, "Wi-Fi failed to connect within 3 s. Halting.");
        return;
    }

    ESP_LOGI(TAG, "Wi-Fi connected.");

    // ── Step 5: Local HTTP server ─────────────────────────────────────────────
    ESP_ERROR_CHECK(DSGV_http_server_start());

    // ── Step 6: MQTT client ───────────────────────────────────────────────────
    ESP_ERROR_CHECK(DSGV_mqtt_start());

    // ── Step 7: Matter endpoint (uncomment when esp-matter SDK is linked) ─────
    // ESP_ERROR_CHECK(matter_endpoint_start());
    ESP_LOGI(TAG, "Matter: uncomment matter_endpoint_start() when esp-matter SDK linked.");

    ESP_LOGI(TAG, "=== DSGV Hub Firmware fully initialized ===");
    ESP_LOGI(TAG, "Device     : %s  caps=%s  relays=%u",
             g_device_config.device_type,
             g_device_config.capabilities,
             g_device_config.relay_count);
    ESP_LOGI(TAG, "HTTP server: port %d", HTTP_SERVER_PORT);
    ESP_LOGI(TAG, "MQTT broker: %s:%d (TLS) → %s:%d (fallback)",
             MQTT_CLOUD_HOST, MQTT_CLOUD_PORT,
             MQTT_LOCAL_HOST, MQTT_LOCAL_PORT);
}
