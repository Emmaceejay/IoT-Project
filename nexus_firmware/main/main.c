/**
 * main.c — Nexus Hub ESP32 Firmware Entry Point
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
 *   5. Start local HTTP server (Nexus REST + Tasmota compat)
 *   6. Start MQTT client (cloud → local fallback)
 *   7. Start Matter endpoint (device discoverable regardless of MQTT state)
 */

#include "nvs_flash.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "nexus_config.h"
#include "nexus_device_state.h"
#include "wifi_manager.h"
#include "nexus_http_server.h"

// Forward declarations for modules not yet fully integrated via headers
esp_err_t nexus_mqtt_start(void);
void      nexus_gpio_init(void);
// esp_err_t matter_endpoint_start(void);  // Uncomment when esp-matter SDK linked

static const char *TAG = "nexus_main";

void app_main(void) {
    ESP_LOGI(TAG, "=== Nexus Hub Firmware %s Booting ===",
             NEXUS_FIRMWARE_VERSION);

    // ── Step 1: NVS ──────────────────────────────────────────────────────────
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    // ── Step 2: TCP/IP stack + Event Loop ────────────────────────────────────
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    // ── Step 3: GPIO ─────────────────────────────────────────────────────────
    nexus_gpio_init();

    // ── Step 4: Wi-Fi ────────────────────────────────────────────────────────
    esp_err_t wifi_err = wifi_manager_connect();

    if (wifi_err == ESP_ERR_NOT_FOUND) {
        ESP_LOGW(TAG, "No Wi-Fi credentials. Waiting for Matter commissioning...");
        // Device sits in Matter discoverable mode (BLE) until App pairs it.
        // matter_endpoint_start();
        return;
    }

    // Wait for DHCP address (Wi-Fi needs a moment to associate + get IP)
    vTaskDelay(pdMS_TO_TICKS(3000));

    if (!wifi_manager_is_connected()) {
        ESP_LOGE(TAG, "Wi-Fi failed to connect within 3 s. Halting.");
        return;
    }

    ESP_LOGI(TAG, "Wi-Fi connected.");

    // ── Step 5: Local HTTP server (Tasmota-compatible REST API) ──────────────
    // This lets the Nexus Hub App control the device directly when both are
    // on the same Wi-Fi — no broker or internet required.
    ESP_ERROR_CHECK(nexus_http_server_start());

    // ── Step 6: MQTT client (cloud → local broker fallback) ──────────────────
    ESP_ERROR_CHECK(nexus_mqtt_start());

    // ── Step 7: Matter endpoint ───────────────────────────────────────────────
    // Registers the device as a standard Matter On/Off Light cluster.
    // Uncomment once the esp-matter SDK component is linked.
    // ESP_ERROR_CHECK(matter_endpoint_start());
    ESP_LOGI(TAG, "Matter endpoint: uncomment matter_endpoint_start() when "
                  "esp-matter SDK is linked.");

    ESP_LOGI(TAG, "=== Nexus Hub Firmware fully initialized ===");
    ESP_LOGI(TAG, "HTTP server : port %d", HTTP_SERVER_PORT);
    ESP_LOGI(TAG, "MQTT broker : %s:%d (TLS) → %s:%d (fallback)",
             MQTT_CLOUD_HOST, MQTT_CLOUD_PORT,
             MQTT_LOCAL_HOST, MQTT_LOCAL_PORT);
}
