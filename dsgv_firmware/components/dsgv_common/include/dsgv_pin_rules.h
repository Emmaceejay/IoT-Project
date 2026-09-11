#pragma once

#include "sdkconfig.h"
#include "driver/gpio.h"
#include <stdbool.h>

/**
 * dsgv_pin_rules.h — per-chip GPIO capability rules.
 *
 * Single source of truth for "may this pin be used for this purpose on this
 * chip". Used by:
 *   - DSGV_device_config_load()  to reject unusable pins from NVS
 *   - DSGV_gpio_init()           to skip rather than abort on a bad pin
 *   - the provisioning parsers   to reject a bad pin before it is persisted
 *
 * Rationale: the web flasher lets a user type arbitrary pin numbers and they
 * never see a build log, so every pin has to be validated against the actual
 * silicon before it is written to NVS or handed to gpio_config(). A flat
 * "0 <= pin < GPIO_NUM_MAX" range check is not sufficient — it happily
 * accepts the SPI flash pins, which hang the chip on the next flash access.
 */

typedef enum {
    DSGV_PIN_OK = 0,
    DSGV_PIN_DISABLED,      // GPIO_NUM_NC (-1) — deliberately unused, not an error
    DSGV_PIN_NOT_EXIST,     // outside range, or a gap in this package's numbering
    DSGV_PIN_RESERVED,      // SPI flash / PSRAM — configuring it hangs the chip
    DSGV_PIN_INPUT_ONLY,    // has no output driver; gpio_set_level() silently no-ops
} DSGV_pin_status_t;

/**
 * @brief Validate a pin for a given direction.
 * @param pin          GPIO number, or GPIO_NUM_NC (-1) to mean "feature disabled".
 * @param need_output  true for relays, PWM and the status LED; false for inputs.
 */
DSGV_pin_status_t DSGV_pin_check(int pin, bool need_output);

/** @brief Human-readable form of a status code, for logging. */
const char *DSGV_pin_status_str(DSGV_pin_status_t s);

/**
 * @brief True if the pin is usable but carries a caveat the user should know
 *        about (boot strapping, UART0 console, or native USB). These do not
 *        fail validation — plenty of real designs use them deliberately — but
 *        they are worth surfacing in logs and in the flasher UI.
 */
bool DSGV_pin_is_strapping(int pin);
bool DSGV_pin_is_console(int pin);   // UART0 — also the serial config channel
bool DSGV_pin_is_usb(int pin);

/** @brief Highest valid pin number + 1 for this chip. */
int DSGV_pin_count(void);

/**
 * @brief Map a GPIO to its ADC1 channel.
 * @return the ADC1 channel number, or -1 if this pin has no ADC1 function.
 *
 * The oneshot ADC driver addresses channels, not GPIOs, so a user-selected
 * analog pin has to be translated. The mapping is fixed in silicon and
 * differs per chip — e.g. ADC1_CH0 is GPIO 36 on ESP32 but GPIO 1 on S3 and
 * GPIO 0 on C3/C6 — which is exactly why it belongs here beside the other
 * per-chip tables rather than being hardcoded at the call site.
 */
int DSGV_pin_to_adc1_channel(int pin);
