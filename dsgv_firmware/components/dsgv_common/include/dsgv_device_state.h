#pragma once

/**
 * DSGV_device_state.h
 *
 * Single shared state struct for the device. All three transport layers —
 * MQTT, local HTTP, and GPIO — read/write through this to stay in sync.
 *
 * Thread safety: acquire g_state_mutex before reading or writing.
 */

#include <stdbool.h>
#include <stdint.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

typedef struct {
    // ── Relay outputs (capabilities: "relay", "relay_2", "relay_3", "relay_4") ──
    // relay_states[0] → gang 1 (JSON key "power")
    // relay_states[1] → gang 2 (JSON key "power_2") — only used if DSGV_RELAY_COUNT >= 2
    // relay_states[2] → gang 3 (JSON key "power_3")
    // relay_states[3] → gang 4 (JSON key "power_4")
    bool relay_states[4];

    // ── Dimmer (capability: "dimmer") ─────────────────────────────────────────
    int brightness;     // 0-100 percent

    // ── Color Temperature (capability: "color_temperature") ───────────────────
    int color_temp_k;   // Kelvin, e.g. 2700 (warm) to 6500 (cool)

    // ── RGB Light (capability: "rgb_light") ───────────────────────────────────
    uint8_t rgb_r;      // 0-255
    uint8_t rgb_g;      // 0-255
    uint8_t rgb_b;      // 0-255

    // ── Humidity sensor (capability: "humidity_sensor") ───────────────────────
    float humidity;     // 0.0-100.0 % RH (updated by external I2C sensor driver)

    // ── Motion sensor (capability: "motion_sensor") ───────────────────────────
    bool motion_detected;  // true when PIR triggered

    // ── Contact sensor (capability: "contact_sensor") ─────────────────────────
    bool contact_closed;   // true = door/window closed (reed switch LOW)

    // ── HVAC (capability: "hvac_control") ─────────────────────────────────────
    float current_temp;     // degrees Celsius (internal SOC sensor or NTC ADC)
    float target_temp;      // degrees Celsius (setpoint)
    char  hvac_mode[16];    // "cool" | "heat" | "auto" | "off"

    // ── Network (populated at runtime from DHCP) ──────────────────────────────
    char local_ip[16];      // e.g. "192.168.1.42"

    // ── Power restore behaviour (persisted in NVS, user-configurable) ─────────
    // "off"     → relay(s) always start OFF after power loss  (safe default)
    // "on"      → relay(s) always start ON  after power loss
    // "restore" → relay(s) return to last known state before power loss
    char power_restore_mode[16];
} DSGV_device_state_t;

// ── Global instances (defined in DSGV_mqtt.c, used by all modules) ──────────
extern DSGV_device_state_t g_device_state;
extern SemaphoreHandle_t    g_state_mutex;

// ── Convenience macros ────────────────────────────────────────────────────────
#define STATE_LOCK()   xSemaphoreTake(g_state_mutex, portMAX_DELAY)
#define STATE_UNLOCK() xSemaphoreGive(g_state_mutex)
