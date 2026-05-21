cmake_minimum_required(VERSION 3.16)

# ── ESP-IDF project setup ──────────────────────────────────────────────────────
include($ENV{IDF_PATH}/tools/cmake/project.cmake)

project(dsgv_firmware)

# IDF_TARGET is NOT set here — pass it on the command line or in CMakePresets:
#   idf.py -DIDF_TARGET=esp32c3 build   (ESP32-C3 / C6)
#   idf.py -DIDF_TARGET=esp32s3 build   (ESP32-S3)
#   idf.py -DIDF_TARGET=esp32   build   (ESP32 classic)
# DSGV_config.h selects the correct GPIO pin map automatically.

# ── Source files ───────────────────────────────────────────────────────────────
idf_component_register(
    SRCS
        "main/main.c"
        "main/wifi/wifi_manager.c"
        "main/mqtt/dsgv_mqtt.c"
        "main/ota/dsgv_ota.c"
        "main/gpio/dsgv_gpio.c"
        "main/http/dsgv_http_server.c"
        "main/provisioning/dsgv_provisioning.c"
        "main/config/dsgv_device_config.c"
    INCLUDE_DIRS
        "include"
    REQUIRES
        nvs_flash
        esp_wifi
        esp_netif
        esp_event
        mqtt
        esp_https_ota
        esp_http_client
        esp_http_server
        driver
        esp_adc
        json
        bt
        esp_system
)
