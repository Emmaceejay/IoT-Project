# ── DSGV Hub Firmware — Multi-Device Monorepo ────────────────────────────────
#
# There is NO top-level ESP-IDF project here.
# Each device SKU is a standalone ESP-IDF project under devices/<device_name>/.
#
# BUILD A DEVICE:
#   cd devices/dimmer
#   idf.py -DIDF_TARGET=esp32c3 build
#   idf.py -p COM5 flash monitor
#
# BUILD ALL DEVICES (PowerShell):
#   .\scripts\build_all.ps1 esp32c3
#
# BUILD ONE DEVICE (PowerShell shortcut):
#   .\scripts\build_device.ps1 dimmer esp32c3
#   .\scripts\build_device.ps1 2gang_switch esp32 COM5
#
# SHARED COMPONENT (never edit per device):
#   components/dsgv_common/
#
# THE ONLY FILE TO EDIT PER DEVICE:
#   devices/<device_name>/sdkconfig.defaults
# ─────────────────────────────────────────────────────────────────────────────
