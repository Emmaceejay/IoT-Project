cmake_minimum_required(VERSION 3.16)

# ── ESP-IDF project setup ──────────────────────────────────────────────────────
include($ENV{IDF_PATH}/tools/cmake/project.cmake)

project(nexus_firmware)

# Target: ESP32-C3 (Matter-capable, BLE + Wi-Fi, small form factor)
# Change to esp32 or esp32s3 depending on your hardware
set(IDF_TARGET esp32c3)

# ── Source files ───────────────────────────────────────────────────────────────
idf_component_register(
    SRCS
        "main/main.c"
        "main/wifi/wifi_manager.c"
        "main/mqtt/nexus_mqtt.c"
        "main/ota/nexus_ota.c"
        "main/gpio/nexus_gpio.c"
    INCLUDE_DIRS
        "include"
    REQUIRES
        nvs_flash
        esp_wifi
        esp_event
        mqtt
        esp_https_ota
        esp_http_client
        driver
        json
)
