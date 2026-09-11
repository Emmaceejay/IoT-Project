/**
 * DSGV ESP8266 firmware — toolchain proof.
 *
 * Deliberately minimal. Its only job right now is to establish that the
 * ESP8266_RTOS_SDK toolchain builds in CI and produces a flashable image.
 * The device logic is ported on top of this once that is green, one piece at
 * a time with CI verifying each step — the same discipline that surfaced 17
 * defects in the ESP32 firmware, all of which existed because nothing had
 * ever compiled it.
 */

#include "esp_system.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "dsgv8266";

void app_main(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    ESP_LOGI(TAG, "DSGV ESP8266 firmware starting");
    ESP_LOGI(TAG, "SDK: %s", esp_get_idf_version());
    ESP_LOGI(TAG, "free heap: %u bytes", esp_get_free_heap_size());
}
