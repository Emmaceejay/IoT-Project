#include "wifi_manager.h"
#include "dsgv_config.h"
#include "dsgv_mdns.h"   // DSGV_mdns_restart() — re-advertise on IP change
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "nvs.h"
#include <string.h>

static const char *TAG = "wifi_manager";

// Tracks whether the station interface currently has an IP address.
// Read by wifi_manager_is_connected() so other modules can gate on it.
static bool s_connected = false;

/**
 * Wi-Fi + IP event handler.
 *
 * ESP-IDF posts events on the default event loop whenever the Wi-Fi state
 * changes. We handle two events here:
 *
 *  WIFI_EVENT_STA_DISCONNECTED
 *    The association to the AP dropped (signal loss, AP restart, etc.).
 *    We mark ourselves as disconnected and call esp_wifi_connect() to
 *    trigger an immediate reconnect attempt. The Wi-Fi driver will keep
 *    retrying with exponential back-off until it succeeds.
 *
 *  IP_EVENT_STA_GOT_IP
 *    The DHCP client has assigned an IP address (either on initial connect
 *    or after a lease renewal). We:
 *      1. Log the new IP for debugging.
 *      2. Mark ourselves as connected.
 *      3. Restart the mDNS service so it advertises the new IP address.
 *         Without this, after a DHCP renewal the old stale IP would still
 *         be in the mDNS cache of nearby devices.
 */
static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                                int32_t event_id, void *event_data)
{
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        ESP_LOGW(TAG, "Wi-Fi disconnected. Retrying…");
        s_connected = false;
        esp_wifi_connect(); // trigger immediate reconnect attempt
    }
    else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
        ESP_LOGI(TAG, "Got IP: " IPSTR, IP2STR(&event->ip_info.ip));
        s_connected = true;

        // Re-advertise on mDNS with the new IP so the DSGV Hub App and any
        // other LAN tools always resolve to the correct address. This covers
        // both the first-boot case and DHCP lease renewals.
        // We only restart if mDNS is already running (i.e. past Step 6 in
        // main.c). On first boot this event fires before DSGV_mdns_start(),
        // so DSGV_mdns_restart() would fail gracefully since mdns_free() on
        // an uninitialised stack is a no-op in ESP-IDF.
        DSGV_mdns_restart();
    }
}

esp_err_t wifi_manager_connect(void)
{
    // Open the "wifi_creds" NVS namespace that was written by the BLE
    // provisioning service (dsgv_provisioning.c). If it doesn't exist the
    // device has never been provisioned — return NOT_FOUND so main.c can
    // enter provisioning mode.
    nvs_handle_t nvs;
    esp_err_t err = nvs_open("wifi_creds", NVS_READONLY, &nvs);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "No Wi-Fi credentials in NVS — entering provisioning mode.");
        return ESP_ERR_NOT_FOUND;
    }

    char ssid[64]      = {0};
    char password[128] = {0};
    size_t ssid_len = sizeof(ssid);
    size_t pass_len = sizeof(password);

    // nvs_get_str() copies the stored string into the buffer and writes the
    // actual length (including null terminator) to the size variable.
    nvs_get_str(nvs, "ssid",     ssid,     &ssid_len);
    nvs_get_str(nvs, "password", password, &pass_len);
    nvs_close(nvs);

    // WIFI_INIT_CONFIG_DEFAULT() fills the config struct with safe defaults
    // for task stack sizes, buffer counts, and feature flags. Must be called
    // before esp_wifi_init() and before any other esp_wifi_* function.
    wifi_init_config_t wifi_init_cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&wifi_init_cfg));

    // Register the event handler for Wi-Fi state changes and IP events.
    // ESP_EVENT_ANY_ID means we receive all WIFI_EVENT subtypes (connect,
    // disconnect, scan done, etc.) — we filter inside the handler.
    esp_event_handler_register(WIFI_EVENT,  ESP_EVENT_ANY_ID,    wifi_event_handler, NULL);
    esp_event_handler_register(IP_EVENT,    IP_EVENT_STA_GOT_IP, wifi_event_handler, NULL);

    // Build the Wi-Fi station config from the stored credentials.
    // strlcpy() is safer than strcpy() — it always null-terminates the output
    // and will never write past the end of the destination buffer.
    wifi_config_t wifi_config = {};
    strlcpy((char *)wifi_config.sta.ssid,     ssid,     sizeof(wifi_config.sta.ssid));
    strlcpy((char *)wifi_config.sta.password, password, sizeof(wifi_config.sta.password));

    // WIFI_MODE_STA = station mode (connects to an existing AP / router).
    // The alternative WIFI_MODE_AP is access-point mode — not used here.
    esp_wifi_set_mode(WIFI_MODE_STA);
    esp_wifi_set_config(WIFI_IF_STA, &wifi_config);

    // esp_wifi_start() powers on the Wi-Fi radio.
    // esp_wifi_connect() sends the association request to the AP.
    // Both return immediately; the actual connection result arrives as an
    // event on the event loop (IP_EVENT_STA_GOT_IP on success,
    // WIFI_EVENT_STA_DISCONNECTED on failure).
    esp_wifi_start();
    esp_wifi_connect();

    ESP_LOGI(TAG, "Connecting to SSID: %s", ssid);
    return ESP_OK;
}

esp_err_t wifi_manager_save_credentials(const char *ssid, const char *password)
{
    // NVS_READWRITE opens (or creates) the namespace for writing.
    nvs_handle_t nvs;
    ESP_ERROR_CHECK(nvs_open("wifi_creds", NVS_READWRITE, &nvs));
    nvs_set_str(nvs, "ssid",     ssid);
    nvs_set_str(nvs, "password", password);
    // nvs_commit() flushes the pending writes to flash. Without this the
    // values exist only in RAM and are lost on reboot.
    nvs_commit(nvs);
    nvs_close(nvs);
    ESP_LOGI(TAG, "Wi-Fi credentials saved for SSID: %s", ssid);
    return ESP_OK;
}

esp_err_t wifi_manager_factory_reset(void)
{
    // Erase the wifi_creds NVS namespace so the device re-enters BLE
    // provisioning mode on next boot (no credentials → NOT_FOUND path in
    // wifi_manager_connect()).
    nvs_handle_t nvs;
    if (nvs_open("wifi_creds", NVS_READWRITE, &nvs) == ESP_OK) {
        nvs_erase_all(nvs);
        nvs_commit(nvs);
        nvs_close(nvs);
    }
    ESP_LOGW(TAG, "Factory reset complete. Rebooting…");
    esp_restart();
    return ESP_OK; // unreachable; keeps the compiler warning-free
}

bool wifi_manager_is_connected(void)
{
    return s_connected;
}
