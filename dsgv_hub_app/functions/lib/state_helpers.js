/**
 * state_helpers.js — Shared utilities for mapping DSGV device capabilities
 * to Google Home traits and Alexa interfaces.
 *
 * Both the Google Smart Home handler (smarthome_google.js) and the Alexa
 * handler (smarthome_alexa.js) need to:
 *   1. Convert a capabilities array (e.g. ["relay","brightness"]) to the
 *      correct set of voice-platform trait/interface objects.
 *   2. Read the current device state from the Firebase "device_states" node
 *      and format it for QUERY / ReportState responses.
 *   3. Translate voice commands back into MQTT command payloads.
 *
 * Putting this logic here keeps the two handler files thin and ensures the
 * mapping stays consistent.
 */

const admin = require("firebase-admin");

// ── State Mirror ──────────────────────────────────────────────────────────────

/**
 * Read the current state of a device from the Firebase "device_states" node.
 * Returns {} if no state has been recorded yet (device never sent telemetry).
 *
 * @param {string} deviceId  - Uppercase 12-hex MAC address e.g. "A1B2C3D4E5F6"
 * @returns {Promise<object>} - State object: { power, brightness, ... }
 */
async function getDeviceState(deviceId) {
  const db = admin.database();
  const snap = await db.ref(`device_states/${deviceId}`).once("value");
  return snap.val() || {};
}

/**
 * Optimistically write a pending command into the state mirror so that
 * a QUERY arriving immediately after an EXECUTE sees the expected state
 * instead of the stale pre-command state.
 *
 * The MQTT broker will later update the same node with the real telemetry
 * from the device — overwriting this optimistic value.
 *
 * @param {string} deviceId  - Device MAC address
 * @param {object} command   - MQTT command payload to merge into state
 */
async function optimisticStateUpdate(deviceId, command) {
  const db = admin.database();
  await db.ref(`device_states/${deviceId}`).update({
    ...command,
    last_updated: Date.now(),
  });
}

// ── Capability → Google Trait mapping ─────────────────────────────────────────
//
// Each capability string maps to one or more Google Home trait names and a
// Google device type. The device type controls the icon shown in Google Home.
//
// Reference: https://developers.home.google.com/cloud-to-cloud/traits

/**
 * Given a capabilities array, return the Google Home device type string and
 * trait list appropriate for that device.
 *
 * @param {string[]} caps - e.g. ["relay", "brightness"]
 * @returns {{ type: string, traits: string[], attributes: object }}
 */
function googleDeviceProfile(caps) {
  // Determine device type from capability combination — order matters:
  // check for the most specific combination first.
  let deviceType;
  if (caps.includes("hvac_mode")) {
    deviceType = "action.devices.types.THERMOSTAT";
  } else if (caps.includes("motion")) {
    deviceType = "action.devices.types.SENSOR";
  } else if (caps.includes("contact")) {
    deviceType = "action.devices.types.SENSOR";
  } else if (caps.includes("temperature") && !caps.includes("relay")) {
    deviceType = "action.devices.types.SENSOR";
  } else if (caps.includes("rgb") || caps.includes("color_temp") || caps.includes("brightness")) {
    deviceType = "action.devices.types.LIGHT";
  } else if (caps.includes("relay")) {
    deviceType = "action.devices.types.SWITCH";
  } else {
    deviceType = "action.devices.types.SENSOR";
  }

  // Build the trait list — add every trait whose capability is present.
  const traits = [];
  const attributes = {};

  if (caps.includes("relay")) {
    traits.push("action.devices.traits.OnOff");
  }
  if (caps.includes("brightness")) {
    traits.push("action.devices.traits.Brightness");
  }
  if (caps.includes("color_temp") && !caps.includes("rgb")) {
    traits.push("action.devices.traits.ColorSetting");
    attributes.colorModel = "temp";
    // The ESP32 firmware supports 2000 K (warm white) to 6500 K (cool daylight)
    attributes.colorTemperatureRange = { temperatureMinK: 2000, temperatureMaxK: 6500 };
  }
  if (caps.includes("rgb")) {
    traits.push("action.devices.traits.ColorSetting");
    attributes.colorModel = "rgb";
  }
  if (caps.includes("brightness") || caps.includes("color_temp") || caps.includes("rgb")) {
    // All light devices support scenes (on/off via OnOff trait, already added)
  }
  if (caps.includes("temperature")) {
    traits.push("action.devices.traits.TemperatureControl");
    attributes.queryOnlyTemperatureControl = !caps.includes("hvac_mode");
    attributes.temperatureUnitForUX = "C";
  }
  if (caps.includes("humidity")) {
    traits.push("action.devices.traits.HumiditySetting");
    attributes.queryOnlyHumiditySetting = true;
  }
  if (caps.includes("hvac_mode")) {
    traits.push("action.devices.traits.ThermostatMode");
    traits.push("action.devices.traits.TemperatureControl");
    attributes.availableThermostatModes = ["off", "heat", "cool", "auto"];
    attributes.thermostatTemperatureUnit = "C";
  }
  if (caps.includes("motion")) {
    traits.push("action.devices.traits.OccupancySensing");
    attributes.occupancySensorConfiguration = [{ occupancySensorType: "PIR" }];
  }
  if (caps.includes("contact")) {
    traits.push("action.devices.traits.OpenClose");
    attributes.queryOnlyOpenClose = true;
    attributes.discreteOnlyOpenClose = true;
  }

  return { type: deviceType, traits, attributes };
}

/**
 * Convert a DSGV device state (from Firebase device_states/) to the format
 * expected by a Google Home QUERY response.
 *
 * @param {object} state  - Raw state from Firebase
 * @param {string[]} caps - Device capabilities
 * @returns {object}      - Google Home state object
 */
function toGoogleState(state, caps) {
  const result = {
    online: state.online !== false,
    status: "SUCCESS",
  };

  if (caps.includes("relay")) {
    result.on = state.power === true;
  }
  if (caps.includes("brightness")) {
    // Google expects 0-100 integer; firmware stores 0-100 already.
    result.brightness = typeof state.brightness === "number"
        ? Math.round(state.brightness)
        : 0;
  }
  if (caps.includes("color_temp") && !caps.includes("rgb")) {
    result.color = { temperatureK: state.color_temp || 4000 };
  }
  if (caps.includes("rgb")) {
    const r = state.red   || 255;
    const g = state.green || 255;
    const b = state.blue  || 255;
    // Google expects a 24-bit integer: (R << 16) | (G << 8) | B
    result.color = { spectrumRgb: (r << 16) | (g << 8) | b };
  }
  if (caps.includes("temperature")) {
    result.temperatureSetpointCelsius = state.current_temp || 20;
    result.temperatureAmbientCelsius  = state.current_temp || 20;
  }
  if (caps.includes("humidity")) {
    result.humidityAmbientPercent = state.humidity || 0;
  }
  if (caps.includes("hvac_mode")) {
    result.thermostatMode = state.mode || "off";
    result.thermostatTemperatureSetpoint = state.target_temp || 20;
    result.thermostatTemperatureAmbient  = state.current_temp || 20;
  }
  if (caps.includes("motion")) {
    result.occupancy = state.motion === true;
  }
  if (caps.includes("contact")) {
    result.openPercent = state.contact === false ? 100 : 0;
  }

  return result;
}

/**
 * Translate a Google Home EXECUTE command into the MQTT payload that the
 * DSGV firmware understands.
 *
 * Google sends structured execution objects. We map each supported command
 * to one or more MQTT key-value pairs.
 *
 * @param {string} command  - Google command name, e.g. "action.devices.commands.OnOff"
 * @param {object} params   - Command parameters from Google
 * @returns {object}        - MQTT command payload to publish, or {} if unknown
 */
function googleCommandToMqtt(command, params) {
  switch (command) {
    case "action.devices.commands.OnOff":
      return { power: params.on };

    case "action.devices.commands.BrightnessAbsolute":
      return { brightness: params.brightness };

    case "action.devices.commands.BrightnessRelative":
      // Relative brightness change — the firmware will handle clamping to [0,100]
      return { brightness_delta: params.relativePercent };

    case "action.devices.commands.ColorAbsolute":
      if (params.color?.temperatureK !== undefined) {
        return { color_temp: params.color.temperatureK };
      }
      if (params.color?.spectrumRgb !== undefined) {
        const rgb = params.color.spectrumRgb;
        return {
          red:   (rgb >> 16) & 0xFF,
          green: (rgb >>  8) & 0xFF,
          blue:   rgb        & 0xFF,
        };
      }
      return {};

    case "action.devices.commands.ThermostatTemperatureSetpoint":
      return { target_temp: params.thermostatTemperatureSetpoint };

    case "action.devices.commands.ThermostatSetMode":
      return { mode: params.thermostatMode };

    default:
      return {};
  }
}

// ── Capability → Alexa Interface mapping ──────────────────────────────────────
//
// Alexa Smart Home Skill uses a different vocabulary from Google.
// "Interfaces" ≈ Google "traits". Each interface has a version and optional config.
//
// Reference: https://developer.amazon.com/en-US/docs/alexa/device-apis/list-of-interfaces.html

/**
 * Given a capabilities array, return the Alexa Smart Home interface list
 * and display categories appropriate for that device.
 *
 * @param {string[]} caps - e.g. ["relay", "brightness"]
 * @returns {{ categories: string[], interfaces: object[] }}
 */
function alexaDeviceProfile(caps) {
  const interfaces = [];

  // Every endpoint must declare the base Alexa interface and EndpointHealth.
  // EndpointHealth lets Alexa know if the device is reachable.
  interfaces.push({ type: "AlexaInterface", interface: "Alexa", version: "3" });
  interfaces.push({
    type: "AlexaInterface",
    interface: "Alexa.EndpointHealth",
    version: "3",
    properties: {
      supported: [{ name: "connectivity" }],
      proactivelyReported: false,
      retrievable: true,
    },
  });

  if (caps.includes("relay")) {
    interfaces.push({
      type: "AlexaInterface",
      interface: "Alexa.PowerController",
      version: "3",
      properties: {
        supported: [{ name: "powerState" }],
        proactivelyReported: false,
        retrievable: true,
      },
    });
  }
  if (caps.includes("brightness")) {
    interfaces.push({
      type: "AlexaInterface",
      interface: "Alexa.BrightnessController",
      version: "3",
      properties: {
        supported: [{ name: "brightness" }],
        proactivelyReported: false,
        retrievable: true,
      },
    });
  }
  if (caps.includes("color_temp")) {
    interfaces.push({
      type: "AlexaInterface",
      interface: "Alexa.ColorTemperatureController",
      version: "3",
      properties: {
        supported: [{ name: "colorTemperatureInKelvin" }],
        proactivelyReported: false,
        retrievable: true,
      },
    });
  }
  if (caps.includes("rgb")) {
    interfaces.push({
      type: "AlexaInterface",
      interface: "Alexa.ColorController",
      version: "3",
      properties: {
        supported: [{ name: "color" }],
        proactivelyReported: false,
        retrievable: true,
      },
    });
  }
  if (caps.includes("temperature")) {
    interfaces.push({
      type: "AlexaInterface",
      interface: "Alexa.TemperatureSensor",
      version: "3",
      properties: {
        supported: [{ name: "temperature" }],
        proactivelyReported: false,
        retrievable: true,
      },
    });
  }
  if (caps.includes("hvac_mode")) {
    interfaces.push({
      type: "AlexaInterface",
      interface: "Alexa.ThermostatController",
      version: "3",
      properties: {
        supported: [
          { name: "targetSetpoint" },
          { name: "thermostatMode" },
        ],
        proactivelyReported: false,
        retrievable: true,
      },
      configuration: {
        supportedModes: ["OFF", "HEAT", "COOL", "AUTO"],
        supportsScheduling: false,
      },
    });
  }
  if (caps.includes("motion")) {
    interfaces.push({
      type: "AlexaInterface",
      interface: "Alexa.MotionSensor",
      version: "3",
      properties: {
        supported: [{ name: "detectionState" }],
        proactivelyReported: false,
        retrievable: true,
      },
    });
  }
  if (caps.includes("contact")) {
    interfaces.push({
      type: "AlexaInterface",
      interface: "Alexa.ContactSensor",
      version: "3",
      properties: {
        supported: [{ name: "detectionState" }],
        proactivelyReported: false,
        retrievable: true,
      },
    });
  }

  // Display category affects the icon in the Alexa app
  let categories;
  if (caps.includes("hvac_mode")) {
    categories = ["THERMOSTAT"];
  } else if (caps.includes("motion")) {
    categories = ["MOTION_SENSOR"];
  } else if (caps.includes("contact")) {
    categories = ["CONTACT_SENSOR"];
  } else if (caps.includes("temperature") && !caps.includes("relay")) {
    categories = ["TEMPERATURE_SENSOR"];
  } else if (caps.includes("rgb") || caps.includes("color_temp") || caps.includes("brightness")) {
    categories = ["LIGHT"];
  } else {
    categories = ["SWITCH"];
  }

  return { categories, interfaces };
}

/**
 * Build an Alexa property list for a ReportState or ChangeReport response.
 * Each property describes the current value of one attribute of the device.
 *
 * @param {object} state  - Raw state from Firebase device_states/
 * @param {string[]} caps - Device capabilities
 * @returns {object[]}    - Array of Alexa property objects
 */
function toAlexaProperties(state, caps) {
  const now = new Date().toISOString();
  const uncertainty = 1000; // ms — how stale the value might be
  const props = [];

  // EndpointHealth.connectivity is always reported
  props.push({
    namespace: "Alexa.EndpointHealth",
    name: "connectivity",
    value: { value: state.online !== false ? "OK" : "UNREACHABLE" },
    timeOfSample: now,
    uncertaintyInMilliseconds: uncertainty,
  });

  if (caps.includes("relay")) {
    props.push({
      namespace: "Alexa.PowerController",
      name: "powerState",
      value: state.power === true ? "ON" : "OFF",
      timeOfSample: now,
      uncertaintyInMilliseconds: uncertainty,
    });
  }
  if (caps.includes("brightness")) {
    props.push({
      namespace: "Alexa.BrightnessController",
      name: "brightness",
      value: typeof state.brightness === "number" ? Math.round(state.brightness) : 0,
      timeOfSample: now,
      uncertaintyInMilliseconds: uncertainty,
    });
  }
  if (caps.includes("color_temp")) {
    props.push({
      namespace: "Alexa.ColorTemperatureController",
      name: "colorTemperatureInKelvin",
      value: state.color_temp || 4000,
      timeOfSample: now,
      uncertaintyInMilliseconds: uncertainty,
    });
  }
  if (caps.includes("rgb")) {
    // Alexa expects color as { hue, saturation, brightness } (HSB model)
    // Simple conversion from RGB: approximate for now, full conversion available if needed
    props.push({
      namespace: "Alexa.ColorController",
      name: "color",
      value: rgbToHsb(state.red || 255, state.green || 255, state.blue || 255),
      timeOfSample: now,
      uncertaintyInMilliseconds: uncertainty,
    });
  }
  if (caps.includes("temperature")) {
    props.push({
      namespace: "Alexa.TemperatureSensor",
      name: "temperature",
      value: { value: state.current_temp || 20, scale: "CELSIUS" },
      timeOfSample: now,
      uncertaintyInMilliseconds: uncertainty,
    });
  }
  if (caps.includes("hvac_mode")) {
    // Alexa thermostat mode values are uppercase: "OFF", "HEAT", "COOL", "AUTO"
    props.push({
      namespace: "Alexa.ThermostatController",
      name: "thermostatMode",
      value: { value: (state.mode || "off").toUpperCase() },
      timeOfSample: now,
      uncertaintyInMilliseconds: uncertainty,
    });
    props.push({
      namespace: "Alexa.ThermostatController",
      name: "targetSetpoint",
      value: { value: state.target_temp || 20, scale: "CELSIUS" },
      timeOfSample: now,
      uncertaintyInMilliseconds: uncertainty,
    });
  }
  if (caps.includes("motion")) {
    props.push({
      namespace: "Alexa.MotionSensor",
      name: "detectionState",
      value: state.motion === true ? "DETECTED" : "NOT_DETECTED",
      timeOfSample: now,
      uncertaintyInMilliseconds: uncertainty,
    });
  }
  if (caps.includes("contact")) {
    // Reed switch: contact=true means closed, contact=false means open
    props.push({
      namespace: "Alexa.ContactSensor",
      name: "detectionState",
      value: state.contact !== false ? "NOT_DETECTED" : "DETECTED",
      timeOfSample: now,
      uncertaintyInMilliseconds: uncertainty,
    });
  }

  return props;
}

/**
 * Convert Alexa directive name and payload to the MQTT command the firmware expects.
 *
 * @param {string} namespace  - Alexa interface namespace
 * @param {string} name       - Directive name
 * @param {object} payload    - Directive payload
 * @returns {object}          - MQTT command payload
 */
function alexaDirectiveToMqtt(namespace, name, payload) {
  switch (`${namespace}.${name}`) {
    case "Alexa.PowerController.TurnOn":
      return { power: true };
    case "Alexa.PowerController.TurnOff":
      return { power: false };

    case "Alexa.BrightnessController.SetBrightness":
      return { brightness: payload.brightness };
    case "Alexa.BrightnessController.AdjustBrightness":
      return { brightness_delta: payload.brightnessDelta };

    case "Alexa.ColorTemperatureController.SetColorTemperature":
      return { color_temp: payload.colorTemperatureInKelvin };

    case "Alexa.ColorController.SetColor": {
      // Alexa sends HSB — convert to RGB for the firmware
      const rgb = hsbToRgb(payload.color.hue, payload.color.saturation, payload.color.brightness);
      return { red: rgb.r, green: rgb.g, blue: rgb.b };
    }

    case "Alexa.ThermostatController.SetTargetTemperature":
      return { target_temp: payload.targetSetpoint.value };
    case "Alexa.ThermostatController.SetThermostatMode":
      return { mode: (payload.thermostatMode.value || "off").toLowerCase() };

    default:
      return {};
  }
}

// ── Colour space conversions ──────────────────────────────────────────────────

/**
 * RGB (0-255 each) → HSB (Hue 0-360, Saturation 0-1, Brightness 0-1).
 * Used when reporting RGB state to Alexa.
 */
function rgbToHsb(r, g, b) {
  r /= 255; g /= 255; b /= 255;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const d = max - min;
  let h = 0;
  if (d !== 0) {
    if (max === r) h = ((g - b) / d) % 6;
    else if (max === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
    h = Math.round(h * 60);
    if (h < 0) h += 360;
  }
  return { hue: h, saturation: max ? d / max : 0, brightness: max };
}

/**
 * HSB → RGB (0-255 each).
 * Used when receiving a SetColor directive from Alexa.
 */
function hsbToRgb(h, s, v) {
  const c = v * s;
  const x = c * (1 - Math.abs((h / 60) % 2 - 1));
  const m = v - c;
  let r, g, b;
  if (h < 60)       { r = c; g = x; b = 0; }
  else if (h < 120) { r = x; g = c; b = 0; }
  else if (h < 180) { r = 0; g = c; b = x; }
  else if (h < 240) { r = 0; g = x; b = c; }
  else if (h < 300) { r = x; g = 0; b = c; }
  else              { r = c; g = 0; b = x; }
  return {
    r: Math.round((r + m) * 255),
    g: Math.round((g + m) * 255),
    b: Math.round((b + m) * 255),
  };
}

module.exports = {
  getDeviceState,
  optimisticStateUpdate,
  googleDeviceProfile,
  toGoogleState,
  googleCommandToMqtt,
  alexaDeviceProfile,
  toAlexaProperties,
  alexaDirectiveToMqtt,
};
