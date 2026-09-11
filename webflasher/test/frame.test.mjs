import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  encodeFrame, FrameDecoder, MsgType, MAGIC, HEADER_LEN, MAX_PAYLOAD,
} from '../lib/dsgv-frame.js';

const enc = new TextEncoder();

test('header layout matches the wire spec', () => {
  const f = encodeFrame(MsgType.SET_CONFIG, '{"relay_count":1}');
  assert.deepEqual([...f.slice(0, 4)], MAGIC, 'magic');
  assert.equal(f[4], 1, 'version');
  assert.equal(f[5], MsgType.SET_CONFIG, 'type');
  assert.equal((f[6] << 8) | f[7], 17, 'big-endian length');
  assert.equal(f.at(-1), 0x0a, 'newline terminator');
});

test('checksum is the sum of every preceding byte', () => {
  const f = encodeFrame(MsgType.SET_CONFIG, '{"relay_count":1}');
  let sum = 0;
  for (let i = 0; i < f.length - 2; i++) sum += f[i];
  assert.equal(f.at(-2), sum & 0xff);
});

test('matches the Python reference encoder byte for byte', () => {
  // Values captured from dsgv_firmware/tools/dsgv_serial_config.py, which is
  // the implementation the firmware was developed against. If these two ever
  // disagree, one of them is wrong on the wire.
  const f = encodeFrame(MsgType.SET_CONFIG, '{"relay_count":1}');
  assert.equal(f.length, 27);
  assert.equal(f.at(-2), 0x94);

  const empty = encodeFrame(MsgType.REQUEST_INFO);
  assert.equal(empty.length, 10);
  assert.equal((empty[6] << 8) | empty[7], 0);
});

test('rejects an oversized payload rather than truncating', () => {
  assert.throws(
    () => encodeFrame(MsgType.SET_CONFIG, 'x'.repeat(MAX_PAYLOAD + 1)),
    RangeError,
  );
});

test('round-trips through the decoder', () => {
  const d = new FrameDecoder();
  const frames = d.push(encodeFrame(MsgType.RESPONSE_OK, '{"ok":true}'));
  assert.equal(frames.length, 1);
  assert.equal(frames[0].type, MsgType.RESPONSE_OK);
  assert.equal(frames[0].text, '{"ok":true}');
});

test('recovers a frame buried in boot log output', () => {
  // The realistic case: UART0 carries ESP_LOG output and frames together.
  const d = new FrameDecoder();
  const noise = enc.encode('I (312) DSGV_gpio: LEDC ready: 2 channels\n');
  const frame = encodeFrame(MsgType.RESPONSE_OK, '{"chip":"esp32c3"}');
  const more = enc.encode('W (410) DSGV_cfg: relay_pins[1]=99 rejected\n');

  const got = d.push(new Uint8Array([...noise, ...frame, ...more]));
  assert.equal(got.length, 1);
  assert.equal(got[0].text, '{"chip":"esp32c3"}');
});

test('reassembles a frame split across reads', () => {
  const d = new FrameDecoder();
  const f = encodeFrame(MsgType.RESPONSE_OK, '{"a":1,"b":2}');
  const cut = 5;

  assert.equal(d.push(f.slice(0, cut)).length, 0, 'incomplete yields nothing');
  const done = d.push(f.slice(cut));
  assert.equal(done.length, 1);
  assert.equal(done[0].text, '{"a":1,"b":2}');
});

test('ignores a log line that merely contains the magic', () => {
  // "DSGV" appears in every log tag, so this is not a contrived case.
  const d = new FrameDecoder();
  const bait = enc.encode('I (77) DSGV_serial: listening on UART0\n');
  const real = encodeFrame(MsgType.RESPONSE_OK, 'ok');

  const got = d.push(new Uint8Array([...bait, ...real]));
  assert.equal(got.length, 1, 'only the genuine frame is returned');
  assert.equal(got[0].text, 'ok');
});

test('drops a frame whose checksum is wrong', () => {
  const d = new FrameDecoder();
  const f = encodeFrame(MsgType.RESPONSE_OK, 'payload');
  f[f.length - 2] ^= 0xff;                       // corrupt in transit
  assert.equal(d.push(f).length, 0);
});

test('handles several frames in one read', () => {
  const d = new FrameDecoder();
  const a = encodeFrame(MsgType.RESPONSE_OK, 'first');
  const b = encodeFrame(MsgType.RESPONSE_ERR, 'second');
  const got = d.push(new Uint8Array([...a, ...b]));
  assert.equal(got.length, 2);
  assert.equal(got[0].text, 'first');
  assert.equal(got[1].type, MsgType.RESPONSE_ERR);
});

test('a byte-at-a-time feed behaves like one bulk read', () => {
  const d = new FrameDecoder();
  const f = encodeFrame(MsgType.RESPONSE_OK, '{"drip":true}');
  let got = [];
  for (const b of f) got = got.concat(d.push(new Uint8Array([b])));
  assert.equal(got.length, 1);
  assert.equal(got[0].text, '{"drip":true}');
});
