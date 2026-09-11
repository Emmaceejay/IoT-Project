import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  checkPin, selectablePins, validateAssignments, buildProvisioningPayload,
  roleKey, familyFromChipName,
} from '../lib/config-builder.js';

// Driven by the real catalogue, not fixtures: these tests should fail if the
// firmware's pin rules change in a way the flasher has not accounted for.
const chips   = JSON.parse(readFileSync(new URL('../../catalog/chips.json',   import.meta.url)));
const devices = JSON.parse(readFileSync(new URL('../../catalog/devices.json', import.meta.url)));

const byId = (id) => devices.devices.find((d) => d.id === id);
const C3   = chips.chips['ESP32-C3'];
const ESP32 = chips.chips['ESP32'];
const S3   = chips.chips['ESP32-S3'];

test('rejects SPI flash pins — the ones that hang the chip', () => {
  // C3 flash is 12-17. This is the single most important rejection: a user
  // typing 14 here would produce a board that does not boot.
  for (const pin of [12, 13, 14, 15, 16, 17]) {
    const r = checkPin(C3, pin, 'output');
    assert.equal(r.ok, false, `GPIO ${pin} should be refused`);
    assert.match(r.reason, /flash/i);
  }
});

test('rejects ESP32 input-only pins for outputs but allows them as inputs', () => {
  // 34-39 have no output driver: gpio_config() succeeds and the relay never
  // actuates, so this must be caught in the form.
  for (const pin of [34, 35, 36, 37, 38, 39]) {
    assert.equal(checkPin(ESP32, pin, 'output').ok, false, `GPIO ${pin} as output`);
    assert.equal(checkPin(ESP32, pin, 'input').ok, true,  `GPIO ${pin} as input`);
  }
});

test('rejects pins absent from the S3 die', () => {
  for (const pin of [22, 23, 24, 25]) {
    const r = checkPin(S3, pin, 'output');
    assert.equal(r.ok, false);
    assert.match(r.reason, /does not exist/);
  }
});

test('rejects non-ADC pins for an ADC role', () => {
  assert.equal(checkPin(C3, 0, 'adc').ok, true, 'C3 GPIO0 is ADC1_CH0');
  assert.equal(checkPin(C3, 10, 'adc').ok, false, 'C3 GPIO10 has no ADC1');
  assert.equal(checkPin(ESP32, 34, 'adc').ok, true, 'ESP32 GPIO34 is ADC1_CH6');
});

test('warns without blocking on console, USB and strapping pins', () => {
  const console_ = checkPin(C3, C3.console[0], 'output');
  assert.equal(console_.ok, true);
  assert.match(console_.warning, /UART0/);

  const strap = checkPin(C3, C3.strapping[0], 'output');
  assert.equal(strap.ok, true);
  assert.match(strap.warning, /strapping/);
});

test('-1 means not fitted and is always accepted', () => {
  assert.equal(checkPin(C3, -1, 'output').ok, true);
  assert.equal(checkPin(C3, -1, 'adc').ok, true);
});

test('selectable pins never include a reserved or absent pin', () => {
  for (const [family, chip] of Object.entries(chips.chips)) {
    for (const direction of ['output', 'input', 'adc']) {
      for (const pin of selectablePins(chip, direction)) {
        assert.ok(!chip.reserved.includes(pin),
          `${family}/${direction} offered reserved GPIO ${pin}`);
        assert.ok(!chip.not_exist.includes(pin),
          `${family}/${direction} offered absent GPIO ${pin}`);
        if (direction === 'output') {
          assert.ok(!chip.input_only.includes(pin),
            `${family} offered input-only GPIO ${pin} for an output`);
        }
      }
    }
  }
});

test('every catalogue device can be fully assigned on some chip', () => {
  for (const device of devices.devices) {
    const placed = Object.entries(chips.chips).some(([, chip]) => {
      const assignments = {};
      const taken = new Set();
      for (const rd of device.pin_roles) {
        const pin = selectablePins(chip, rd.direction).find((p) => !taken.has(p));
        if (pin === undefined) return false;
        taken.add(pin);
        assignments[roleKey(rd)] = pin;
      }
      return validateAssignments(device, chip, assignments).errors.length === 0;
    });
    assert.ok(placed, `${device.id} could not be placed on any chip`);
  }
});

test('flags a pin assigned to two roles', () => {
  const dev = byId('2gang_switch');
  const res = validateAssignments(dev, C3, {
    'relay:0': 2, 'relay:1': 2, 'switch:0': 5, 'switch:1': 6,
  });
  assert.equal(res.errors.length, 1);
  assert.match(res.errors[0], /GPIO 2 is assigned to/);
});

test('requires a pin for required roles only', () => {
  const dev = byId('1gang_switch');

  const missing = validateAssignments(dev, C3, { 'switch:0': 5 });
  assert.ok(missing.errors.some((e) => /Relay 1/.test(e)), 'relay is required');

  const ok = validateAssignments(dev, C3, { 'relay:0': 2 });
  assert.deepEqual(ok.errors, [], 'wall switch is optional');
});

test('payload matches the schema the firmware parses', () => {
  const dev = byId('2gang_switch');
  const payload = buildProvisioningPayload(dev, {
    'relay:0': 2, 'relay:1': 3, 'switch:0': 5, 'switch:1': 6,
  });

  assert.equal(payload.device_type, 'Switch');
  assert.deepEqual(payload.capabilities, ['relay', 'relay_2']);
  assert.equal(payload.relay_count, 2);
  assert.deepEqual(payload.pins.relay, [2, 3]);
  assert.deepEqual(payload.pins.switch, [5, 6]);
});

test('unfitted gangs keep their position in the array', () => {
  // The firmware indexes pins.relay by gang, so a short or shifted array would
  // silently wire gang 3 to gang 2's pin.
  const dev = byId('3gang_switch');
  const payload = buildProvisioningPayload(dev, {
    'relay:0': 2, 'relay:1': 3, 'relay:2': 4,
    'switch:0': 5, 'switch:2': 7,           // gang 2 has no wall switch
  });
  assert.deepEqual(payload.pins.switch, [5, -1, 7]);
  assert.equal(payload.pins.switch.length, dev.relay_count);
});

test('payload survives a JSON round trip within the frame limit', () => {
  const dev = byId('4gang_switch');
  const assignments = {};
  dev.pin_roles.forEach((rd, i) => { assignments[roleKey(rd)] = i + 1; });
  const json = JSON.stringify(buildProvisioningPayload(dev, assignments));

  assert.deepEqual(JSON.parse(json).pins.relay, [1, 2, 3, 4]);
  assert.ok(json.length < 1024, `payload ${json.length} B must fit MAX_PAYLOAD`);
});

test('maps esptool chip names onto catalogue families', () => {
  // Strings in the shape esptool-js actually reports.
  assert.equal(familyFromChipName(chips, 'ESP32-C3 (QFN32) (revision v0.4)'), 'ESP32-C3');
  assert.equal(familyFromChipName(chips, 'ESP32-S3 (QFN56)'), 'ESP32-S3');
  assert.equal(familyFromChipName(chips, 'ESP32-C6 (QFN40)'), 'ESP32-C6');

  // Package variants of the original ESP32 are still plain ESP32.
  assert.equal(familyFromChipName(chips, 'ESP32-D0WD-V3 (revision v3.1)'), 'ESP32');
  assert.equal(familyFromChipName(chips, 'ESP32-PICO-D4'), 'ESP32');
  assert.equal(familyFromChipName(chips, 'ESP32'), 'ESP32');
});

test('refuses a known variant we do not support rather than guessing', () => {
  // Regression: substring matching used to report these as plain ESP32,
  // which would have flashed an Xtensa image onto a RISC-V part.
  for (const name of ['ESP32-H2', 'ESP32-C2 (QFN24)', 'ESP32-P4', 'ESP32-S2']) {
    assert.equal(familyFromChipName(chips, name), null, `${name} must not match`);
  }
  assert.equal(familyFromChipName(chips, 'ESP8266EX'), null);
  assert.equal(familyFromChipName(chips, ''), null);
  assert.equal(familyFromChipName(chips, undefined), null);
});
