#pragma once

/**
 * DSGV_gpio.h — Public GPIO/hardware layer API
 *
 * Exposes relay control, LEDC PWM outputs (dimmer, CCT, RGB), and the
 * all-at-once state-apply helper used by MQTT and HTTP command handlers.
 */

#include <stdbool.h>
#include <stdint.h>

// Initialise all GPIO outputs, LEDC PWM channels, ADC, internal temperature
// sensor (if SOC_TEMP_SENSOR_SUPPORTED), motion/contact input interrupts, and
// the background sensor/telemetry FreeRTOS task.
// Must be called once, after DSGV_mqtt_start() (needs g_state_mutex).
void DSGV_gpio_init(void);

// ── Relay outputs (capabilities: "relay" … "relay_4") ────────────────────────
// DSGV_gpio_relay_set() controls gang 0 (the primary relay), e.g. from a
// physical button handler. MQTT / HTTP commands use DSGV_gpio_apply_state()
// which drives all gangs from g_device_state.relay_states[] at once.
void DSGV_gpio_relay_set(bool on);   // gang 0 convenience wrapper
bool DSGV_gpio_relay_get(void);

// ── Dimmer (capability: "dimmer") ────────────────────────────────────────────
void DSGV_gpio_dimmer_set(int pct);    // 0-100 %

// ── Color temperature (capability: "color_temperature") ──────────────────────
void DSGV_gpio_ct_set(int kelvin);     // 2000-6500 K — blends warm/cool PWM

// ── RGB light (capability: "rgb_light") ──────────────────────────────────────
void DSGV_gpio_rgb_set(uint8_t r, uint8_t g, uint8_t b);  // 0-255 per channel

// ── Apply full g_device_state to all hardware outputs ────────────────────────
// Called by MQTT handle_command() and HTTP apply_capability() after any state
// update so relay, LEDC PWM, and LED all reflect the latest command.
void DSGV_gpio_apply_state(void);
