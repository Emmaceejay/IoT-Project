/**
 * main.c — DSGV Hub ESP32 Firmware Entry Point
 *
 * Dual-Stack Architecture:
 *   Matter (CHIP) : native HomeKit / Google Home / Alexa via local fabric
 *   MQTT Client   : cloud broker (TLS) → local Mosquitto fallback
 *   HTTP Server   : Tasmota-compatible REST API for same-LAN direct control
 *
 * Startup Sequence:
 *   1. Init NVS (Non-Volatile Storage)
 *   2. Init TCP/IP + Event Loop
 *   3. Init GPIO (relay, LED)
 *   4. Connect Wi-Fi (credentials from NVS / Matter commissioning)
 *   5. Start local HTTP server (DSGV REST + Tasmota compat)
 *   6. Start MQTT client (cloud → local fallback)
 *   7. Start Matter endpoint (device discoverable regardless of MQTT state)
 */

#include "nvs_flash.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "dsgv_config.h"
#include "dsgv_device_state.h"
#include "dsgv_device_config.h"
#include "wifi_manager.h"
#include "dsgv_http_server.h"
#include "dsgv_provisioning.h"

// Forward declarations for modules not yet fully integrated via headers
esp_err_t DSGV_mqtt_start(void);
void      DSGV_gpio_init(void);
// esp_err_t matter_endpoint_start(void);  // Uncomment when esp-matter SDK linked

static const char *TAG = "DSGV_main";

void app_main(void) {
    ESP_LOGI(TAG, "=== DSGV Hub Firmware %s Booting ===",
             dsgv_firmware_VERSION);

    // ── Step 1: NVS ──────────────────────────────────────────────────────────
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    // Load per-SKU device config from NVS (falls back to DSGV_config.h defaults)
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
        // Start NimBLE GATT server so the DSGV Hub App can push Wi-Fi
        // credentials via Bluetooth. The device reboots automatically once
        // credentials are received and saved to NVS.
        ESP_ERROR_CHECK(DSGV_provisioning_start());
        // Provisioning runs in a background FreeRTOS task.
        // Suspend this task — there is nothing else to do until reboot.
        vTaskSuspend(NULL);
        return; // unreachable, keeps compiler happy
    }

    // Wait for DHCP address (Wi-Fi needs a moment to associate + get IP)
    vTaskDelay(pdMS_TO_TICKS(3000));

    if (!wifi_manager_is_connected()) {
        ESP_LOGE(TAG, "Wi-Fi failed to connect within 3 s. Halting.");
        return;
    }

    ESP_LOGI(TAG, "Wi-Fi connected.");

    // ── Step 5: Local HTTP server (Tasmota-compatible REST API) ──────────────
    // This lets the DSGV Hub App control the device directly when both are
    // on the same Wi-Fi — no broker or internet required.
    ESP_ERROR_CHECK(DSGV_http_server_start());

    // ── Step 6: MQTT client (cloud → local broker fallback) ──────────────────
    ESP_ERROR_CHECK(DSGV_mqtt_start());

    // ── Step 7: Matter endpoint ───────────────────────────────────────────────
    // Registers the device as a standard Matter On/Off Light cluster.
    // Uncomment once the esp-matter SDK component is linked.
    // ESP_ERROR_CHECK(matter_endpoint_start());
    ESP_LOGI(TAG, "Matter endpoint: uncomment matter_endpoint_start() when "
                  "esp-matter SDK is linked.");

    ESP_LOGI(TAG, "=== DSGV Hub Firmware fully initialized ===");
    ESP_LOGI(TAG, "HTTP server : port %d", HTTP_SERVER_PORT);
    ESP_LOGI(TAG, "MQTT broker : %s:%d (TLS) → %s:%d (fallback)",
             MQTT_CLOUD_HOST, MQTT_CLOUD_PORT,
             MQTT_LOCAL_HOST, MQTT_LOCAL_PORT);
}
