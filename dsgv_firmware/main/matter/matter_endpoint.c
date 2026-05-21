/**
 * matter_endpoint.c — DSGV Hub Matter Cluster Endpoint
 *
 * Registers the device as a standard Matter "On/Off Light" node.
 * This makes the device discoverable and controllable by:
 *   - Apple HomeKit
 *   - Google Home
 *   - Amazon Alexa
 *   - Samsung SmartThings
 *   - Home Assistant
 *
 * When Matter ecosystem sends an "On" command, we forward it to
 * the GPIO relay AND publish updated telemetry to our MQTT broker
 * so the DSGV Hub App stays in sync.
 *
 * Required: esp-matter SDK (https://github.com/espressif/esp-matter)
 * Setup:    Follow esp-matter README to set IDF_COMPONENT_MANAGER=1
 */

// #include <esp_matter.h>
// #include <esp_matter_cluster.h>
// #include <esp_matter_endpoint.h>
// #include "dsgv_gpio.h"
// #include "dsgv_mqtt.h"
// #include "esp_log.h"

// static const char *TAG = "matter_endpoint";
// static uint16_t s_endpoint_id = 0;

/**
 * Callback triggered when Matter ecosystem sends an On/Off command.
 * Syncs state to GPIO relay and re-publishes telemetry via MQTT.
 */
// static esp_err_t app_attribute_update_cb(
//     esp_matter::callback::type_t type,
//     uint16_t endpoint_id,
//     uint32_t cluster_id,
//     uint32_t attribute_id,
//     esp_matter_attr_val_t *val,
//     void *priv_data)
// {
//     if (cluster_id == chip::app::Clusters::OnOff::Id &&
//         attribute_id == chip::app::Clusters::OnOff::Attributes::OnOff::Id) {
//         bool on = val->val.b;
//         DSGV_gpio_relay_set(on);
//         char telemetry[64];
//         snprintf(telemetry, sizeof(telemetry), "{\"power\":%s}", on ? "true" : "false");
//         DSGV_mqtt_publish_telemetry(telemetry);
//         ESP_LOGI(TAG, "Matter OnOff → %s", on ? "ON" : "OFF");
//     }
//     return ESP_OK;
// }

/**
 * Initializes Matter node and registers On/Off Light endpoint.
 * Call from app_main() after Wi-Fi is ready.
 */
// esp_err_t matter_endpoint_start(void) {
//     esp_matter::node::config_t node_config;
//     esp_matter::node_t *node = esp_matter::node::create(&node_config,
//                                    app_attribute_update_cb, NULL);
//
//     esp_matter::endpoint::on_off_light::config_t light_config;
//     esp_matter::endpoint_t *endpoint =
//         esp_matter::endpoint::on_off_light::create(node, &light_config,
//                                                     ENDPOINT_FLAG_NONE, NULL);
//     s_endpoint_id = esp_matter::endpoint::get_id(endpoint);
//
//     esp_matter::start(NULL);
//     ESP_LOGI(TAG, "Matter ON/OFF endpoint started. ID: %d", s_endpoint_id);
//     return ESP_OK;
// }
