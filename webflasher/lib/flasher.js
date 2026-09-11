/**
 * Web Serial + esptool-js glue.
 *
 * This layer cannot be unit-tested — it needs a browser and a board — so it is
 * kept as thin as possible and holds no decision-making. Everything worth
 * getting right (framing, pin rules, payload shape) lives in dsgv-frame.js and
 * config-builder.js, which are tested.
 */

import { ESPLoader, Transport } from
  'https://cdn.jsdelivr.net/npm/esptool-js@0.6.1/+esm';
import { encodeFrame, FrameDecoder, MsgType } from './dsgv-frame.js';

/** Web Serial is Chromium desktop, Edge, and Firefox 151+. Never iOS. */
export function serialSupported() {
  return typeof navigator !== 'undefined' && 'serial' in navigator;
}

export function unsupportedReason() {
  const ua = navigator.userAgent;
  if (/iPhone|iPad|iPod/.test(ua)) {
    return 'iOS and iPadOS do not support Web Serial in any browser, including '
         + 'Chrome and Firefox on iOS. Flashing needs a desktop computer.';
  }
  if (/Android/.test(ua)) {
    return 'Android support for Web Serial over USB is limited and depends on '
         + 'your Chrome version. A desktop computer is more reliable.';
  }
  if (/Safari/.test(ua) && !/Chrome/.test(ua)) {
    return 'Safari does not support Web Serial. Use Chrome, Edge, or Firefox 151+.';
  }
  return 'This browser does not support Web Serial. Use Chrome, Edge, or Firefox 151+.';
}

/**
 * Holds one serial port across both phases — flashing, then configuration.
 * The port is opened once and reused: asking the user to re-pick it after the
 * reset would be a second permission prompt for the same board.
 */
export class DeviceSession {
  #port = null;
  #transport = null;
  #loader = null;
  #log;

  constructor(log = () => {}) { this.#log = log; }

  get chipName() { return this.#loader?.chip?.CHIP_NAME ?? null; }

  /** Prompt for a port and identify the chip. */
  async connect() {
    this.#port = await navigator.serial.requestPort();
    this.#transport = new Transport(this.#port, true);

    this.#loader = new ESPLoader({
      transport: this.#transport,
      baudrate: 115200,
      terminal: {
        clean: () => {},
        writeLine: (d) => this.#log(d),
        write: (d) => this.#log(d, { inline: true }),
      },
    });

    // main() resets the chip into download mode and identifies it.
    const chip = await this.#loader.main();
    this.#log(`detected ${chip}`);
    return chip;
  }

  /**
   * @param parts [{ data: Uint8Array, address: number }]
   * @param onProgress (fraction 0..1, partIndex)
   */
  async flash(parts, onProgress = () => {}) {
    if (!this.#loader) throw new Error('not connected');

    await this.#loader.writeFlash({
      fileArray: parts.map((p) => ({ data: p.data, address: p.address })),
      flashSize: 'keep',
      flashMode: 'keep',
      flashFreq: 'keep',
      eraseAll: false,
      compress: true,
      reportProgress: (fileIndex, written, total) => {
        onProgress(total ? written / total : 0, fileIndex);
      },
    });

    await this.#loader.after('hard_reset');
  }

  /**
   * Leave download mode and reopen the port for normal serial traffic.
   *
   * esptool-js drives the port at its own settings while flashing; the config
   * protocol needs a plain 115200 stream. Closing and reopening is the only
   * reliable way to hand the port between the two.
   */
  async beginSerialSession() {
    if (this.#transport) {
      try { await this.#transport.disconnect(); } catch { /* already closed */ }
    }
    this.#loader = null;
    this.#transport = null;

    try { await this.#port.close(); } catch { /* was not open */ }
    await this.#port.open({ baudRate: 115200 });
    this.#log('serial session open at 115200');
  }

  /**
   * Send one frame and wait for the device's reply.
   *
   * Retries because the first attempt usually lands while the device is still
   * booting: the listener starts after GPIO init, so a frame sent too early is
   * simply not read by anyone.
   */
  async request(type, payload = '', { timeoutMs = 4000, attempts = 6 } = {}) {
    const frame = encodeFrame(type, payload);

    for (let attempt = 1; attempt <= attempts; attempt++) {
      const writer = this.#port.writable.getWriter();
      try { await writer.write(frame); } finally { writer.releaseLock(); }

      const reply = await this.#readFrame(timeoutMs);
      if (reply) {
        if (reply.type === MsgType.RESPONSE_ERR) {
          throw new Error(`device rejected the request: ${reply.text}`);
        }
        return reply;
      }
      this.#log(`no reply (attempt ${attempt}/${attempts}) — device may still be booting`);
    }
    throw new Error(
      'the device did not answer. It may not be running DSGV firmware, or the '
      + 'serial console may be assigned to a GPIO in this configuration.');
  }

  async #readFrame(timeoutMs) {
    const decoder = new FrameDecoder();
    const reader = this.#port.readable.getReader();
    const deadline = Date.now() + timeoutMs;

    try {
      while (Date.now() < deadline) {
        const timeout = new Promise((r) => setTimeout(() => r(null),
          Math.max(0, deadline - Date.now())));
        const result = await Promise.race([reader.read(), timeout]);
        if (!result || result.done) break;

        for (const f of decoder.push(result.value)) return f;
      }
    } finally {
      try { await reader.cancel(); } catch { /* ignore */ }
      reader.releaseLock();
    }
    return null;
  }

  async close() {
    try { await this.#transport?.disconnect(); } catch { /* ignore */ }
    try { await this.#port?.close(); } catch { /* ignore */ }
    this.#port = null;
    this.#transport = null;
    this.#loader = null;
  }
}

/** Fetch the binaries a manifest build entry names, relative to the manifest. */
export async function fetchBuildParts(manifestUrl, build, onStatus = () => {}) {
  const base = new URL(manifestUrl, window.location.href);
  const parts = [];

  for (const part of build.parts) {
    const url = new URL(part.path, base);
    onStatus(`downloading ${part.path}`);
    const res = await fetch(url);
    if (!res.ok) {
      throw new Error(`could not fetch ${part.path}: HTTP ${res.status}`);
    }
    parts.push({
      address: part.offset,
      data: new Uint8Array(await res.arrayBuffer()),
      name: part.path,
    });
  }
  return parts;
}
