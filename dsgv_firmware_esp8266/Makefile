# ESP8266_RTOS_SDK v3.4 uses the legacy GNU-make build system. This is not
# ESP-IDF: the SDK is a frozen fork that tracks IDF v3.3-era APIs, so nothing
# in dsgv_firmware/ builds here without a portability layer.
PROJECT_NAME := dsgv_universal_8266

# coap is unused here, and its source is never fetched: the component carries a
# nested tinydtls submodule whose Eclipse Gerrit URL now redirects, which git
# refuses to follow. Excluding it keeps the build from looking for sources that
# were deliberately not cloned.
EXCLUDE_COMPONENTS := coap

include $(IDF_PATH)/make/project.mk
