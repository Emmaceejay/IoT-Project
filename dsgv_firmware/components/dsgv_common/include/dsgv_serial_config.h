#pragma once

#include "esp_err.h"

/**
 * dsgv_serial_config.h — configuration over the UART0 console.
 *
 * This is the channel the web flasher uses immediately after writing the
 * firmware, while it still holds the serial port open and before the device
 * has any network. It carries the full device config (identity, capabilities
 * and the pin map), not just Wi-Fi credentials.
 *
 * ── Framing ──────────────────────────────────────────────────────────────
 *
 *   'D' 'S' 'G' 'V'  ver  type  len_hi  len_lo  payload…  checksum  '\n'
 *
 *   ver       protocol version, currently 1
 *   type      see DSGV_SERIAL_* below
 *   len       payload length, big-endian, 0..DSGV_SERIAL_MAX_PAYLOAD
 *   checksum  sum of every preceding byte in the frame, & 0xFF
 *
 * The magic-plus-checksum envelope is deliberate rather than raw JSON: this
 * port is also the ESP-IDF log console, so frames arrive interleaved with
 * arbitrary log output. A parser scanning for a 4-byte magic and validating a
 * checksum resynchronises cleanly after noise; newline-delimited JSON does
 * not. Same reasoning as Improv Serial, whose framing this mirrors.
 *
 * ── Message types ────────────────────────────────────────────────────────
 *
 *   Host → device
 *     0x01 REQUEST_INFO   empty payload
 *     0x02 SET_CONFIG     JSON, in the schema of dsgv_config_json.h
 *     0x03 GET_CONFIG     empty payload
 *     0x04 RESTART        empty payload
 *
 *   Device → host
 *     0x81 RESPONSE_OK    JSON payload (info or config), or empty
 *     0x82 RESPONSE_ERR   UTF-8 reason string
 *
 * ── On access control ────────────────────────────────────────────────────
 *
 * SET_CONFIG is not authenticated. That is a deliberate call, not an
 * oversight: anyone who can reach UART0 can already hold the device in
 * download mode and rewrite the whole flash, so requiring a token here would
 * add friction without adding security. It does mean the port should be
 * treated as a manufacturing and setup interface. Once secure boot and flash
 * encryption are enabled for production units, this becomes the weaker of the
 * two paths and should be reconsidered.
 */

#define DSGV_SERIAL_PROTO_VERSION   1
#define DSGV_SERIAL_MAX_PAYLOAD     1024

#define DSGV_SERIAL_REQUEST_INFO    0x01
#define DSGV_SERIAL_SET_CONFIG      0x02
#define DSGV_SERIAL_GET_CONFIG      0x03
#define DSGV_SERIAL_RESTART         0x04
#define DSGV_SERIAL_RESPONSE_OK     0x81
#define DSGV_SERIAL_RESPONSE_ERR    0x82

/**
 * @brief Start the serial config listener on UART0.
 *
 * Safe to call before Wi-Fi is up; it has no network dependency, which is the
 * point — a freshly flashed device can be fully configured with no radio.
 */
esp_err_t DSGV_serial_config_start(void);
