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
 *   4. Event bus (dsgv_events — GPIO-to-MQTT telemetry bridge)
 *   5. GPIO init (relays, LEDC PWM, ADC, sensors)
 *   6. Wi-Fi connect — enters BLE provisioning mode if no credentials found
 *   7. HTTP server (Tasmota-compatible REST API, port 80) — local control is
 *      live from this point on, independent of everything below
 *   8. Gateway config fetch (best-effort, up to GATEWAY_TIMEOUT_MS) — pulls
 *      the broker host/port/tls/credentials for this device into NVS. Runs
 *      after the HTTP server so a slow/absent internet connection never
 *      delays local control. Failure just means MQTT uses whatever's cached.
 *   9. MQTT client (cloud TLS → local Mosquitto fallback)
 */

#include "nvs_flash.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "esp_app_desc.h"
#include "esp_mac.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "dsgv_config.h"
#include "dsgv_device_state.h"
#include "dsgv_device_config.h"
#include "wifi_manager.h"
#include "dsgv_http_server.h"
#include "dsgv_provisioning.h"
#include "dsgv_captive_portal.h"
#include "dsgv_gateway.h"

esp_err_t DSGV_mqtt_start(void);
void      DSGV_gpio_init(void);
void      dsgv_events_init(void);

static const char *TAG = "DSGV_main";

// Prints device identity to serial once NVS config is loaded.
// Copy the Pair Code and Auth Token from here when building each device.
static void print_device_identity(void) {
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_BT);
    ESP_LOGI(TAG, "");
    ESP_LOGI(TAG, "================================================");
    ESP_LOGI(TAG, "  BLE Name  : %s%02X%02X%02X",
             DSGV_PROV_DEVICE_NAME_PREFIX, mac[3], mac[4], mac[5]);
    ESP_LOGI(TAG, "  Pair Code : %02X%02X%02X", mac[3], mac[4], mac[5]);
    ESP_LOGI(TAG, "  Auth Token: %.16s", g_device_config.auth_token);
    ESP_LOGI(TAG, "             %.16s", g_device_config.auth_token + 16);
    ESP_LOGI(TAG, "================================================");
    ESP_LOGI(TAG, "");
}

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
    print_device_identity();

    // ── Step 3: TCP/IP stack + Event Loop ────────────────────────────────────
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    // ── Step 3: Event bus ────────────────────────────────────────────────────
    // Must be initialised before GPIO so the sensor/wall-switch tasks can post
    // telemetry events immediately on their first wakeup.
    dsgv_events_init();

    // ── Step 4: GPIO ─────────────────────────────────────────────────────────
    // sensor_task calls STATE_LOCK() as soon as it's created inside DSGV_gpio_init(),
    // which is before DSGV_mqtt_start() would normally create the mutex — so create
    // it here first.
    if (g_state_mutex == NULL) {
        g_state_mutex = xSemaphoreCreateMutex();
        configASSERT(g_state_mutex != NULL);
    }
    DSGV_gpio_init();

    // ── Step 4: Wi-Fi ────────────────────────────────────────────────────────
    esp_err_t wifi_err = wifi_manager_connect();

    if (wifi_err == ESP_ERR_NOT_FOUND) {
        ESP_LOGW(TAG, "No Wi-Fi credentials — starting BLE advertising now.");
        ESP_LOGW(TAG, "Open your app and connect to: %s<Pair Code from above>",
                 DSGV_PROV_DEVICE_NAME_PREFIX);
        ESP_ERROR_CHECK(DSGV_provisioning_start());
        vTaskSuspend(NULL);
        return;
    }

    // Poll up to 15 s — WPA3-SAE (Dragonfly handshake) takes 4-5 s, well over
    // the 3 s that WPA2 needs.
    for (int i = 0; i < 15 && !wifi_manager_is_connected(); i++) {
        vTaskDelay(pdMS_TO_TICKS(1000));
    }

    if (!wifi_manager_is_connected()) {
        // Credentials exist but the network is unreachable (wrong password,
        // router replaced, etc.).  Stop the reconnect loop so it does not
        // interfere with the AP radio, then start a setup Access Point and
        // serve the captive portal so the user can supply new credentials
        // from any phone browser — no factory reset, no app required.
        wifi_manager_stop_reconnect();
        ESP_LOGW(TAG, "Wi-Fi failed to connect within 15 s.");
        ESP_LOGW(TAG, "Starting setup AP + captive portal for credential recovery.");
        if (wifi_manager_start_ap()         == ESP_OK &&
            DSGV_captive_portal_start()     == ESP_OK) {
            ESP_LOGI(TAG, "Connect your phone to the 'DSGV_Setup_*' Wi-Fi network,");
            ESP_LOGI(TAG, "then open a browser — the setup page will appear automatically.");
        } else {
            ESP_LOGE(TAG, "Failed to start setup AP. Device cannot recover without reboot.");
        }
        vTaskSuspend(NULL);
        return;
    }

    ESP_LOGI(TAG, "Wi-Fi connected.");

    // ── Step 7: Local HTTP server ─────────────────────────────────────────────
    // Local control is live from here regardless of what happens below —
    // it authenticates with auth_token, never the MQTT broker credential.
    ESP_ERROR_CHECK(DSGV_http_server_start());

    // ── Step 8: Gateway config fetch ─────────────────────────────────────────
    // Best-effort. Populates mqtt_cfg NVS (host/port/tls/username/password)
    // for DSGV_mqtt_start() below. On failure (no internet, gateway down),
    // whatever's already cached in NVS from a previous successful fetch is
    // used unchanged — see dsgv_gateway.h. No compile-time broker credential
    // exists as a fallback by design: a device needs one successful
    // internet-connected boot before cloud MQTT works, same requirement
    // BLE provisioning already has via registerDevice.
    esp_err_t gw_err = dsgv_gateway_fetch_config();
    if (gw_err != ESP_OK) {
        ESP_LOGW(TAG, "Gateway config fetch failed (%s) — MQTT will use cached NVS "
                 "credentials, or stay disconnected if none have ever been fetched",
                 esp_err_to_name(gw_err));
    }

    // ── Step 9: MQTT client ───────────────────────────────────────────────────
    // Best-effort — a failed MQTT init must NOT abort the device.
    // HTTP server and physical button control remain fully functional without cloud.
    esp_err_t mqtt_err = DSGV_mqtt_start();
    if (mqtt_err != ESP_OK) {
        ESP_LOGW(TAG, "MQTT start failed (%s) — device operable via HTTP and local control",
                 esp_err_to_name(mqtt_err));
    }

    ESP_LOGI(TAG, "=== DSGV Hub Firmware fully initialized ===");
    ESP_LOGI(TAG, "Device     : %s  caps=%s  relays=%u",
             g_device_config.device_type,
             g_device_config.capabilities,
             g_device_config.relay_count);
    ESP_LOGI(TAG, "HTTP server: port %d", HTTP_SERVER_PORT);
    ESP_LOGI(TAG, "MQTT broker: %s:%d", MQTT_CLOUD_HOST, MQTT_CLOUD_PORT);
}
