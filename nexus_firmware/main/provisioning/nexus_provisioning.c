/**
 * nexus_provisioning.c
 * BLE GATT Wi-Fi provisioning for Nexus Hub (NimBLE stack, ESP32-C3).
 *
 * The device advertises a custom BLE GATT service until the Nexus Hub App
 * writes Wi-Fi credentials. On receipt, credentials are saved to NVS and
 * the device reboots into normal operating mode.
 *
 * sdkconfig requirements (add to sdkconfig.defaults or via idf.py menuconfig):
 *   CONFIG_BT_ENABLED=y
 *   CONFIG_BT_NIMBLE_ENABLED=y
 */

#include "nexus_provisioning.h"
#include "nexus_config.h"
#include "nexus_device_config.h"
#include "wifi_manager.h"

#include "esp_log.h"
#include "esp_mac.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "cJSON.h"
#include <string.h>
#include <stdio.h>

static const char *TAG = "nexus_prov";

// ── Module state ─────────────────────────────────────────────────────────────

static char     s_dev_name[24];   // "NexusHub_AABBCC\0"
static char     s_status[64];     // Current status string sent to the app
static uint16_t s_status_handle;  // Resolved GATT handle for status char
static uint16_t s_conn_handle = BLE_HS_CONN_HANDLE_NONE;

// ── UUID definitions (128-bit, stored in little-endian byte order) ─────────
//
// Standard UUID string → NimBLE BLE_UUID128_INIT byte mapping:
//   UUID:   AABBCCDD-EEFF-GGHH-IIJJ-KKLLMMNNOOPP
//   Bytes:  PP,OO,NN,MM,LL,KK,JJ,II,HH,GG,FF,EE,DD,CC,BB,AA
//
// Service: 4fafc201-1fb5-459e-8fcc-c5c9c331914b
static const ble_uuid128_t s_svc_uuid = BLE_UUID128_INIT(
    0x4b, 0x91, 0x31, 0xc3, 0xc9, 0xc5, 0xcc, 0x8f,
    0x9e, 0x45, 0xb5, 0x1f, 0x01, 0xc2, 0xaf, 0x4f
);

// Credential (Write): beb5483e-36e1-4688-b7f5-ea07361b26a8
static const ble_uuid128_t s_cred_uuid = BLE_UUID128_INIT(
    0xa8, 0x26, 0x1b, 0x36, 0x07, 0xea, 0xf5, 0xb7,
    0x88, 0x46, 0xe1, 0x36, 0x3e, 0x48, 0xb5, 0xbe
);

// Status (Read + Notify): beb5483f-36e1-4688-b7f5-ea07361b26a8
static const ble_uuid128_t s_status_uuid = BLE_UUID128_INIT(
    0xa8, 0x26, 0x1b, 0x36, 0x07, 0xea, 0xf5, 0xb7,
    0x88, 0x46, 0xe1, 0x36, 0x3f, 0x48, 0xb5, 0xbe
);

// ── Forward declarations ──────────────────────────────────────────────────────
// do_advertise() and gap_event_cb() call each other; one must be forward-declared.
static void do_advertise(void);

// ── Internal helpers ──────────────────────────────────────────────────────────

static void notify_status(void) {
    if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE) return;
    struct os_mbuf *om = ble_hs_mbuf_from_flat(
        s_status, (uint16_t)strlen(s_status));
    if (om != NULL) {
        ble_gatts_notify_custom(s_conn_handle, s_status_handle, om);
    }
}

static void set_status(const char *status_str) {
    strlcpy(s_status, status_str, sizeof(s_status));
    notify_status();
    ESP_LOGI(TAG, "Prov status: %s", s_status);
}

// Delayed reboot — lets BLE stack flush the final notification/write response
static void reboot_task(void *arg) {
    vTaskDelay(pdMS_TO_TICKS(800));
    esp_restart();
}

// ── GATT callbacks ────────────────────────────────────────────────────────────

static int credential_write_cb(uint16_t conn_handle, uint16_t attr_handle,
                                struct ble_gatt_access_ctxt *ctxt, void *arg) {
    uint16_t pkt_len = OS_MBUF_PKTLEN(ctxt->om);
    if (pkt_len == 0 || pkt_len > 383) {
        set_status("failed:payload_too_large");
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }

    char buf[384] = {0};
    if (ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf) - 1, NULL) != 0) {
        set_status("failed:read_error");
        return BLE_ATT_ERR_UNLIKELY;
    }

    cJSON *root = cJSON_Parse(buf);
    if (root == NULL) {
        ESP_LOGW(TAG, "Invalid JSON from app: %s", buf);
        set_status("failed:invalid_json");
        return BLE_ATT_ERR_UNLIKELY;
    }

    const cJSON *ssid = cJSON_GetObjectItemCaseSensitive(root, "ssid");
    const cJSON *pass = cJSON_GetObjectItemCaseSensitive(root, "password");

    if (!cJSON_IsString(ssid) || ssid->valuestring == NULL ||
        !cJSON_IsString(pass) || pass->valuestring == NULL) {
        cJSON_Delete(root);
        set_status("failed:missing_fields");
        return BLE_ATT_ERR_UNLIKELY;
    }

    ESP_LOGI(TAG, "Received credentials for SSID: %s", ssid->valuestring);

    // ── Optional device config fields ────────────────────────────────────────
    // The app may include device_type, capabilities (JSON array), and
    // relay_count to configure this unit for its hardware SKU at first boot.
    const cJSON *dev_type    = cJSON_GetObjectItemCaseSensitive(root, "device_type");
    const cJSON *caps_item   = cJSON_GetObjectItemCaseSensitive(root, "capabilities");
    const cJSON *relay_count = cJSON_GetObjectItemCaseSensitive(root, "relay_count");

    bool has_device_config = cJSON_IsString(dev_type) ||
                             cJSON_IsArray(caps_item)  ||
                             cJSON_IsNumber(relay_count);

    if (has_device_config) {
        nexus_device_config_t cfg = g_device_config; // start from current/defaults

        if (cJSON_IsString(dev_type) && dev_type->valuestring) {
            strlcpy(cfg.device_type, dev_type->valuestring, sizeof(cfg.device_type));
        }

        if (cJSON_IsArray(caps_item)) {
            // Re-serialize the JSON array to the flat string format we store
            char *caps_str = cJSON_PrintUnformatted(caps_item);
            if (caps_str) {
                strlcpy(cfg.capabilities, caps_str, sizeof(cfg.capabilities));
                cJSON_free(caps_str);
            }
        }

        if (cJSON_IsNumber(relay_count)) {
            int cnt = (int)relay_count->valuedouble;
            if (cnt >= 0 && cnt <= NEXUS_MAX_RELAY_COUNT) {
                cfg.relay_count = (uint8_t)cnt;
            }
        }

        esp_err_t cfg_err = nexus_device_config_save(&cfg);
        if (cfg_err != ESP_OK) {
            ESP_LOGW(TAG, "Device config save failed — continuing with defaults");
        } else {
            ESP_LOGI(TAG, "Device config saved: type=%s caps=%s relays=%u",
                     cfg.device_type, cfg.capabilities, cfg.relay_count);
        }
    }

    set_status("connecting");
    esp_err_t err = wifi_manager_save_credentials(ssid->valuestring,
                                                   pass->valuestring);
    cJSON_Delete(root);

    if (err != ESP_OK) {
        set_status("failed:nvs_write_error");
        return BLE_ATT_ERR_UNLIKELY;
    }

    set_status("success");
    // Reboot in a separate task so this callback can return cleanly
    // and the BLE stack has time to deliver the final notification.
    xTaskCreate(reboot_task, "prov_reboot", 2048, NULL, 5, NULL);
    return 0;
}

static int status_read_cb(uint16_t conn_handle, uint16_t attr_handle,
                           struct ble_gatt_access_ctxt *ctxt, void *arg) {
    int rc = os_mbuf_append(ctxt->om, s_status, (uint16_t)strlen(s_status));
    return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
}

// ── GATT service table ────────────────────────────────────────────────────────

static const struct ble_gatt_svc_def s_gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]){
            {
                // Write JSON credentials here
                .uuid       = &s_cred_uuid.u,
                .access_cb  = credential_write_cb,
                .flags      = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
            },
            {
                // Read or subscribe to provisioning status
                .uuid       = &s_status_uuid.u,
                .access_cb  = status_read_cb,
                .flags      = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &s_status_handle,
            },
            { 0 }, // end of characteristics
        },
    },
    { 0 }, // end of services
};

// ── BLE advertising ───────────────────────────────────────────────────────────

static void do_advertise(void) {
    struct ble_hs_adv_fields fields = {0};
    fields.flags             = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.name              = (const uint8_t *)s_dev_name;
    fields.name_len          = (uint8_t)strlen(s_dev_name);
    fields.name_is_complete  = 1;

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gap_adv_set_fields failed: rc=%d", rc);
        return;
    }

    struct ble_gap_adv_params adv_params = {0};
    adv_params.conn_mode = BLE_GAP_CONN_MODE_UND; // undirected connectable
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;

    // Advertise indefinitely (BLE_HS_FOREVER) — device reboots on success
    rc = ble_gap_adv_start(BLE_OWN_ADDR_PUBLIC, NULL, BLE_HS_FOREVER,
                            &adv_params, gap_event_cb, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gap_adv_start failed: rc=%d", rc);
        return;
    }

    ESP_LOGI(TAG, "BLE advertising: %s", s_dev_name);
    ESP_LOGI(TAG, "Provision QR  : nexus://provision?name=%s", s_dev_name);
}

static int gap_event_cb(struct ble_gap_event *event, void *arg) {
    switch (event->type) {
        case BLE_GAP_EVENT_CONNECT:
            if (event->connect.status == 0) {
                s_conn_handle = event->connect.conn_handle;
                ESP_LOGI(TAG, "App connected (handle=%d)", s_conn_handle);
            } else {
                // Failed — restart advertising so another attempt is possible
                do_advertise();
            }
            break;

        case BLE_GAP_EVENT_DISCONNECT:
            ESP_LOGI(TAG, "App disconnected (reason=%d)",
                     event->disconnect.reason);
            s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
            // Restart advertising unless we're about to reboot
            if (strcmp(s_status, "success") != 0) {
                do_advertise();
            }
            break;

        case BLE_GAP_EVENT_SUBSCRIBE:
            if (event->subscribe.attr_handle == s_status_handle &&
                event->subscribe.cur_notify) {
                ESP_LOGD(TAG, "App subscribed to status notifications");
            }
            break;

        default:
            break;
    }
    return 0;
}

// ── NimBLE host lifecycle ─────────────────────────────────────────────────────

static void ble_on_sync(void) {
    // Ensure we have a usable public address before advertising
    int rc = ble_hs_util_ensure_addr(0);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_hs_util_ensure_addr failed: rc=%d", rc);
        return;
    }
    do_advertise();
}

static void ble_on_reset(int reason) {
    ESP_LOGE(TAG, "BLE host stack reset (reason=%d). Advertising will resume.",
             reason);
}

static void ble_host_task(void *param) {
    ESP_LOGI(TAG, "NimBLE host task running");
    nimble_port_run();              // Blocks until nimble_port_stop()
    nimble_port_freertos_deinit();
}

// ── Public API ────────────────────────────────────────────────────────────────

esp_err_t nexus_provisioning_start(void) {
    // Build device name from BT MAC: "NexusHub_AABBCC"
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_BT);
    snprintf(s_dev_name, sizeof(s_dev_name),
             "%s%02X%02X%02X",
             NEXUS_PROV_DEVICE_NAME_PREFIX, mac[3], mac[4], mac[5]);

    strlcpy(s_status, "idle", sizeof(s_status));

    ESP_LOGI(TAG, "Initialising BLE provisioning (%s)…", s_dev_name);

    esp_err_t ret = nimble_port_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init failed: %d", ret);
        return ret;
    }

    // Register host sync/reset callbacks
    ble_hs_cfg.sync_cb  = ble_on_sync;
    ble_hs_cfg.reset_cb = ble_on_reset;

    // Initialise standard GAP and GATT services
    ble_svc_gap_init();
    ble_svc_gatt_init();
    ble_svc_gap_device_name_set(s_dev_name);

    // Register the custom provisioning GATT service
    int rc = ble_gatts_count_cfg(s_gatt_svcs);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gatts_count_cfg failed: rc=%d", rc);
        return ESP_FAIL;
    }
    rc = ble_gatts_add_svcs(s_gatt_svcs);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gatts_add_svcs failed: rc=%d", rc);
        return ESP_FAIL;
    }

    // Hand off to the NimBLE FreeRTOS host task — returns immediately
    nimble_port_freertos_init(ble_host_task);

    return ESP_OK;
}
