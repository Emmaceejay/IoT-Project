#pragma once

/**
 * dsgv_common.h — Public entry point for the dsgv_common component.
 *
 * Each device project's main.c calls dsgv_app_main() which contains the
 * full firmware initialization sequence (NVS → GPIO → Wi-Fi → HTTP → MQTT).
 * Device identity is controlled entirely by sdkconfig.defaults in each
 * device project folder via the CONFIG_DSGV_* Kconfig options.
 */

void dsgv_app_main(void);
