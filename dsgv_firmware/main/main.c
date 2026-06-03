/**
 * main.c — DSGV Hub ESP32 Firmware Entry Point
 *
 * Transport Architecture:
 *   C2C (Cloud-to-Cloud) : Google Home / Alexa / SmartThings via the cloud
 *                          bridge — no hardware certification needed.
 *   MQTT Client          : cloud broker (TLS) for remote control and telemetry.
 *   HTTP Server          : Tasmota-compatible REST API for same-LAN direct
 *                          control without touching the internet.
 *   mDNS                 : advertises this device on the local network so the
 *                          DSGV Hub App can discover it without the device
 *                          publishing its IP over MQTT first.
 *
 * Startup Sequence:
 *   1. Init NVS (Non-Volatile Storage) — loads Wi-Fi creds, auth token, etc.
 *   2. Init TCP/IP stack + Event Loop  — required before any network calls.
 *   3. Init GPIO (relay, LED, sensors) — hardware must be configured early.
 *   4. Connect Wi-Fi                   — credentials come from NVS.
 *      └─ If no credentials found → enter BLE provisioning mode and wait.
 *   5. Start local HTTP server         — available even without MQTT broker.
 *   6. Start mDNS service              — device discoverable on LAN immediately.
 *   7. Start MQTT client               — remote control + telemetry + C2C bridge.
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
#include "dsgv_mdns.h"   // mDNS service — announces device on local network

// Forward declarations for modules that expose a C init function
// but whose headers are internal to the component.
esp_err_t DSGV_mqtt_start(void);
void      DSGV_gpio_init(void);

static const char *TAG = "DSGV_main";

void app_main(void) {
    ESP_LOGI(TAG, "=== DSGV Hub Firmware %s Booting ===",
             dsgv_firmware_VERSION);

    // ── Step 1: NVS (Non-Volatile Storage) ───────────────────────────────────
    // NVS stores Wi-Fi credentials, the device auth token, and MQTT broker
    // settings across reboots. It must be initialised before anything else
    // tries to read from it (device config, Wi-Fi driver, etc.).
    //
    // The two error cases below happen when a new firmware version changes the
    // NVS data layout. Erasing and re-initialising is safe here because:
    //   - ESP_ERR_NVS_NO_FREE_PAGES: the NVS area is full / corrupted.
    //   - ESP_ERR_NVS_NEW_VERSION_FOUND: the flash was written by a different
    //     firmware version whose NVS format is incompatible.
    // After an erase the device will enter BLE provisioning mode on next boot
    // to collect fresh credentials from the DSGV Hub App.
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_LOGW(TAG, "NVS layout mismatch — erasing and re-initialising.");
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    // Load per-SKU device identity from NVS (falls back to sdkconfig.defaults
    // compile-time values if the NVS key is absent — first boot behaviour).
    ESP_ERROR_CHECK(DSGV_device_config_load());

    // ── Step 2: TCP/IP Stack + Event Loop ────────────────────────────────────
    // esp_netif_init() sets up the LwIP TCP/IP stack.
    // esp_event_loop_create_default() creates the shared event bus that
    // Wi-Fi, MQTT, HTTP, and mDNS all post events on.
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());

    // Create the default "station" (STA) network interface — the one that
    // connects to a home Wi-Fi router.
    esp_netif_create_default_wifi_sta();

    // ── Step 3: GPIO ──────────────────────────────────────────────────────────
    // Configures relay outputs, LEDC PWM channels (dimmer / RGB / CCT),
    // sensor inputs (PIR, reed switch), status LED, and the factory-reset button.
    // Must run before Wi-Fi so relay state is defined before the device is
    // controllable.
    DSGV_gpio_init();

    // ── Step 4: Wi-Fi ─────────────────────────────────────────────────────────
    esp_err_t wifi_err = wifi_manager_connect();

    if (wifi_err == ESP_ERR_NOT_FOUND) {
        // No Wi-Fi credentials stored in NVS — this is a freshly flashed device.
        // Start the NimBLE GATT provisioning server so the DSGV Hub App can
        // push the Wi-Fi SSID/password and device identity over Bluetooth.
        // The firmware saves the credentials to NVS and reboots automatically.
        ESP_LOGW(TAG, "No Wi-Fi credentials — entering BLE provisioning mode.");
        ESP_ERROR_CHECK(DSGV_provisioning_start());

        // BLE provisioning runs in its own FreeRTOS task.
        // Suspend this task — there is nothing more to do until the device
        // reboots after receiving credentials.
        vTaskSuspend(NULL);
        return; // unreachable; keeps the compiler warning-free
    }

    // Give the Wi-Fi driver time to associate with the AP and get a DHCP lease.
    // 3 s is conservative — most APs respond within 1 s.
    vTaskDelay(pdMS_TO_TICKS(3000));

    if (!wifi_manager_is_connected()) {
        ESP_LOGE(TAG, "Wi-Fi failed to connect within 3 s. Halting.");
        return;
    }

    ESP_LOGI(TAG, "Wi-Fi connected — LAN IP assigned.");

    // ── Step 5: Local HTTP Server (Tasmota-compatible REST API) ──────────────
    // Starts a lightweight HTTP server on port 80 (HTTP_SERVER_PORT).
    // This lets the DSGV Hub App — and any Tasmota-aware tool — control the
    // device directly on the same LAN without going through a cloud broker.
    //
    // Key endpoints:
    //   GET  /api/status         → returns current device state as JSON
    //   POST /api/cmd            → executes a capability command immediately
    //   GET  /cm?cmnd=<cmd>      → Tasmota-compatible command interface
    //
    // The HTTP server remains available even when MQTT is down.
    ESP_ERROR_CHECK(DSGV_http_server_start());

    // ── Step 6: mDNS (Local Network Discovery) ────────────────────────────────
    // Advertises this device on the local network using multicast DNS so the
    // DSGV Hub App can discover it by name instead of needing its IP address.
    //
    // Advertised services:
    //   _dsgv._tcp.local   — primary DSGV service, port 80
    //   _http._tcp.local   — HTTP endpoint (Tasmota-tool compatibility)
    //
    // TXT records carried in the advertisement:
    //   id=<MAC>           — uniqueDeviceId the app uses to correlate with MQTT
    //   caps=<json_array>  — capabilities (e.g. ["relay","brightness"])
    //   type=<deviceType>  — human-readable (e.g. "Switch", "Dimmer")
    //   fw=<version>       — firmware version string
    //
    // The app queries _dsgv._tcp.local on startup and fills in localIp for
    // each discovered device — enabling direct HTTP commands with <10 ms latency.
    ESP_ERROR_CHECK(DSGV_mdns_start());

    // ── Step 7: MQTT Client (Remote Control + C2C Bridge) ─────────────────────
    // Connects to the cloud MQTT broker (TLS, port 8883) and:
    //   • Publishes an "announce" message so new devices are auto-detected.
    //   • Publishes telemetry every DSGV_TELEMETRY_INTERVAL_MS (30 s).
    //   • Subscribes to the "command" topic to receive control messages.
    //   • Uses a Last Will and Testament (LWT) so the broker marks the device
    //     offline automatically if the connection drops without a clean close.
    //
    // The C2C cloud bridge (Google Home / Alexa / SmartThings) publishes
    // commands to this same MQTT topic when a voice command arrives, so the
    // device has no direct dependency on any voice platform SDK.
    ESP_ERROR_CHECK(DSGV_mqtt_start());

    ESP_LOGI(TAG, "=== DSGV Hub Firmware fully initialised ===");
    ESP_LOGI(TAG, "HTTP server : port %d", HTTP_SERVER_PORT);
    ESP_LOGI(TAG, "MQTT broker : %s:%d (TLS)",
             MQTT_CLOUD_HOST, MQTT_CLOUD_PORT);
    ESP_LOGI(TAG, "mDNS        : dsgv-%s.local",
             DSGV_DEVICE_TYPE); // hostname set in DSGV_mdns_start()
}
