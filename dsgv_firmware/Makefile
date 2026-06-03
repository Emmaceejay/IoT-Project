# DSGV Hub Firmware — Makefile
#
# Wraps idf.py for multi-device builds with a simpler command interface.
# Works with the VS Code ESP-IDF extension too — right-click any device
# directory and use the extension's GUI, or use these make targets from
# the terminal.
#
# ── Usage ────────────────────────────────────────────────────────────────────
#
#   Build only:
#     make DEVICE=1gang_switch TARGET=esp32c3 build
#
#   Flash only (device must already be built):
#     make DEVICE=dimmer TARGET=esp32c3 PORT=/dev/ttyUSB0 flash
#
#   Open serial monitor (Ctrl+] to exit):
#     make DEVICE=dimmer TARGET=esp32c3 PORT=/dev/ttyUSB0 monitor
#
#   Flash then immediately open monitor (most common workflow):
#     make DEVICE=rgb_light TARGET=esp32c3 PORT=/dev/ttyUSB0 fm
#
#   Clean build artefacts for one device:
#     make DEVICE=thermostat clean
#
#   Build every device type for a given chip (CI / release):
#     make TARGET=esp32c3 build-all
#
#   List valid device names:
#     make list
#
# ── Variable defaults ─────────────────────────────────────────────────────────
#
#   DEVICE  — which device type to build (required for most targets)
#   TARGET  — ESP32 chip variant: esp32c3 (default), esp32c6, esp32s3, esp32
#   PORT    — serial port for flash/monitor: /dev/ttyUSB0 (Linux),
#             /dev/cu.usbserial-* (macOS), COM3 (Windows)
#   BAUD    — flash baud rate (default 460800 — fast but reliable)
#
# ─────────────────────────────────────────────────────────────────────────────

DEVICE  ?= 1gang_switch
TARGET  ?= esp32c3
PORT    ?= /dev/ttyUSB0
BAUD    ?= 460800

# All supported device types. Keep in sync with the devices/ directory.
DEVICES := 1gang_switch 2gang_switch 3gang_switch 4gang_switch \
           dimmer rgb_light colour_temp \
           temp_sensor motion_sensor contact_sensor \
           thermostat

# The ESP-IDF project directory for the chosen DEVICE
DEVICE_DIR := devices/$(DEVICE)

# idf.py base command: -C sets the working directory so idf.py finds the
# device's own CMakeLists.txt and sdkconfig.defaults.
IDF := idf.py -C $(DEVICE_DIR) -DIDF_TARGET=$(TARGET)

# ── Targets ───────────────────────────────────────────────────────────────────

.PHONY: build flash monitor fm clean build-all list help

## Build the firmware binary for DEVICE
build:
	$(IDF) build

## Flash the firmware to a connected device
flash:
	$(IDF) -p $(PORT) -b $(BAUD) flash

## Open the serial monitor (Ctrl+] to exit)
monitor:
	$(IDF) -p $(PORT) monitor

## Flash then immediately open the monitor — the most common dev workflow
fm:
	$(IDF) -p $(PORT) -b $(BAUD) flash monitor

## Delete build/ directory for DEVICE (keeps sdkconfig)
clean:
	$(IDF) fullclean

## Build ALL device types for TARGET (used in CI and release pipelines)
build-all:
	@echo "Building all devices for TARGET=$(TARGET)…"
	@for dev in $(DEVICES); do \
		echo ""; \
		echo "══════════════════════════════════════════"; \
		echo "  Building: $$dev  (target: $(TARGET))"; \
		echo "══════════════════════════════════════════"; \
		$(MAKE) DEVICE=$$dev TARGET=$(TARGET) build || exit 1; \
	done
	@echo ""
	@echo "All devices built successfully."

## Print all valid DEVICE names
list:
	@echo "Valid DEVICE values:"
	@for dev in $(DEVICES); do echo "  $$dev"; done

## Print this help message
help:
	@echo ""
	@echo "DSGV Hub Firmware Build System"
	@echo ""
	@echo "  make [DEVICE=<name>] [TARGET=<chip>] [PORT=<port>] <target>"
	@echo ""
	@echo "Targets:"
	@echo "  build      Build firmware binary"
	@echo "  flash      Flash to device"
	@echo "  monitor    Open serial monitor (Ctrl+] to exit)"
	@echo "  fm         Flash + monitor (most common)"
	@echo "  clean      Delete build artefacts"
	@echo "  build-all  Build every device type"
	@echo "  list       List all device names"
	@echo ""
	@echo "Variables:"
	@echo "  DEVICE  = $(DEVICE)"
	@echo "  TARGET  = $(TARGET)   (esp32c3 | esp32c6 | esp32s3 | esp32)"
	@echo "  PORT    = $(PORT)"
	@echo "  BAUD    = $(BAUD)"
	@echo ""
	@echo "Examples:"
	@echo "  make DEVICE=dimmer TARGET=esp32c3 PORT=/dev/ttyUSB0 fm"
	@echo "  make DEVICE=rgb_light TARGET=esp32s3 build"
	@echo "  make TARGET=esp32c3 build-all"
	@echo ""
