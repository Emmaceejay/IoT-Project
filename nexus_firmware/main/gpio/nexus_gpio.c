/**
 * nexus_gpio.c — GPIO and physical hardware layer
 *
 * Drives the relay, status LED, and reads the factory-reset button.
 * All state writes go through g_device_state so MQTT and HTTP layers
 * always have an accurate view of actual hardware state.
 */

#include "nexus_config.h"
#include "nexus_device_state.h"
#include "driver/gpio.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <stdio.h>

static const char *TAG = "nexus_gpio";

// Declared in nexus_mqtt.c
extern void nexus_mqtt_publish_telemetry(const char *json_payload);

/**
 * Initialize all GPIO pins:
 *   - Relay output
 *   - Status LED (mirrors relay state)
 *   - Factory-reset button (with interrupt)
 */
void nexus_gpio_init(void) {
    // ── Relay ─────────────────────────────────────────────────────────────
    gpio_config_t relay_conf = {
        .pin_bit_mask = (1ULL << GPIO_RELAY_PIN),
        .mode         = GPIO_MODE_OUTPUT,
        .pull_up_en   = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    gpio_config(&relay_conf);
    gpio_set_level(GPIO_RELAY_PIN, 0); // Start OFF

    // ── Status LED ────────────────────────────────────────────────────────
    gpio_config_t led_conf = {
        .pin_bit_mask = (1ULL << GPIO_STATUS_LED_PIN),
        .mode         = GPIO_MODE_OUTPUT,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    gpio_config(&led_conf);

    ESP_LOGI(TAG, "GPIO initialized. Relay→pin%d, LED→pin%d",
             GPIO_RELAY_PIN, GPIO_STATUS_LED_PIN);
}

/**
 * Drive the relay and mirror state to the LED.
 * Updates g_device_state and publishes telemetry so both MQTT and HTTP
 * layers reflect the actual hardware state.
 */
void nexus_gpio_relay_set(bool on) {
    gpio_set_level(GPIO_RELAY_PIN, on ? 1 : 0);
    gpio_set_level(GPIO_STATUS_LED_PIN, on ? 1 : 0);

    STATE_LOCK();
    g_device_state.power = on;
    nexus_device_state_t snap = g_device_state;
    STATE_UNLOCK();

    ESP_LOGI(TAG, "Relay → %s", on ? "ON" : "OFF");

    // Publish updated telemetry so the Nexus Hub App stays in sync
    char telemetry[256];
    snprintf(telemetry, sizeof(telemetry),
        "{\"power\":%s,\"brightness\":%d,\"color_temp\":%d,"
        "\"current_temp\":%.1f,\"target_temp\":%.1f,\"mode\":\"%s\"}",
        snap.power ? "true" : "false",
        snap.brightness,
        snap.color_temp_k,
        snap.current_temp,
        snap.target_temp,
        snap.hvac_mode
    );
    nexus_mqtt_publish_telemetry(telemetry);
}

bool nexus_gpio_relay_get(void) {
    STATE_LOCK();
    bool state = g_device_state.power;
    STATE_UNLOCK();
    return state;
}

/**
 * Apply the full current g_device_state to hardware outputs.
 * Called after any MQTT or HTTP command to sync hardware to new state.
 */
void nexus_gpio_apply_state(void) {
    STATE_LOCK();
    bool power = g_device_state.power;
    STATE_UNLOCK();

    gpio_set_level(GPIO_RELAY_PIN, power ? 1 : 0);
    gpio_set_level(GPIO_STATUS_LED_PIN, power ? 1 : 0);
}
