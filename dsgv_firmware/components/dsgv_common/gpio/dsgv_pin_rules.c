#include "dsgv_pin_rules.h"

/**
 * Per-chip pin tables as 64-bit masks (bit N = GPIO N).
 *
 * Sources: the GPIO / pin-layout chapters of each chip's technical reference
 * manual and datasheet.
 *
 *   NOT_EXIST  — numbers inside the enum range that are not bonded out.
 *   RESERVED   — SPI flash and (where applicable) octal PSRAM. Reconfiguring
 *                these hangs the chip the next time it fetches from flash,
 *                which on an OTA-capable device means a brick.
 *   INPUT_ONLY — no output driver in silicon; gpio_config() accepts an output
 *                config and the pin simply never drives, which is the worst
 *                kind of failure because nothing reports an error.
 *   STRAPPING  — sampled at reset; driving them can prevent boot.
 *   CONSOLE    — UART0. Phase 2 uses this for serial provisioning, so taking
 *                it for a relay would disable the flasher's config channel.
 *   USB        — native USB D-/D+. Using them disables USB-Serial-JTAG.
 */

#if defined(CONFIG_IDF_TARGET_ESP32C3)
#  define PIN_LIMIT      22
#  define M_NOT_EXIST    0ULL
#  define M_RESERVED     (0x3FULL << 12)                 // 12-17 SPI flash
#  define M_INPUT_ONLY   0ULL
#  define M_STRAPPING    ((1ULL << 2) | (1ULL << 8) | (1ULL << 9))
#  define M_CONSOLE      ((1ULL << 20) | (1ULL << 21))   // U0RXD / U0TXD
#  define M_USB          ((1ULL << 18) | (1ULL << 19))

#elif defined(CONFIG_IDF_TARGET_ESP32C6)
#  define PIN_LIMIT      31
#  define M_NOT_EXIST    0ULL
#  define M_RESERVED     (0x7FULL << 24)                 // 24-30 SPI flash
#  define M_INPUT_ONLY   0ULL
#  define M_STRAPPING    ((1ULL << 4) | (1ULL << 5) | (1ULL << 8) | \
                          (1ULL << 9) | (1ULL << 15))
#  define M_CONSOLE      ((1ULL << 16) | (1ULL << 17))   // U0TXD / U0RXD
#  define M_USB          ((1ULL << 12) | (1ULL << 13))

#elif defined(CONFIG_IDF_TARGET_ESP32S3)
#  define PIN_LIMIT      49
#  define M_NOT_EXIST    (0xFULL << 22)                  // 22-25 absent on the die
#  define M_RESERVED     ((0x7FULL << 26) | (0x1FULL << 33))  // flash 26-32, octal PSRAM 33-37
#  define M_INPUT_ONLY   0ULL
#  define M_STRAPPING    ((1ULL << 0) | (1ULL << 3) | (1ULL << 45) | (1ULL << 46))
#  define M_CONSOLE      ((1ULL << 43) | (1ULL << 44))   // U0TXD / U0RXD
#  define M_USB          ((1ULL << 19) | (1ULL << 20))

#elif defined(CONFIG_IDF_TARGET_ESP32)
#  define PIN_LIMIT      40
   // 20, 24 and 28-31 are not bonded out on the common packages.
#  define M_NOT_EXIST    ((1ULL << 20) | (1ULL << 24) | (0xFULL << 28))
#  define M_RESERVED     (0x3FULL << 6)                  // 6-11 SPI flash
#  define M_INPUT_ONLY   (0x3FULL << 34)                 // 34-39 input-only
#  define M_STRAPPING    ((1ULL << 0) | (1ULL << 2) | (1ULL << 5) | \
                          (1ULL << 12) | (1ULL << 15))
#  define M_CONSOLE      ((1ULL << 1) | (1ULL << 3))     // U0TXD / U0RXD
#  define M_USB          0ULL                            // no native USB

#else
#  error "DSGV: no pin rule table for this IDF target. Add one above — \
falling back to permissive defaults would let the flasher hand a user the \
SPI flash pins."
#endif

static inline bool in_mask(int pin, unsigned long long mask) {
    if (pin < 0 || pin >= 64) return false;
    return (mask >> pin) & 1ULL;
}

int DSGV_pin_count(void) {
    return PIN_LIMIT;
}

DSGV_pin_status_t DSGV_pin_check(int pin, bool need_output) {
    // -1 is the documented "feature not fitted" value and is always accepted.
    if (pin == GPIO_NUM_NC) return DSGV_PIN_DISABLED;

    if (pin < 0 || pin >= PIN_LIMIT)   return DSGV_PIN_NOT_EXIST;
    if (in_mask(pin, M_NOT_EXIST))     return DSGV_PIN_NOT_EXIST;
    if (in_mask(pin, M_RESERVED))      return DSGV_PIN_RESERVED;
    if (need_output && in_mask(pin, M_INPUT_ONLY)) return DSGV_PIN_INPUT_ONLY;

    return DSGV_PIN_OK;
}

const char *DSGV_pin_status_str(DSGV_pin_status_t s) {
    switch (s) {
        case DSGV_PIN_OK:         return "ok";
        case DSGV_PIN_DISABLED:   return "disabled (GPIO_NUM_NC)";
        case DSGV_PIN_NOT_EXIST:  return "no such pin on this chip";
        case DSGV_PIN_RESERVED:   return "reserved for SPI flash/PSRAM";
        case DSGV_PIN_INPUT_ONLY: return "input-only, cannot drive an output";
        default:                  return "unknown";
    }
}

bool DSGV_pin_is_strapping(int pin) { return in_mask(pin, M_STRAPPING); }
bool DSGV_pin_is_console(int pin)   { return in_mask(pin, M_CONSOLE);   }
bool DSGV_pin_is_usb(int pin)       { return in_mask(pin, M_USB);       }

// ── ADC1 GPIO → channel ───────────────────────────────────────────────────────
// Fixed in silicon; the ordering is not the same on any two of these chips.

int DSGV_pin_to_adc1_channel(int pin) {
#if defined(CONFIG_IDF_TARGET_ESP32)
    // ADC1_CH0..CH7 = GPIO 36, 37, 38, 39, 32, 33, 34, 35
    switch (pin) {
        case 36: return 0;  case 37: return 1;
        case 38: return 2;  case 39: return 3;
        case 32: return 4;  case 33: return 5;
        case 34: return 6;  case 35: return 7;
        default: return -1;
    }
#elif defined(CONFIG_IDF_TARGET_ESP32S3)
    // ADC1_CH0..CH9 = GPIO 1..10
    if (pin >= 1 && pin <= 10) return pin - 1;
    return -1;
#elif defined(CONFIG_IDF_TARGET_ESP32C3)
    // ADC1_CH0..CH4 = GPIO 0..4
    if (pin >= 0 && pin <= 4) return pin;
    return -1;
#elif defined(CONFIG_IDF_TARGET_ESP32C6)
    // ADC1_CH0..CH6 = GPIO 0..6
    if (pin >= 0 && pin <= 6) return pin;
    return -1;
#else
    (void)pin;
    return -1;
#endif
}
