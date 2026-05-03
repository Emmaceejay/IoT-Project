/**
 * main.c — Nexus Hub ESP32 Firmware Entry Point
 *
 * Dual-Stack Architecture:
 * - Matter (CHIP): handles Apple HomeKit / Google Home / Alexa natively via local fabric
 * - MQTT Client:   connects to Nexus Hub App via EMQX Cloud or Local Mosquitto fallback
 *
 * Startup Sequence:
 * 1. Init NVS (Non-Volatile Storage)
 * 2. Init GPIO (relay, LED, button)
 * 3. Connect Wi-Fi (stored credentials from previous Matter commissioning)
 * 4. If Wi-Fi credentials exist → Start MQTT client
 * 5. Start Matter endpoint (device is discoverable regardless of MQTT state)
 */

#include "nvs_flash.h"
#include "esp_event.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

// Nexus modules
#include "nexus_config.h"
#include "wifi_manager.h"
// #include "nexus_mqtt.h"    // Uncomment when mqtt module is linked
// #include "nexus_gpio.h"    // Uncomment when gpio module is linked
// #include "matter_endpoint.h" // Uncomment when esp-matter SDK is integrated

static const char *TAG = "nexus_main";

void app_main(void) {
    ESP_LOGI(TAG, "=== Nexus Hub Firmware %s Booting ===", NEXUS_FIRMWARE_VERSION);

    // ── Step 1: Initialize NVS ────────────────────────────────────────────
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    // ── Step 2: Initialize Event Loop ─────────────────────────────────────
    ESP_ERROR_CHECK(esp_event_loop_create_default());

    // ── Step 3: Initialize GPIO ───────────────────────────────────────────
    // nexus_gpio_init();
    ESP_LOGI(TAG, "GPIO ready. (Uncomment nexus_gpio_init when module linked)");

    // ── Step 4: Connect Wi-Fi ─────────────────────────────────────────────
    esp_err_t wifi_err = wifi_manager_connect();

    if (wifi_err == ESP_ERR_NOT_FOUND) {
        ESP_LOGW(TAG, "No Wi-Fi credentials. Waiting for Matter commissioning...");
        // Device sits in discoverable Matter mode via BLE until app pairs it
    } else {
        ESP_LOGI(TAG, "Wi-Fi connecting...");

        // ── Step 5: Start MQTT (after short delay for Wi-Fi connection) ───
        vTaskDelay(pdMS_TO_TICKS(3000));
        // nexus_mqtt_start();
        ESP_LOGI(TAG, "MQTT ready. (Uncomment nexus_mqtt_start when module linked)");
    }

    // ── Step 6: Start Matter Endpoint ─────────────────────────────────────
    // matter_endpoint_start(); // Registers relay as Matter On/Off cluster
    ESP_LOGI(TAG, "Matter endpoint ready. (Uncomment when esp-matter SDK linked)");

    ESP_LOGI(TAG, "=== Nexus Hub Firmware fully initialized ===");
}
