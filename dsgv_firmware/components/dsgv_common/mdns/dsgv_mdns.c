/**
 * dsgv_mdns.c — mDNS (Multicast DNS) service implementation.
 *
 * How mDNS works (brief primer for learners):
 *   Normal DNS requires a DNS server (e.g., your router) to translate names
 *   like "kitchen-switch.local" into IP addresses. mDNS is the zero-config
 *   alternative: every device on the LAN listens on the multicast address
 *   224.0.0.251 : 5353 and answers queries about itself directly.
 *
 *   When the DSGV Hub App wants to find all smart devices on the LAN, it
 *   sends one mDNS PTR query: "who provides _dsgv._tcp.local?". Each device
 *   replies with a set of DNS records:
 *     PTR   _dsgv._tcp.local → dsgv-a1b2c3.local   (service pointer)
 *     SRV   dsgv-a1b2c3.local : 80                  (hostname + port)
 *     A     dsgv-a1b2c3.local → 192.168.1.42         (IP address)
 *     TXT   id=A1B2C3 caps=["relay"] type=Switch fw=1.0.0
 *
 *   The ESP-IDF mdns component handles all of this automatically once we
 *   call mdns_service_add() with the right parameters.
 */

#include <string.h>
#include <stdio.h>
#include "esp_log.h"
#include "esp_wifi.h"
#include "esp_mac.h"
#include "mdns.h"
#include "dsgv_mdns.h"
#include "dsgv_config.h"
#include "dsgv_device_config.h"  // provides g_device_config (type, capabilities, etc.)

static const char *TAG = "DSGV_mdns";

/* ── Helpers ──────────────────────────────────────────────────────────────── */

/**
 * Build the mDNS hostname string: "dsgv-<MAC_NO_COLONS>"
 * e.g. "dsgv-a1b2c3d4e5f6"
 *
 * The hostname is written into the caller-supplied buffer. The MAC address is
 * read from the Wi-Fi station interface — it matches the device_id used in
 * MQTT topics so the app can correlate them.
 *
 * @param buf    Output buffer. Must be at least 20 bytes.
 * @param buflen Length of buf.
 */
static void build_hostname(char *buf, size_t buflen)
{
    uint8_t mac[6];
    // esp_wifi_get_mac() returns the 6-byte MAC of the requested interface.
    // WIFI_IF_STA is the station (client) interface — the one that connects
    // to the home router and gets the DHCP lease.
    esp_wifi_get_mac(WIFI_IF_STA, mac);
    snprintf(buf, buflen, "dsgv-%02x%02x%02x%02x%02x%02x",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

/**
 * Register the two mDNS services with their TXT records.
 *
 * _dsgv._tcp — queried by the DSGV Hub App
 * _http._tcp — for Tasmota-aware tools that already know to look for HTTP
 *
 * TXT records are key=value pairs embedded in the mDNS reply. They are how
 * the device broadcasts its identity without the app needing to make a
 * separate HTTP request just to learn what type of device this is.
 */
static esp_err_t register_services(void)
{
    // Build the MAC-based device ID string (uppercase, no separators)
    // to match the format used in MQTT topics: "A1B2C3D4E5F6"
    uint8_t mac[6];
    char mac_str[13]; // 12 hex chars + null terminator
    esp_wifi_get_mac(WIFI_IF_STA, mac);
    snprintf(mac_str, sizeof(mac_str), "%02X%02X%02X%02X%02X%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);

    // ── Primary service: _dsgv._tcp ───────────────────────────────────────
    // mdns_service_add() registers a service entry in the mDNS responder.
    // Parameters:
    //   instance_name : human-readable label shown in discovery UIs
    //   service_type  : the service name (must start with underscore)
    //   proto         : transport protocol ("_tcp" or "_udp")
    //   port          : TCP port this service listens on
    //   txt           : array of key=value TXT record items
    //   num_items     : number of TXT items

    mdns_txt_item_t dsgv_txt[] = {
        // "id" — the device's unique identifier. Matches the MQTT topic
        // prefix "devices/<id>/..." so the app can join LAN discovery
        // results with MQTT announce data.
        { .key = "id",   .value = mac_str },

        // "caps" — the capabilities JSON array. The app reads this to
        // determine which UI controls to render for this device.
        // Must fit in a single TXT record value (max 255 bytes).
        { .key = "caps", .value = DSGV_DEVICE_CAPABILITIES },

        // "type" — the device type label (e.g. "Switch", "Dimmer").
        // Used for icon selection and display name in the device list.
        { .key = "type", .value = DSGV_DEVICE_TYPE },

        // "fw" — the running firmware version. The app compares this
        // against the latest available version to flag pending OTA updates.
        { .key = "fw",   .value = dsgv_firmware_VERSION },
    };

    esp_err_t err = mdns_service_add(
        /* instance_name */ DSGV_DEVICE_TYPE,   // e.g. "Switch"
        /* service_type  */ MDNS_SERVICE_DSGV,  // "_dsgv"
        /* proto         */ MDNS_PROTO_TCP,     // "_tcp"
        /* port          */ MDNS_HTTP_PORT,     // 80
        /* txt           */ dsgv_txt,
        /* num_items     */ sizeof(dsgv_txt) / sizeof(dsgv_txt[0])
    );
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to add _dsgv._tcp service: %s",
                 esp_err_to_name(err));
        return err;
    }

    // ── Secondary service: _http._tcp ─────────────────────────────────────
    // Registering _http._tcp lets any tool that does standard HTTP service
    // discovery (e.g. Home Assistant, curl with mDNS, Tasmota-aware apps)
    // find the device without knowing about the DSGV-specific service type.
    err = mdns_service_add(
        /* instance_name */ DSGV_DEVICE_TYPE,
        /* service_type  */ MDNS_SERVICE_HTTP,  // "_http"
        /* proto         */ MDNS_PROTO_TCP,
        /* port          */ MDNS_HTTP_PORT,
        /* txt           */ NULL,               // no TXT records needed here
        /* num_items     */ 0
    );
    if (err != ESP_OK) {
        // Not fatal — the primary _dsgv service already works.
        ESP_LOGW(TAG, "Failed to add _http._tcp service: %s",
                 esp_err_to_name(err));
    }

    return ESP_OK;
}

/* ── Public API ───────────────────────────────────────────────────────────── */

esp_err_t DSGV_mdns_start(void)
{
    // mdns_init() starts the mDNS responder task inside ESP-IDF.
    // It registers the device on the multicast group 224.0.0.251:5353.
    esp_err_t err = mdns_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "mdns_init failed: %s", esp_err_to_name(err));
        return err;
    }

    // Set the hostname — this becomes the ".local" domain name for the device.
    // e.g. "dsgv-a1b2c3d4e5f6.local"
    // The hostname must be unique on the LAN. Using the MAC address guarantees
    // uniqueness without any coordination between devices.
    char hostname[20];
    build_hostname(hostname, sizeof(hostname));
    err = mdns_hostname_set(hostname);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "mdns_hostname_set failed: %s", esp_err_to_name(err));
        mdns_free();
        return err;
    }

    // The instance name appears in discovery UI tools (e.g. "Switch" or
    // "Kitchen Dimmer"). We use the device type for now; you could later
    // replace this with the user-assigned name stored in NVS.
    err = mdns_instance_name_set(DSGV_DEVICE_TYPE);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "mdns_instance_name_set failed: %s",
                 esp_err_to_name(err));
        mdns_free();
        return err;
    }

    // Register the _dsgv._tcp and _http._tcp service entries.
    err = register_services();
    if (err != ESP_OK) {
        mdns_free();
        return err;
    }

    ESP_LOGI(TAG, "mDNS started: %s.local  (_dsgv._tcp port %d)",
             hostname, MDNS_HTTP_PORT);
    return ESP_OK;
}

void DSGV_mdns_stop(void)
{
    // mdns_free() deregisters all services, leaves the multicast group,
    // and deletes the mDNS responder task.
    mdns_free();
    ESP_LOGI(TAG, "mDNS stopped.");
}

esp_err_t DSGV_mdns_restart(void)
{
    // Stop first so we cleanly deregister the old advertisement, then
    // start again so the new IP (from the fresh DHCP lease) is announced.
    // The mDNS stack reads the current netif IP on init, so no explicit
    // IP address parameter is needed.
    ESP_LOGI(TAG, "mDNS restarting (DHCP lease renewed)…");
    DSGV_mdns_stop();
    return DSGV_mdns_start();
}
