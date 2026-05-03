#include "nexus_config.h"
#include "driver/gpio.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "nexus_gpio";
static bool s_relay_state = false;

/**
 * Initialize all GPIO pins:
 * - Relay output pin
 * - Status LED
 * - Factory reset button (with interrupt)
 */
void nexus_gpio_init(void) {
    // ── Relay / Output pin ────────────────────────────────────────────────
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

    ESP_LOGI(TAG, "GPIO initialized. Relay on pin %d", GPIO_RELAY_PIN);
}

/**
 * Toggle the relay and mirror state to the status LED.
 * Publishes updated telemetry after state change.
 */
void nexus_gpio_relay_set(bool on) {
    s_relay_state = on;
    gpio_set_level(GPIO_RELAY_PIN, on ? 1 : 0);
    gpio_set_level(GPIO_STATUS_LED_PIN, on ? 1 : 0);
    ESP_LOGI(TAG, "Relay → %s", on ? "ON" : "OFF");

    // Publish updated telemetry back to the app
    // nexus_mqtt_publish_telemetry("{\"power\": true}");
}

bool nexus_gpio_relay_get(void) {
    return s_relay_state;
}
