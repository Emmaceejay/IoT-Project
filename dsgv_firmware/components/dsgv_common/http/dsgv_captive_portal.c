/**
 * dsgv_captive_portal.c
 *
 * Captive portal HTTP server for the device's setup Access Point.
 * Triggered automatically when Wi-Fi credentials exist but the network is
 * unreachable — instead of halting, the device becomes its own AP and
 * serves this page so the user can supply new credentials without a
 * factory reset or QR scan.
 *
 * Captive portal detection URLs handled:
 *   Android  — /generate_204
 *   iOS      — /hotspot-detect.html
 *   Windows  — /connecttest.txt, /ncsi.txt
 *   Linux    — /generate_204
 * All redirect to / so the form opens automatically in the phone's browser.
 */

#include "dsgv_captive_portal.h"
#include "wifi_manager.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

static const char *TAG = "DSGV_portal";
static httpd_handle_t s_server = NULL;

// ── Embedded HTML pages ───────────────────────────────────────────────────────

static const char SETUP_HTML[] =
    "<!DOCTYPE html>"
    "<html><head>"
    "<meta charset='utf-8'>"
    "<meta name='viewport' content='width=device-width,initial-scale=1'>"
    "<title>DSGV Device Setup</title>"
    "<style>"
    "body{font-family:system-ui,sans-serif;max-width:420px;margin:40px auto;"
         "padding:0 20px;background:#0a0e1a;color:#fff}"
    "h1{color:#00e5ff;font-size:22px;margin-bottom:4px}"
    "p{color:#aaa;font-size:14px;line-height:1.5}"
    "label{display:block;margin:16px 0 4px;color:#aaa;font-size:13px}"
    "input{width:100%;padding:12px;background:#1a2236;border:1px solid #333;"
          "border-radius:8px;color:#fff;font-size:15px;box-sizing:border-box}"
    "input:focus{border-color:#00e5ff;outline:none}"
    "button{width:100%;padding:14px;margin-top:20px;background:#00e5ff;"
            "color:#000;border:none;border-radius:8px;font-size:16px;"
            "font-weight:600;cursor:pointer}"
    "button:active{opacity:.85}"
    ".note{margin-top:24px;font-size:12px;color:#555;text-align:center}"
    "</style></head><body>"
    "<h1>Connect to Wi-Fi</h1>"
    "<p>Enter your home network details. The device will save them and reconnect automatically.</p>"
    "<form method='POST' action='/wifi'>"
    "<label>Network name (SSID)</label>"
    "<input name='ssid' placeholder='MyHomeNetwork' required "
           "autocomplete='off' autocorrect='off' autocapitalize='none'>"
    "<label>Password</label>"
    "<input type='password' name='password' "
           "placeholder='Leave blank for open networks' autocomplete='current-password'>"
    "<button type='submit'>Connect Device</button>"
    "</form>"
    "<p class='note'>Credentials are sent directly to the device over your local network "
    "and are never uploaded to any server.</p>"
    "</body></html>";

static const char SUCCESS_HTML[] =
    "<!DOCTYPE html>"
    "<html><head>"
    "<meta charset='utf-8'>"
    "<meta name='viewport' content='width=device-width,initial-scale=1'>"
    "<title>Connecting\xe2\x80\xa6</title>"
    "<style>"
    "body{font-family:system-ui,sans-serif;max-width:420px;margin:60px auto;"
         "padding:20px;background:#0a0e1a;color:#fff;text-align:center}"
    "h1{color:#00e5ff}"
    "p{color:#aaa;font-size:14px;line-height:1.6}"
    ".check{font-size:48px;margin-bottom:16px}"
    "</style></head><body>"
    "<div class='check'>\xe2\x9c\x93</div>"
    "<h1>Credentials saved!</h1>"
    "<p>The device is connecting to your network.<br>"
    "This page will stop loading \xe2\x80\x94 that is normal.</p>"
    "<p>Reconnect your phone to your home Wi-Fi, then open the <strong>DSGV App</strong> "
    "to confirm the device is back online.</p>"
    "</body></html>";

// ── Helpers ───────────────────────────────────────────────────────────────────

// URL-decode a percent-encoded string (in-place safe when dst == src is avoided).
static void url_decode(char *dst, size_t dst_len, const char *src) {
    size_t di = 0;
    for (size_t i = 0; src[i] && di < dst_len - 1; i++) {
        if (src[i] == '%' && src[i+1] && src[i+2]) {
            char hex[3] = { src[i+1], src[i+2], '\0' };
            dst[di++] = (char)strtol(hex, NULL, 16);
            i += 2;
        } else if (src[i] == '+') {
            dst[di++] = ' ';
        } else {
            dst[di++] = src[i];
        }
    }
    dst[di] = '\0';
}

// Extract a field from application/x-www-form-urlencoded body.
// Returns true and writes the URL-decoded value into out on success.
static bool parse_field(const char *body, const char *key,
                         char *out, size_t out_len) {
    size_t klen = strlen(key);
    const char *p = body;
    while (p && *p) {
        if (strncmp(p, key, klen) == 0 && p[klen] == '=') {
            const char *val  = p + klen + 1;
            const char *next = strchr(val, '&');
            size_t      vlen = next ? (size_t)(next - val) : strlen(val);
            if (vlen >= out_len) vlen = out_len - 1;
            char encoded[256] = {0};
            memcpy(encoded, val, vlen);
            url_decode(out, out_len, encoded);
            return true;
        }
        p = strchr(p, '&');
        if (p) p++;
    }
    out[0] = '\0';
    return false;
}

static void reboot_task(void *arg) {
    vTaskDelay(pdMS_TO_TICKS(1200));
    esp_restart();
}

// ── HTTP handlers ─────────────────────────────────────────────────────────────

// GET / → setup form
static esp_err_t handle_root(httpd_req_t *req) {
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    httpd_resp_send(req, SETUP_HTML, (ssize_t)strlen(SETUP_HTML));
    return ESP_OK;
}

// POST /wifi → parse form, save creds, reboot
static esp_err_t handle_wifi_post(httpd_req_t *req) {
    char body[384] = {0};
    int  received  = httpd_req_recv(req, body,
                         (size_t)req->content_len < sizeof(body) - 1
                             ? req->content_len : sizeof(body) - 1);
    if (received <= 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Empty body");
        return ESP_FAIL;
    }
    body[received] = '\0';

    char ssid[64]  = {0};
    char pass[128] = {0};
    parse_field(body, "ssid",     ssid, sizeof(ssid));
    parse_field(body, "password", pass, sizeof(pass));

    if (ssid[0] == '\0') {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "SSID is required");
        return ESP_FAIL;
    }

    // Send success page before rebooting so the browser gets a response
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    httpd_resp_send(req, SUCCESS_HTML, (ssize_t)strlen(SUCCESS_HTML));

    wifi_manager_save_credentials(ssid, pass);
    ESP_LOGI(TAG, "Portal: credentials saved for SSID '%s'. Rebooting…", ssid);
    xTaskCreate(reboot_task, "portal_reboot", 2048, NULL, 5, NULL);
    return ESP_OK;
}

// Captive portal detection redirect → / so the browser opens the form
static esp_err_t handle_redirect(httpd_req_t *req) {
    httpd_resp_set_status(req, "302 Found");
    httpd_resp_set_hdr(req, "Location", "http://192.168.4.1/");
    httpd_resp_send(req, NULL, 0);
    return ESP_OK;
}

// ── Public API ────────────────────────────────────────────────────────────────

esp_err_t DSGV_captive_portal_start(void) {
    if (s_server) return ESP_OK;   // already running

    httpd_config_t cfg  = HTTPD_DEFAULT_CONFIG();
    cfg.server_port     = 80;
    cfg.max_uri_handlers = 10;
    cfg.stack_size      = 8192;

    if (httpd_start(&s_server, &cfg) != ESP_OK) {
        ESP_LOGE(TAG, "Failed to start captive portal HTTP server");
        return ESP_FAIL;
    }

    // Core handlers
    static const httpd_uri_t root    = { .uri = "/",     .method = HTTP_GET,  .handler = handle_root };
    static const httpd_uri_t post_w  = { .uri = "/wifi", .method = HTTP_POST, .handler = handle_wifi_post };

    // OS captive portal detection probes — all redirect to /
    static const httpd_uri_t r204    = { .uri = "/generate_204",        .method = HTTP_GET, .handler = handle_redirect };
    static const httpd_uri_t rhs     = { .uri = "/hotspot-detect.html", .method = HTTP_GET, .handler = handle_redirect };
    static const httpd_uri_t rconn   = { .uri = "/connecttest.txt",     .method = HTTP_GET, .handler = handle_redirect };
    static const httpd_uri_t rncsi   = { .uri = "/ncsi.txt",            .method = HTTP_GET, .handler = handle_redirect };
    static const httpd_uri_t rcan    = { .uri = "/canonical.html",      .method = HTTP_GET, .handler = handle_redirect };
    static const httpd_uri_t rsuccess= { .uri = "/success.txt",         .method = HTTP_GET, .handler = handle_redirect };

    httpd_register_uri_handler(s_server, &root);
    httpd_register_uri_handler(s_server, &post_w);
    httpd_register_uri_handler(s_server, &r204);
    httpd_register_uri_handler(s_server, &rhs);
    httpd_register_uri_handler(s_server, &rconn);
    httpd_register_uri_handler(s_server, &rncsi);
    httpd_register_uri_handler(s_server, &rcan);
    httpd_register_uri_handler(s_server, &rsuccess);

    ESP_LOGI(TAG, "Captive portal ready at http://192.168.4.1/");
    return ESP_OK;
}
