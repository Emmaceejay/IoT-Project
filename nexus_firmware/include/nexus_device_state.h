#pragma once

/**
 * nexus_device_state.h
 *
 * Single shared state struct for the device. All three transport layers —
 * MQTT, local HTTP, and GPIO — read/write through this to stay in sync.
 *
 * Thread safety: acquire g_state_mutex before reading or writing.
 */

#include <stdbool.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

typedef struct {
    // ── Relay / On-Off ────────────────────────────────────────────────────────
    bool power;

    // ── Dimmer (capability: "dimmer") ─────────────────────────────────────────
    int brightness;     // 0-100 percent

    // ── Color Temperature (capability: "color_temperature") ───────────────────
    int color_temp_k;   // Kelvin, e.g. 2700 (warm) to 6500 (cool)

    // ── HVAC (capability: "hvac_control") ─────────────────────────────────────
    float current_temp;     // degrees Celsius (sensor reading)
    float target_temp;      // degrees Celsius (setpoint)
    char  hvac_mode[16];    // "cool" | "heat" | "auto" | "off"

    // ── Network (populated at runtime from DHCP) ──────────────────────────────
    char local_ip[16];      // e.g. "192.168.1.42"
} nexus_device_state_t;

// ── Global instances (defined in nexus_mqtt.c, used by all modules) ──────────
extern nexus_device_state_t g_device_state;
extern SemaphoreHandle_t    g_state_mutex;

// ── Convenience macros ────────────────────────────────────────────────────────
#define STATE_LOCK()   xSemaphoreTake(g_state_mutex, portMAX_DELAY)
#define STATE_UNLOCK() xSemaphoreGive(g_state_mutex)
