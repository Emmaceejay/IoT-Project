/**
 * DSGV serial config framing — browser/Node port of
 * dsgv_firmware/tools/dsgv_serial_config.py.
 *
 * Must stay byte-identical to that script and to
 * components/dsgv_common/serial/dsgv_serial_config.c. The three are checked
 * against each other by webflasher/test/frame.test.mjs.
 *
 *   'D' 'S' 'G' 'V'  ver  type  len_hi  len_lo  payload…  checksum  '\n'
 *
 * The decoder is a resynchronising scanner rather than a straight parser
 * because this port is also the ESP-IDF log console: frames arrive embedded in
 * arbitrary boot output, and a byte sequence inside a log line can look like
 * the start of a frame. Validating the checksum before accepting is what makes
 * that safe.
 */

export const MAGIC = Object.freeze([0x44, 0x53, 0x47, 0x56]); // "DSGV"
export const VERSION = 1;
export const HEADER_LEN = 8;
export const MAX_PAYLOAD = 1024;

export const MsgType = Object.freeze({
  REQUEST_INFO: 0x01,
  SET_CONFIG:   0x02,
  GET_CONFIG:   0x03,
  RESTART:      0x04,
  RESPONSE_OK:  0x81,
  RESPONSE_ERR: 0x82,
});

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** Build a frame. `payload` may be a string, Uint8Array, or omitted. */
export function encodeFrame(type, payload = new Uint8Array()) {
  const body = typeof payload === 'string' ? encoder.encode(payload) : payload;
  if (body.length > MAX_PAYLOAD) {
    throw new RangeError(`payload ${body.length} exceeds ${MAX_PAYLOAD}`);
  }

  const frame = new Uint8Array(HEADER_LEN + body.length + 2);
  frame.set(MAGIC, 0);
  frame[4] = VERSION;
  frame[5] = type;
  frame[6] = (body.length >> 8) & 0xff;
  frame[7] = body.length & 0xff;
  frame.set(body, HEADER_LEN);

  let sum = 0;
  for (let i = 0; i < HEADER_LEN + body.length; i++) sum += frame[i];
  frame[HEADER_LEN + body.length] = sum & 0xff;
  frame[HEADER_LEN + body.length + 1] = 0x0a;

  return frame;
}

/**
 * Incremental decoder. Feed it whatever arrives from the port; it returns the
 * complete, checksum-valid frames found so far and keeps the remainder.
 */
export class FrameDecoder {
  #buf = [];

  /** @returns {{type:number, payload:Uint8Array, text:string}[]} */
  push(chunk) {
    for (const b of chunk) this.#buf.push(b);
    const out = [];

    for (;;) {
      const start = this.#findMagic();
      if (start < 0) {
        // Keep only a possible partial magic at the tail.
        if (this.#buf.length > MAGIC.length) {
          this.#buf = this.#buf.slice(-(MAGIC.length - 1));
        }
        break;
      }
      if (start > 0) this.#buf = this.#buf.slice(start);
      if (this.#buf.length < HEADER_LEN) break;

      const len = (this.#buf[6] << 8) | this.#buf[7];
      if (len > MAX_PAYLOAD || this.#buf[4] !== VERSION) {
        // Not a real frame — a log line that happened to contain "DSGV".
        this.#buf = this.#buf.slice(1);
        continue;
      }

      const total = HEADER_LEN + len + 2;
      if (this.#buf.length < total) break;         // wait for more bytes

      let sum = 0;
      for (let i = 0; i < total - 2; i++) sum += this.#buf[i];

      if ((sum & 0xff) !== this.#buf[total - 2] || this.#buf[total - 1] !== 0x0a) {
        this.#buf = this.#buf.slice(1);            // false positive; resync
        continue;
      }

      const payload = new Uint8Array(this.#buf.slice(HEADER_LEN, HEADER_LEN + len));
      out.push({
        type: this.#buf[5],
        payload,
        get text() { return decoder.decode(payload); },
      });
      this.#buf = this.#buf.slice(total);
    }

    return out;
  }

  reset() { this.#buf = []; }

  #findMagic() {
    outer:
    for (let i = 0; i + MAGIC.length <= this.#buf.length; i++) {
      for (let j = 0; j < MAGIC.length; j++) {
        if (this.#buf[i + j] !== MAGIC[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}
