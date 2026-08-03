/**
 * dsgv_events.c — Event bus consumer: GPIO-to-MQTT telemetry bridge.
 *
 * The GPIO layer posts pre-built JSON telemetry to the event queue and returns
 * immediately — it has no knowledge of MQTT.  This task wakes on each posted
 * event and forwards the payload to DSGV_mqtt_publish_telemetry(), which is
 * a no-op when MQTT is disconnected (s_client == NULL guard inside mqtt.c).
 *
 * Queue depth 8 × 512 B = 4 KB heap.  On queue overflow, the excess publish
 * is silently dropped; the sensor heartbeat re-syncs within TELEMETRY_INTERVAL_MS.
 */

#include "dsgv_events.h"
#include "esp_log.h"
#include "freertos/task.h"
#include <string.h>

static const char     *TAG     = "DSGV_events";
static QueueHandle_t   s_queue = NULL;

// Forward declaration — implemented in dsgv_mqtt.c.
// dsgv_events.c depends on mqtt, not the other way around (no cycle).
extern void DSGV_mqtt_publish_telemetry(const char *json_payload);

// ── Consumer task ─────────────────────────────────────────────────────────────

static void event_consumer_task(void *arg) {
    (void)arg;
    dsgv_event_t evt;
    for (;;) {
        if (xQueueReceive(s_queue, &evt, portMAX_DELAY) == pdTRUE) {
            if (evt.type == DSGV_EVENT_TELEMETRY_NEEDED) {
                DSGV_mqtt_publish_telemetry(evt.json);
            }
        }
    }
}

// ── Public API ────────────────────────────────────────────────────────────────

void dsgv_events_init(void) {
    s_queue = xQueueCreate(8, sizeof(dsgv_event_t));
    configASSERT(s_queue != NULL);
    xTaskCreate(event_consumer_task, "DSGV_events", 4096, NULL, 2, NULL);
    ESP_LOGI(TAG, "Event bus ready (queue depth 8, payload %u B)", DSGV_TELEMETRY_JSON_MAX);
}

void dsgv_events_post_telemetry(const char *json_payload) {
    if (!s_queue || !json_payload) return;
    dsgv_event_t evt;
    evt.type = DSGV_EVENT_TELEMETRY_NEEDED;
    strncpy(evt.json, json_payload, sizeof(evt.json) - 1);
    evt.json[sizeof(evt.json) - 1] = '\0';
    // xQueueSend with zero ticks: non-blocking, drops payload if queue full.
    xQueueSend(s_queue, &evt, 0);
}
