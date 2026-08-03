/**
 * dsgv_events.h — Internal event bus: decouples GPIO hardware from MQTT transport.
 *
 * Problem solved: dsgv_gpio.c previously called DSGV_mqtt_publish_telemetry()
 * directly, creating a hard compile-time dependency (GPIO cannot build without
 * MQTT linked). This layer breaks that coupling:
 *
 *   GPIO  →  dsgv_events_post_telemetry()  →  event queue
 *                                               ↓ (consumer task)
 *   MQTT  ←  DSGV_mqtt_publish_telemetry()  ←  event consumer
 *
 * GPIO layer posts a pre-built JSON string and returns immediately.
 * The consumer task (priority 2, stack 4 KB) calls the MQTT publish
 * asynchronously — MQTT may not even be connected yet and that is fine.
 *
 * Call dsgv_events_init() from dsgv_app_main() BEFORE DSGV_gpio_init().
 */

#pragma once

#include "freertos/FreeRTOS.h"

// Maximum JSON telemetry payload in bytes (matches gpio build_telemetry buffer).
#define DSGV_TELEMETRY_JSON_MAX 512

typedef enum {
    DSGV_EVENT_TELEMETRY_NEEDED,  // post-change telemetry publish
} dsgv_event_type_t;

typedef struct {
    dsgv_event_type_t type;
    char              json[DSGV_TELEMETRY_JSON_MAX];
} dsgv_event_t;

// Initialize the event queue and start the consumer task.
// Must be called before any dsgv_events_post_telemetry() call.
void dsgv_events_init(void);

// Post a pre-built telemetry JSON string for async MQTT publish.
// Non-blocking: if the queue is full the payload is silently dropped;
// the sensor heartbeat will republish within DSGV_TELEMETRY_INTERVAL_MS.
// Safe to call from any FreeRTOS task context.
void dsgv_events_post_telemetry(const char *json_payload);
