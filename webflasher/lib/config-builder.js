/**
 * Turn a catalogue device plus the user's pin choices into the provisioning
 * payload the firmware accepts, refusing anything the firmware would reject.
 *
 * Validation is duplicated here on purpose. The firmware validates too, and
 * that is the authority — but it can only refuse a pin after the device has
 * been flashed and provisioned, by which point the user has already wired the
 * board. Catching it in the form is the difference between a red field and a
 * rebuild.
 *
 * The rules come from catalog/chips.json, which is generated from
 * dsgv_pin_rules.c, so this cannot quietly disagree with the firmware.
 */

/** Roles the firmware accepts as arrays, indexed per relay gang. */
const ARRAY_ROLES = new Set(['relay', 'switch']);

/**
 * Check one pin against a chip's rules.
 * @returns {{ok: boolean, reason?: string, warning?: string}}
 */
export function checkPin(chip, pin, direction) {
  if (pin === -1 || pin === null || pin === undefined) {
    return { ok: true };                       // not fitted
  }
  if (!Number.isInteger(pin)) {
    return { ok: false, reason: 'not a whole number' };
  }
  if (pin < 0 || pin >= chip.pin_limit) {
    return { ok: false, reason: `outside GPIO 0–${chip.pin_limit - 1}` };
  }
  if (chip.not_exist.includes(pin)) {
    return { ok: false, reason: 'this pin does not exist on this chip' };
  }
  if (chip.reserved.includes(pin)) {
    return { ok: false, reason: 'reserved for SPI flash / PSRAM — using it will hang the chip' };
  }
  if (direction === 'output' && chip.input_only.includes(pin)) {
    return { ok: false, reason: 'input-only; it cannot drive an output' };
  }
  if (direction === 'adc' && !(String(pin) in chip.adc1)) {
    return { ok: false, reason: 'no ADC1 channel on this pin' };
  }

  // Usable, but the user should know.
  if (chip.console.includes(pin)) {
    return { ok: true, warning: 'this is the UART0 console — serial logging and serial setup will stop working' };
  }
  if (chip.usb.includes(pin)) {
    return { ok: true, warning: 'this is a native USB pin — USB-Serial-JTAG will stop working' };
  }
  if (chip.strapping.includes(pin)) {
    return { ok: true, warning: 'boot strapping pin — an attached load may stop the device booting' };
  }
  return { ok: true };
}

/** Pins a chip can offer for a given direction, in ascending order. */
export function selectablePins(chip, direction) {
  if (direction === 'adc') {
    return Object.keys(chip.adc1).map(Number).sort((a, b) => a - b);
  }
  const base = direction === 'output' ? chip.output_capable : chip.usable;
  return [...base].sort((a, b) => a - b);
}

/**
 * Validate a full set of assignments for a device on a chip.
 *
 * @param device      entry from catalog/devices.json
 * @param chip        entry from catalog/chips.json
 * @param assignments { "relay:0": 2, "dimmer": 4, ... }  keyed by roleKey()
 * @returns {{errors: string[], warnings: string[]}}
 */
export function validateAssignments(device, chip, assignments) {
  const errors = [];
  const warnings = [];
  const used = new Map();                       // pin -> [labels]

  for (const roleDef of device.pin_roles) {
    const key = roleKey(roleDef);
    const pin = assignments[key];
    const label = roleDef.label ?? key;

    if (pin === undefined || pin === null || pin === -1) {
      if (roleDef.required) errors.push(`${label}: a pin must be chosen`);
      continue;
    }

    const res = checkPin(chip, pin, roleDef.direction);
    if (!res.ok) {
      errors.push(`${label} (GPIO ${pin}): ${res.reason}`);
      continue;
    }
    if (res.warning) warnings.push(`${label} (GPIO ${pin}): ${res.warning}`);

    if (!used.has(pin)) used.set(pin, []);
    used.get(pin).push(label);
  }

  // A pin driven by two roles is always a mistake when the user picked both.
  // The firmware only warns, because its shipped defaults overlap deliberately;
  // here we know every value was chosen for this one device, so it is an error.
  for (const [pin, labels] of used) {
    if (labels.length > 1) {
      errors.push(`GPIO ${pin} is assigned to ${labels.join(' and ')} — one pin cannot do both`);
    }
  }

  return { errors, warnings };
}

/** Stable key for a pin role, matching the shape used in assignments. */
export function roleKey(roleDef) {
  return ARRAY_ROLES.has(roleDef.role)
    ? `${roleDef.role}:${roleDef.index}`
    : roleDef.role;
}

/**
 * Build the JSON the firmware's SET_CONFIG expects.
 * Assumes validateAssignments() has already passed.
 */
export function buildProvisioningPayload(device, assignments) {
  const pins = {};

  for (const roleDef of device.pin_roles) {
    const pin = assignments[roleKey(roleDef)];
    const value = pin === undefined || pin === null ? -1 : pin;

    if (ARRAY_ROLES.has(roleDef.role)) {
      if (!pins[roleDef.role]) {
        // Fill with -1 so gang indices stay positional; the firmware reads
        // this array by index, so a short array would shift later gangs.
        pins[roleDef.role] = new Array(device.relay_count).fill(-1);
      }
      pins[roleDef.role][roleDef.index] = value;
    } else {
      pins[roleDef.role] = value;
    }
  }

  return {
    device_type:  device.device_type,
    capabilities: [...device.capabilities],
    relay_count:  device.relay_count,
    pins,
  };
}

/** Chip families in the catalogue that the flasher can serve. */
export function supportedFamilies(chips) {
  return Object.keys(chips.chips).sort();
}

/**
 * Map an esptool-js chip name to a catalogue family key.
 * esptool reports things like "ESP32-C3 (QFN32) (revision v0.4)".
 */
export function familyFromChipName(chips, reported) {
  if (!reported) return null;
  const upper = reported.toUpperCase();

  // Substring matching is not safe here. "ESP32-H2" contains "ESP32", so a
  // naive includes() identifies an unsupported H2 as a plain ESP32 and the
  // flasher writes the wrong binary to it — a board that appears bricked.
  //
  // Variant suffixes are a known letter plus a digit: C2/C3/C5/C6, S2/S3,
  // H2, P4. The \b matters because package names like ESP32-D0WD-V3 and
  // ESP32-PICO-D4 are plain ESP32 parts and must not be read as variants.
  const variant = upper.match(/ESP32-([CSHP]\d+)\b/);
  if (variant) {
    const family = `ESP32-${variant[1]}`;
    return family in chips.chips ? family : null;   // known variant, unsupported
  }

  if (/\bESP8266\b/.test(upper)) {
    return 'ESP8266' in chips.chips ? 'ESP8266' : null;
  }
  if (/\bESP32\b/.test(upper) || upper.startsWith('ESP32-')) {
    return 'ESP32' in chips.chips ? 'ESP32' : null;
  }
  return null;
}
