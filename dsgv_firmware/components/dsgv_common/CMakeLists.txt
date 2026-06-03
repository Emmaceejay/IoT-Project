idf_component_register(
    SRCS
        # Core app initialisation — shared boot logic used by all device types
        "dsgv_app_main.c"

        # NVS-backed device configuration (identity, capabilities, relay count)
        "config/dsgv_device_config.c"

        # GPIO abstraction (relay outputs, LEDC PWM, sensor inputs)
        "gpio/dsgv_gpio.c"

        # Local HTTP REST server — Tasmota-compatible, same-LAN direct control
        "http/dsgv_http_server.c"

        # mDNS service — advertises the device on the LAN for auto-discovery
        "mdns/dsgv_mdns.c"

        # MQTT client — cloud remote control and telemetry
        "mqtt/dsgv_mqtt.c"

        # OTA (Over-The-Air) firmware updates with SHA-256 verification
        "ota/dsgv_ota.c"

        # BLE provisioning — pushes Wi-Fi credentials on first boot
        "provisioning/dsgv_provisioning.c"

        # Wi-Fi manager — connects to AP, handles reconnects, exposes IP events
        "wifi/wifi_manager.c"

    INCLUDE_DIRS
        # Public headers used by main/ and by other components
        "include"

    REQUIRES
        # NVS — Non-Volatile Storage (Wi-Fi creds, auth token, device config)
        nvs_flash

        # Wi-Fi stack and TCP/IP networking
        esp_wifi
        esp_netif
        esp_event

        # MQTT 3.1.1 client (cloud broker + local broker fallback)
        mqtt

        # OTA: esp_https_ota downloads the firmware image over HTTPS
        esp_https_ota

        # HTTP client: used to fetch broker config from Firebase Cloud Functions
        esp_http_client

        # HTTP server: serves the local REST API on port 80
        esp_http_server

        # mDNS: zero-config local network service advertisement
        mdns

        # GPIO and LEDC PWM drivers (relay outputs, dimmer, RGB, CCT)
        esp_driver_gpio
        esp_driver_ledc

        # UART driver (debug output, optional sensor serial)
        esp_driver_uart

        # ADC driver (NTC thermistor temperature sensing)
        esp_adc

        # Bluetooth host stack (NimBLE — BLE provisioning GATT server)
        bt

        # System utilities: esp_random() for hardware-entropy auth token
        esp_system

        # Partition table API: used by OTA to address the ota_0 / ota_1 slots
        esp_partition

        # High-resolution timer: telemetry interval, OTA timeout watchdog
        esp_timer

        # WPA supplicant: required by esp_wifi for WPA2 / WPA3 support
        wpa_supplicant

        # LwIP: the underlying TCP/IP stack (sockets, DNS, DHCP client)
        lwip

        # mbedTLS: TLS 1.2 for MQTT (port 8883) and HTTPS (Firebase)
        mbedtls

        # App format: esp_app_get_description() to read firmware version at runtime
        esp_app_format
)
