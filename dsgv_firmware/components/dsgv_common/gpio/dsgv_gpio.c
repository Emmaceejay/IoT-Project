/**
 * DSGV_gpio.c — GPIO, LEDC PWM, and sensor layer
 *
 * Drives:  relay output, status LED, LEDC dimmer / CCT / RGB PWM channels.
 * Reads:   internal SOC temperature sensor (ESP32-C3/C6/S3),
 *          ADC NTC thermistor (fallback on all chips),
 *          PIR motion digital input, reed-contact digital input.
 *
 * All state is read/written through g_device_state under g_state_mutex.
 * A background FreeRTOS task reads sensors every DSGV_TELEMETRY_INTERVAL_MS
 * and publishes a telemetry snapshot via DSGV_mqtt_publish_telemetry().
 * Motion and contact ISRs wake the task immediately on edge events.
 */

#include "dsgv_gpio.h"
#include "dsgv_config.h"
#include "dsgv_device_config.h"
#include "dsgv_device_state.h"
#include "wifi_manager.h"

#include "driver/gpio.h"
#include "driver/ledc.h"
#include "esp_adc/adc_oneshot.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "esp_timer.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

#if SOC_TEMP_SENSOR_SUPPORTED
#include "driver/temperature_sensor.h"
#endif

static const char *TAG = "DSGV_gpio";

// ── Module state ──────────────────────────────────────────────────────────────

static bool s_ledc_initialized = false;

#if SOC_TEMP_SENSOR_SUPPORTED
static temperature_sensor_handle_t s_temp_sensor = NULL;
#endif

static adc_oneshot_unit_handle_t s_adc1          = NULL;
static bool                      s_adc_ready     = false;

static TaskHandle_t  s_sensor_task_handle  = NULL;
static QueueHandle_t s_wall_sw_queue       = NULL;
static int64_t       s_wall_sw_last_us[DSGV_MAX_RELAY_COUNT];

// Set in DSGV_gpio_init() from g_device_config.capabilities.
// Prevents floating-pin ISR storms on devices without these sensors.
static bool s_has_motion  = false;
static bool s_has_contact = false;

// 50 ms software debounce — mechanical wall switches typically settle in < 20 ms
#define WALL_SW_DEBOUNCE_US  50000

#define RESET_WINDOW_US  ((int64_t)DSGV_RESET_WINDOW_MS * 1000)

static int     s_reset_count           = 0;
static int64_t s_reset_window_start_us = 0;

// ── External symbols ──────────────────────────────────────────────────────────

extern void DSGV_mqtt_publish_telemetry(const char *json_payload);

// ── LEDC helpers ──────────────────────────────────────────────────────────────

static void ledc_init_all(void) {
    if (s_ledc_initialized) return;

    ledc_timer_config_t timer = {
        .speed_mode      = LEDC_LOW_SPEED_MODE,
        .timer_num       = LEDC_TIMER_0,
        .duty_resolution = LEDC_DUTY_RESOLUTION,
        .freq_hz         = LEDC_TIMER_FREQ_HZ,
        .clk_cfg         = LEDC_AUTO_CLK,
    };
    ESP_ERROR_CHECK(ledc_timer_config(&timer));

    const struct { ledc_channel_t ch; gpio_num_t pin; } map[] = {
        { LEDC_CH_DIMMER, g_device_config.dimmer_pin },
        { LEDC_CH_WARM,   g_device_config.warm_pin   },
        { LEDC_CH_COOL,   g_device_config.cool_pin   },
        { LEDC_CH_RED,    g_device_config.red_pin    },
        { LEDC_CH_GREEN,  g_device_config.green_pin  },
        { LEDC_CH_BLUE,   g_device_config.blue_pin   },
    };

    ledc_channel_config_t ch_cfg = {
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .timer_sel  = LEDC_TIMER_0,
        .duty       = 0,
        .hpoint     = 0,
        .intr_type  = LEDC_INTR_DISABLE,
    };
    for (int i = 0; i < (int)(sizeof(map) / sizeof(map[0])); i++) {
        ch_cfg.channel  = map[i].ch;
        ch_cfg.gpio_num = map[i].pin;
        ESP_ERROR_CHECK(ledc_channel_config(&ch_cfg));
    }

    s_ledc_initialized = true;
    ESP_LOGI(TAG, "LEDC ready: 6 channels (dimmer/warm/cool/R/G/B) @ %d Hz 10-bit",
             LEDC_TIMER_FREQ_HZ);
}

// Set LEDC duty from a 0-100 % integer.
static void ledc_set_pct(ledc_channel_t ch, int pct) {
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    uint32_t duty = (uint32_t)pct * 1023u / 100u;
    ledc_set_duty(LEDC_LOW_SPEED_MODE, ch, duty);
    ledc_update_duty(LEDC_LOW_SPEED_MODE, ch);
}

// Set LEDC duty from a 0-255 byte (for RGB channels).
static void ledc_set_byte(ledc_channel_t ch, uint8_t val) {
    uint32_t duty = (uint32_t)val * 1023u / 255u;
    ledc_set_duty(LEDC_LOW_SPEED_MODE, ch, duty);
    ledc_update_duty(LEDC_LOW_SPEED_MODE, ch);
}

// ── ADC NTC thermistor ────────────────────────────────────────────────────────

// Simplified Steinhart-Hart (B-equation): T = 1 / (1/T0 + ln(R/R0)/B)
// Assumes: NTC 10 k @ 25 °C, B = 3950, series resistor 10 k, 12-bit ADC.
#define NTC_B    3950.0f
#define NTC_T0   298.15f    // 25 °C in Kelvin
#define NTC_R0   10000.0f
#define NTC_RS   10000.0f
#define ADC_FS   4095.0f

static float ntc_raw_to_celsius(int raw) {
    if (raw <= 0 || raw >= (int)ADC_FS) return -99.0f;
    // NTC on low side of divider: Vntc = Vcc * raw/ADC_FS
    float ratio  = (float)raw / ADC_FS;
    float r_ntc  = NTC_RS * ratio / (1.0f - ratio);
    float t_inv  = (1.0f / NTC_T0) + logf(r_ntc / NTC_R0) / NTC_B;
    return (1.0f / t_inv) - 273.15f;
}

static void adc_init(void) {
    adc_oneshot_unit_init_cfg_t cfg = {
        .unit_id  = ADC_UNIT_1,
        .ulp_mode = ADC_ULP_MODE_DISABLE,
    };
    if (adc_oneshot_new_unit(&cfg, &s_adc1) != ESP_OK) {
        ESP_LOGW(TAG, "ADC unit init failed — NTC fallback unavailable");
        return;
    }
    adc_oneshot_chan_cfg_t ch = {
        .atten    = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    if (adc_oneshot_config_channel(s_adc1, GPIO_ADC_TEMP_CHANNEL, &ch) != ESP_OK) {
        ESP_LOGW(TAG, "ADC channel config failed");
        return;
    }
    s_adc_ready = true;
    ESP_LOGI(TAG, "ADC1 ch%d ready for NTC thermistor", GPIO_ADC_TEMP_CHANNEL);
}

// ── Temperature reading ───────────────────────────────────────────────────────

static float read_temperature(void) {
#if SOC_TEMP_SENSOR_SUPPORTED
    if (s_temp_sensor) {
        float c = 0.0f;
        if (temperature_sensor_get_celsius(s_temp_sensor, &c) == ESP_OK) {
            return c;
        }
    }
#endif
    if (s_adc_ready && s_adc1) {
        int raw = 0;
        if (adc_oneshot_read(s_adc1, GPIO_ADC_TEMP_CHANNEL, &raw) == ESP_OK) {
            return ntc_raw_to_celsius(raw);
        }
    }
    return -99.0f;
}

// ── Telemetry JSON builder ────────────────────────────────────────────────────

static void build_telemetry(char *buf, size_t len) {
    STATE_LOCK();
    DSGV_device_state_t s = g_device_state;
    STATE_UNLOCK();

    snprintf(buf, len,
        "{\"power\":%s,\"power_2\":%s,\"power_3\":%s,\"power_4\":%s,"
        "\"brightness\":%d,\"color_temp\":%d,"
        "\"red\":%u,\"green\":%u,\"blue\":%u,"
        "\"current_temp\":%.1f,\"humidity\":%.1f,"
        "\"motion\":%s,\"contact\":%s,"
        "\"target_temp\":%.1f,\"mode\":\"%s\"}",
        s.relay_states[0] ? "true"  : "false",
        s.relay_states[1] ? "true"  : "false",
        s.relay_states[2] ? "true"  : "false",
        s.relay_states[3] ? "true"  : "false",
        s.brightness,
        s.color_temp_k,
        (unsigned)s.rgb_r, (unsigned)s.rgb_g, (unsigned)s.rgb_b,
        s.current_temp,
        s.humidity,
        s.motion_detected ? "true"  : "false",
        s.contact_closed  ? "true"  : "false",
        s.target_temp,
        s.hvac_mode
    );
}

// ── ISR handlers (IRAM — no heap alloc, no ESP_LOG*) ─────────────────────────

static void IRAM_ATTR motion_isr_handler(void *arg) {
    BaseType_t higher = pdFALSE;
    vTaskNotifyGiveFromISR(s_sensor_task_handle, &higher);
    portYIELD_FROM_ISR(higher);
}

static void IRAM_ATTR contact_isr_handler(void *arg) {
    BaseType_t higher = pdFALSE;
    vTaskNotifyGiveFromISR(s_sensor_task_handle, &higher);
    portYIELD_FROM_ISR(higher);
}

static void IRAM_ATTR wall_sw_isr(void *arg) {
    uint32_t gang = (uint32_t)(uintptr_t)arg;
    BaseType_t higher = pdFALSE;
    xQueueSendFromISR(s_wall_sw_queue, &gang, &higher);
    portYIELD_FROM_ISR(higher);
}

// ── Wall switch toggle task ───────────────────────────────────────────────────

static void wall_switch_task(void *pvParam) {
    (void)pvParam;
    uint32_t gang;
    for (;;) {
        if (xQueueReceive(s_wall_sw_queue, &gang, portMAX_DELAY) != pdTRUE) continue;
        if (gang >= (uint32_t)g_device_config.relay_count) continue;

        // Software debounce: ignore edges within 50 ms of the last accepted one
        int64_t now = esp_timer_get_time();
        if (now - s_wall_sw_last_us[gang] < WALL_SW_DEBOUNCE_US) continue;
        s_wall_sw_last_us[gang] = now;

        // Factory reset: toggle gang 0 DSGV_RESET_TOGGLE_COUNT times within
        // DSGV_RESET_WINDOW_MS ms → erase Wi-Fi creds and reboot into provisioning.
        if (gang == 0) {
            if (s_reset_count == 0 || (now - s_reset_window_start_us) > RESET_WINDOW_US) {
                s_reset_count           = 1;
                s_reset_window_start_us = now;
            } else {
                s_reset_count++;
                if (s_reset_count >= DSGV_RESET_TOGGLE_COUNT) {
                    ESP_LOGW(TAG, "Factory reset triggered (%d toggles in %d ms)",
                             DSGV_RESET_TOGGLE_COUNT, DSGV_RESET_WINDOW_MS);
                    wifi_manager_factory_reset(); // erases NVS and calls esp_restart()
                }
            }
        }

        bool new_state;
        STATE_LOCK();
        new_state = !g_device_state.relay_states[gang];
        g_device_state.relay_states[gang] = new_state;
        STATE_UNLOCK();

        DSGV_gpio_apply_state();

        char buf[512];
        build_telemetry(buf, sizeof(buf));
        DSGV_mqtt_publish_telemetry(buf);

        ESP_LOGI(TAG, "Wall switch gang %" PRIu32 " → %s", gang, new_state ? "ON" : "OFF");
    }
}

// ── Sensor + periodic telemetry task ─────────────────────────────────────────

static void sensor_task(void *pvParam) {
    (void)pvParam;
    char    last_telemetry[512] = "";
    int64_t last_pub_us         = 0;

    for (;;) {
        // Block until an ISR wakes us or the heartbeat interval expires.
        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(DSGV_TELEMETRY_INTERVAL_MS));

        int64_t now        = esp_timer_get_time();
        int64_t elapsed_us = now - last_pub_us;

        // Rate cap: never publish faster than DSGV_TELEMETRY_MIN_INTERVAL_MS.
        // When an ISR storm occurs (e.g. noisy sensor), sleep the remainder of
        // the window and consume any stacked notifications before continuing.
        if (last_pub_us != 0 &&
            elapsed_us < (int64_t)DSGV_TELEMETRY_MIN_INTERVAL_MS * 1000) {
            TickType_t wait = pdMS_TO_TICKS(
                DSGV_TELEMETRY_MIN_INTERVAL_MS - (uint32_t)(elapsed_us / 1000));
            ulTaskNotifyTake(pdTRUE, wait);
            now = esp_timer_get_time();
            elapsed_us = now - last_pub_us;
        }

        float temp    = read_temperature();
        bool  motion  = s_has_motion  ? (gpio_get_level(GPIO_MOTION_PIN)  == 1) : false;
        bool  contact = s_has_contact ? (gpio_get_level(GPIO_CONTACT_PIN) == 0) : false;

        STATE_LOCK();
        if (temp > -99.0f) g_device_state.current_temp = temp;
        g_device_state.motion_detected = motion;
        g_device_state.contact_closed  = contact;
        STATE_UNLOCK();

        char buf[512];
        build_telemetry(buf, sizeof(buf));

        // Change-detect: publish only when values differ from last snapshot,
        // or when the full heartbeat interval has elapsed (keepalive / app sync).
        bool heartbeat = elapsed_us >= (int64_t)DSGV_TELEMETRY_INTERVAL_MS * 1000;
        if (heartbeat || strcmp(buf, last_telemetry) != 0) {
            DSGV_mqtt_publish_telemetry(buf);
            strlcpy(last_telemetry, buf, sizeof(last_telemetry));
            last_pub_us = now;
        }
    }
}

// ── Public API ────────────────────────────────────────────────────────────────

void DSGV_gpio_init(void) {
    // ── Relay outputs (all gangs) ─────────────────────────────────────────
    gpio_config_t out = {
        .mode         = GPIO_MODE_OUTPUT,
        .pull_up_en   = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    for (int i = 0; i < (int)g_device_config.relay_count; i++) {
        out.pin_bit_mask = (1ULL << g_device_config.relay_pins[i]);
        gpio_config(&out);
        gpio_set_level(g_device_config.relay_pins[i], 0);
    }

    // ── Status LED output ─────────────────────────────────────────────────
    out.pin_bit_mask = (1ULL << GPIO_STATUS_LED_PIN);
    gpio_config(&out);
    gpio_set_level(GPIO_STATUS_LED_PIN, 0);

    // ── LEDC PWM channels ─────────────────────────────────────────────────
    ledc_init_all();

    // ── ISR service (must precede gpio_isr_handler_add) ──────────────────
    (void)gpio_install_isr_service(0);  // no-op if already installed

    // ── Wall switch inputs (one per relay gang, falling-edge toggle) ──────
    // Wire: switch between the GPIO pin and GND; internal pull-up pulls idle HIGH.
    // Works with latching rockers (each direction-change is a falling edge) and
    // momentary push buttons (press = falling edge, release ignored).
    memset(s_wall_sw_last_us, 0, sizeof(s_wall_sw_last_us));
    s_wall_sw_queue = xQueueCreate(8, sizeof(uint32_t));
    if (g_device_config.relay_count > 0) {
        gpio_config_t sw_in = {
            .mode         = GPIO_MODE_INPUT,
            .pull_up_en   = GPIO_PULLUP_ENABLE,
            .pull_down_en = GPIO_PULLDOWN_DISABLE,
            .intr_type    = GPIO_INTR_NEGEDGE,
        };
        for (int i = 0; i < (int)g_device_config.relay_count; i++) {
            sw_in.pin_bit_mask = (1ULL << g_device_config.wall_switch_pins[i]);
            gpio_config(&sw_in);
        }
        xTaskCreate(wall_switch_task, "DSGV_wall_sw", 3072, NULL, 3, NULL);
        for (int i = 0; i < (int)g_device_config.relay_count; i++) {
            gpio_isr_handler_add(g_device_config.wall_switch_pins[i],
                                 wall_sw_isr, (void *)(uintptr_t)i);
        }
        ESP_LOGI(TAG, "Wall switches: %u input(s) → pins [%d,%d,%d,%d]",
                 g_device_config.relay_count,
                 g_device_config.wall_switch_pins[0], g_device_config.wall_switch_pins[1],
                 g_device_config.wall_switch_pins[2], g_device_config.wall_switch_pins[3]);
    }

    // ── Motion sensor input (PIR, HIGH-active) ────────────────────────────
    // Only configured when the device SKU declares the "motion" capability.
    // On switch/dimmer/etc. the pin is unconnected; registering an ANYEDGE
    // ISR on a floating pin causes a publish storm (~100 msg/s on ESP32).
    s_has_motion = strstr(g_device_config.capabilities, "\"motion\"") != NULL;
    if (s_has_motion) {
        gpio_config_t motion_in = {
            .pin_bit_mask = (1ULL << GPIO_MOTION_PIN),
            .mode         = GPIO_MODE_INPUT,
            .pull_up_en   = GPIO_PULLUP_DISABLE,
            .pull_down_en = GPIO_PULLDOWN_DISABLE,  // use external pull-down
            .intr_type    = GPIO_INTR_ANYEDGE,
        };
        gpio_config(&motion_in);
    }

    // ── Contact sensor input (reed switch, LOW-active = closed) ──────────
    s_has_contact = strstr(g_device_config.capabilities, "\"contact\"") != NULL;
    if (s_has_contact) {
        gpio_config_t contact_in = {
            .pin_bit_mask = (1ULL << GPIO_CONTACT_PIN),
            .mode         = GPIO_MODE_INPUT,
            .pull_up_en   = GPIO_PULLUP_DISABLE,   // use external pull-up
            .pull_down_en = GPIO_PULLDOWN_DISABLE,
            .intr_type    = GPIO_INTR_ANYEDGE,
        };
        gpio_config(&contact_in);
    }

    // ── ADC NTC (temperature fallback) ───────────────────────────────────
    adc_init();

    // ── Internal SOC temperature sensor ──────────────────────────────────
#if SOC_TEMP_SENSOR_SUPPORTED
    temperature_sensor_config_t ts_cfg = TEMPERATURE_SENSOR_CONFIG_DEFAULT(-10, 80);
    if (temperature_sensor_install(&ts_cfg, &s_temp_sensor) == ESP_OK &&
        temperature_sensor_enable(s_temp_sensor) == ESP_OK) {
        ESP_LOGI(TAG, "SOC internal temperature sensor enabled");
    } else {
        ESP_LOGW(TAG, "SOC temp sensor init failed; using NTC ADC fallback");
        s_temp_sensor = NULL;
    }
#endif

    // ── Sensor / telemetry background task ───────────────────────────────
    // Task created BEFORE attaching ISR handlers so s_sensor_task_handle
    // is always valid when the first interrupt fires.
    xTaskCreate(sensor_task, "DSGV_sensors", 4096, NULL, 2, &s_sensor_task_handle);

    // Attach ISR handlers only for capabilities this device actually has.
    if (s_has_motion)  gpio_isr_handler_add(GPIO_MOTION_PIN,  motion_isr_handler,  NULL);
    if (s_has_contact) gpio_isr_handler_add(GPIO_CONTACT_PIN, contact_isr_handler, NULL);

    ESP_LOGI(TAG, "GPIO ready (relay[0]=%d cnt=%u LED=%d dim=%d warm=%d cool=%d "
             "R=%d G=%d B=%d motion=%d contact=%d)",
             g_device_config.relay_pins[0], g_device_config.relay_count,
             GPIO_STATUS_LED_PIN,
             g_device_config.dimmer_pin, g_device_config.warm_pin,
             g_device_config.cool_pin,
             g_device_config.red_pin, g_device_config.green_pin,
             g_device_config.blue_pin,
             GPIO_MOTION_PIN, GPIO_CONTACT_PIN);
}

void DSGV_gpio_relay_set(bool on) {
    gpio_set_level(g_device_config.relay_pins[0], on ? 1 : 0);
    gpio_set_level(GPIO_STATUS_LED_PIN, on ? 1 : 0);

    STATE_LOCK();
    g_device_state.relay_states[0] = on;
    STATE_UNLOCK();

    ESP_LOGI(TAG, "Relay → %s", on ? "ON" : "OFF");

    char buf[512];
    build_telemetry(buf, sizeof(buf));
    DSGV_mqtt_publish_telemetry(buf);
}

bool DSGV_gpio_relay_get(void) {
    STATE_LOCK();
    bool state = g_device_state.relay_states[0];
    STATE_UNLOCK();
    return state;
}

void DSGV_gpio_dimmer_set(int pct) {
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    ledc_set_pct(LEDC_CH_DIMMER, pct);
    ESP_LOGI(TAG, "Dimmer → %d%%", pct);
}

void DSGV_gpio_ct_set(int kelvin) {
    if (kelvin < 2000) kelvin = 2000;
    if (kelvin > 6500) kelvin = 6500;
    // Linear blend: 2000 K = 100% warm / 0% cool, 6500 K = 0% warm / 100% cool
    int warm_pct = (6500 - kelvin) * 100 / (6500 - 2000);
    int cool_pct = 100 - warm_pct;
    ledc_set_pct(LEDC_CH_WARM, warm_pct);
    ledc_set_pct(LEDC_CH_COOL, cool_pct);
    ESP_LOGI(TAG, "CCT → %d K (warm=%d%% cool=%d%%)", kelvin, warm_pct, cool_pct);
}

void DSGV_gpio_rgb_set(uint8_t r, uint8_t g, uint8_t b) {
    ledc_set_byte(LEDC_CH_RED,   r);
    ledc_set_byte(LEDC_CH_GREEN, g);
    ledc_set_byte(LEDC_CH_BLUE,  b);
    ESP_LOGI(TAG, "RGB → (%u, %u, %u)", (unsigned)r, (unsigned)g, (unsigned)b);
}

void DSGV_gpio_apply_state(void) {
    STATE_LOCK();
    DSGV_device_state_t s = g_device_state;
    STATE_UNLOCK();

    // All relay outputs — each gang driven independently
    for (int i = 0; i < (int)g_device_config.relay_count; i++) {
        gpio_set_level(g_device_config.relay_pins[i], s.relay_states[i] ? 1 : 0);
    }
    // Status LED mirrors gang 1 (primary relay)
    if (g_device_config.relay_count > 0) {
        gpio_set_level(GPIO_STATUS_LED_PIN, s.relay_states[0] ? 1 : 0);
    }

    // Guard every PWM output behind the device's capability string.
    // A 1-gang switch has capabilities=["relay"] — none of the blocks below
    // fire for it, so no spurious CCT/RGB log noise and no wasted PWM cycles.
    const char *caps = g_device_config.capabilities;

    if (strstr(caps, "\"brightness\"")) {
        ledc_set_pct(LEDC_CH_DIMMER, s.relay_states[0] ? s.brightness : 0);
    }

    if (strstr(caps, "\"color_temp\"")) {
        if (s.relay_states[0] && s.color_temp_k > 0) {
            DSGV_gpio_ct_set(s.color_temp_k);
        } else {
            ledc_set_pct(LEDC_CH_WARM, 0);
            ledc_set_pct(LEDC_CH_COOL, 0);
        }
    }

    if (strstr(caps, "\"rgb\"")) {
        if (s.relay_states[0]) {
            DSGV_gpio_rgb_set(s.rgb_r, s.rgb_g, s.rgb_b);
        } else {
            DSGV_gpio_rgb_set(0, 0, 0);
        }
    }
}
