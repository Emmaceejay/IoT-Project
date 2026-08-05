cmake_minimum_required(VERSION 3.16)

# Must be set before project.cmake is included — this device's actual hardware
# is an ESP32 WROOM module, not a C3 (see commit a46d3ad); locking it here
# prevents an accidental -DIDF_TARGET=esp32c3 from producing a binary that
# doesn't match the board.
set(IDF_TARGET "esp32")

# Path to shared dsgv_common component
set(EXTRA_COMPONENT_DIRS "${CMAKE_CURRENT_LIST_DIR}/../../components")

# Chain shared base config then device-specific overrides
set(SDKCONFIG_DEFAULTS
    "${CMAKE_CURRENT_LIST_DIR}/../../sdkconfig.defaults"
    "${CMAKE_CURRENT_LIST_DIR}/sdkconfig.defaults")

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

project(dsgv_1gang_switch VERSION "1.0.0")