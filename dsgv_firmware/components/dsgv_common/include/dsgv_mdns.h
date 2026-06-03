#pragma once

/**
 * dsgv_mdns.h — mDNS (Multicast DNS) service for local network discovery.
 *
 * What this does:
 *   When the DSGV Hub App opens on your phone it broadcasts a multicast DNS
 *   query asking "is anyone offering a _dsgv._tcp service?". Every DSGV
 *   device on the same Wi-Fi network replies with its hostname and IP address.
 *   The app uses this to fill in the device's local IP — enabling sub-10 ms
 *   direct HTTP commands without the device first publishing its IP over MQTT.
 *
 * Usage:
 *   Call DSGV_mdns_start() once after Wi-Fi connects and gets a DHCP lease.
 *   Call DSGV_mdns_stop() only on graceful shutdown (rare on embedded targets).
 *   Call DSGV_mdns_restart() when the IP address changes (DHCP lease renewal).
 *
 * The ESP-IDF mdns component is used internally. It is part of the standard
 * ESP-IDF distribution — no extra idf_component.yml entry is needed.
 */

#include "esp_err.h"

/**
 * Start the mDNS service and advertise this device on the local network.
 *
 * Registers two services:
 *   _dsgv._tcp   port 80 — queried by the DSGV Hub App
 *   _http._tcp   port 80 — Tasmota-tool compatibility
 *
 * TXT records attached to _dsgv._tcp:
 *   id   = WiFi MAC address (matches MQTT device_id)
 *   caps = capabilities JSON string (e.g. ["relay","brightness"])
 *   type = device type label (e.g. "Switch")
 *   fw   = firmware version string
 *
 * @return ESP_OK on success, or an esp_err_t code on failure.
 */
esp_err_t DSGV_mdns_start(void);

/**
 * Stop the mDNS service and free its resources.
 * Rarely needed on embedded targets — call only before a graceful shutdown.
 */
void DSGV_mdns_stop(void);

/**
 * Stop then restart mDNS. Call this when the device gets a new DHCP lease
 * (IP_EVENT_STA_GOT_IP fires again after a lease renewal or reconnect).
 * The mDNS stack reads the current network interface IP automatically on
 * restart, so the new IP is advertised without any extra configuration.
 *
 * @return ESP_OK on success, or an esp_err_t code on failure.
 */
esp_err_t DSGV_mdns_restart(void);
