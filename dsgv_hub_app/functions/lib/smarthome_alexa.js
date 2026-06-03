/**
 * smarthome_alexa.js — Amazon Alexa Smart Home Skill Directive Handler.
 *
 * Alexa calls this Cloud Function when a user gives a voice command, asks for
 * device state, or discovers/removes devices.
 *
 * Setup checklist:
 *   1. Create a Smart Home Skill in the Alexa Developer Console.
 *   2. Set the Default Endpoint to:
 *        https://us-central1-YOUR_PROJECT_ID.cloudfunctions.net/alexaSmartHome
 *   3. Configure account linking (OAuth 2.0, Authorization Code):
 *        Authorization URI:  …/oauth/authorize
 *        Access Token URI:   …/oauth/token
 *        Client ID:          value of ALEXA_CLIENT_ID in your config
 *        Client Secret:      value of ALEXA_CLIENT_SECRET in your config
 *        Scope:              dsgv.devices.control
 *   4. Submit the skill for certification. Alexa requires HTTPS with a valid
 *        TLS certificate — Firebase Cloud Functions URL satisfies this.
 *
 * Reference: https://developer.amazon.com/en-US/docs/alexa/smarthome/understand-the-smart-home-skill-api.html
 */

const admin  = require("firebase-admin");
const mqtt   = require("mqtt");
const { validateBearerToken } = require("./oauth");
const helpers = require("./state_helpers");

const db = admin.database();

// Module-level MQTT client — shared across warm invocations (see smarthome_google.js)
let mqttClient = null;

function getMqttClient() {
  if (mqttClient && mqttClient.connected) return mqttClient;
  const { functions } = require("firebase-functions");
  const cfg = functions.config();
  mqttClient = mqtt.connect(
    cfg.mqtt?.url || process.env.MQTT_BROKER_URL || "mqtts://mqtt.dsgv.io:8883",
    {
      username: cfg.mqtt?.username || process.env.MQTT_USERNAME || "",
      password: cfg.mqtt?.password || process.env.MQTT_PASSWORD || "",
      keepalive: 30,
      reconnectPeriod: 2000,
    }
  );
  mqttClient.on("error", (err) => console.error("[Alexa] MQTT error:", err.message));
  return mqttClient;
}

// ── Device list helper ────────────────────────────────────────────────────────

async function getUserDeviceIds(uid) {
  const snap = await db.ref(`user_devices/${uid}`).once("value");
  return snap.exists() ? Object.keys(snap.val()) : [];
}

async function getDeviceMeta(deviceId) {
  const [regSnap] = await Promise.all([
    db.ref(`device_registry/${deviceId}`).once("value"),
  ]);
  return regSnap.val() || {};
}

// ── Response builder helpers ──────────────────────────────────────────────────

/**
 * Build an Alexa response envelope.
 * Every Alexa Smart Home response has this outer structure.
 *
 * @param {string} namespace    - e.g. "Alexa.Discovery"
 * @param {string} name         - e.g. "Discover.Response"
 * @param {string} correlationToken - echo from request header (or undefined for Discovery)
 * @param {string} endpointId   - target device (or undefined for Discovery)
 * @param {object} payload      - response-specific payload
 */
function buildAlexaResponse(namespace, name, correlationToken, endpointId, payload = {}) {
  const header = {
    namespace,
    name,
    messageId: require("crypto").randomUUID(),
    payloadVersion: "3",
  };
  if (correlationToken) header.correlationToken = correlationToken;

  const context = {};
  if (endpointId) {
    context.endpoint = { endpointId };
  }

  return { event: { header, endpoint: endpointId ? { endpointId } : undefined, payload } };
}

// ── Discovery ─────────────────────────────────────────────────────────────────

/**
 * Alexa.Discovery.Discover — User asks Alexa to discover their smart home devices.
 *
 * Returns an endpoint object for every device linked to the user's account.
 * The capabilities list tells Alexa which voice commands it can send.
 */
async function handleDiscovery(uid, directive) {
  const deviceIds = await getUserDeviceIds(uid);

  const endpoints = await Promise.all(deviceIds.map(async (mac) => {
    const meta = await getDeviceMeta(mac);
    const caps = JSON.parse(meta.capabilities || "[]");
    const { categories, interfaces } = helpers.alexaDeviceProfile(caps);

    return {
      endpointId:   mac,
      manufacturerName: "DSGV",
      description: `DSGV ${meta.device_type || "Smart Device"}`,
      friendlyName: meta.device_name || mac,
      displayCategories: categories,
      capabilities: interfaces,
    };
  }));

  return {
    event: {
      header: {
        namespace:      "Alexa.Discovery",
        name:           "Discover.Response",
        messageId:      require("crypto").randomUUID(),
        payloadVersion: "3",
      },
      payload: { endpoints },
    },
  };
}

// ── ReportState ───────────────────────────────────────────────────────────────

/**
 * Alexa.ReportState — Alexa asks for the current state of a device.
 *
 * This is called when the user asks "Alexa, is the kitchen light on?" or when
 * an Alexa Routine needs to check state before proceeding.
 */
async function handleReportState(uid, directive) {
  const mac = directive.endpoint.endpointId;
  const userDeviceIds = await getUserDeviceIds(uid);

  if (!userDeviceIds.includes(mac)) {
    return buildAlexaResponse(
      "Alexa.ErrorResponse", "ErrorResponse",
      directive.header.correlationToken, mac,
      { type: "NO_SUCH_ENDPOINT", message: "Device not found for this user" }
    );
  }

  const meta  = await getDeviceMeta(mac);
  const caps  = JSON.parse(meta.capabilities || "[]");
  const state = await helpers.getDeviceState(mac);
  const props = helpers.toAlexaProperties(state, caps);

  return {
    context: { properties: props },
    event: {
      header: {
        namespace:          "Alexa",
        name:               "StateReport",
        messageId:          require("crypto").randomUUID(),
        correlationToken:   directive.header.correlationToken,
        payloadVersion:     "3",
      },
      endpoint: { endpointId: mac },
      payload:  {},
    },
  };
}

// ── Directive handling ────────────────────────────────────────────────────────

/**
 * Handle a control directive (TurnOn, SetBrightness, SetColor, etc.).
 *
 * Alexa sends one directive at a time (unlike Google which can batch).
 * The directive header contains the namespace and name:
 *   namespace: "Alexa.PowerController"   name: "TurnOn"
 *   namespace: "Alexa.BrightnessController"  name: "SetBrightness"
 *   … etc.
 *
 * We translate to MQTT, publish, optimistically update Firebase, and
 * respond with the new state as an Alexa Response event.
 */
async function handleDirective(uid, directive) {
  const mac = directive.endpoint.endpointId;
  const userDeviceIds = await getUserDeviceIds(uid);

  if (!userDeviceIds.includes(mac)) {
    return buildAlexaResponse(
      "Alexa.ErrorResponse", "ErrorResponse",
      directive.header.correlationToken, mac,
      { type: "NO_SUCH_ENDPOINT", message: "Device not found" }
    );
  }

  const { namespace, name } = directive.header;
  const payload = directive.payload || {};

  const mqttPayload = helpers.alexaDirectiveToMqtt(namespace, name, payload);

  if (Object.keys(mqttPayload).length === 0) {
    return buildAlexaResponse(
      "Alexa.ErrorResponse", "ErrorResponse",
      directive.header.correlationToken, mac,
      { type: "INVALID_DIRECTIVE", message: `Unsupported directive: ${namespace}.${name}` }
    );
  }

  // Publish command to MQTT broker
  await new Promise((resolve, reject) => {
    const client = getMqttClient();
    client.publish(`devices/${mac}/command`, JSON.stringify(mqttPayload), { qos: 1 }, (err) => {
      if (err) reject(err); else resolve();
    });
  });

  // Optimistically update Firebase so ReportState sees the new value immediately
  await helpers.optimisticStateUpdate(mac, mqttPayload);

  // Read back the (now-updated) state for the response context
  const meta  = await getDeviceMeta(mac);
  const caps  = JSON.parse(meta.capabilities || "[]");
  const state = await helpers.getDeviceState(mac);
  const props = helpers.toAlexaProperties(state, caps);

  return {
    context: { properties: props },
    event: {
      header: {
        namespace:        "Alexa",
        name:             "Response",
        messageId:        require("crypto").randomUUID(),
        correlationToken: directive.header.correlationToken,
        payloadVersion:   "3",
      },
      endpoint: { endpointId: mac },
      payload:  {},
    },
  };
}

// ── Main Cloud Function export ────────────────────────────────────────────────

/**
 * Alexa Smart Home Cloud Function.
 *
 * Alexa POSTs JSON bodies with this structure:
 *   directive.header.namespace  — "Alexa.Discovery", "Alexa.PowerController", etc.
 *   directive.header.name       — "Discover", "TurnOn", "ReportState", etc.
 *   directive.endpoint.endpointId — MAC address of the target device
 *   directive.payload           — command-specific parameters
 *
 * The access_token is in:
 *   directive.endpoint.scope.token   (for control directives)
 *   directive.payload.scope.token    (for Discovery directives)
 *
 * Note: Alexa does not use an Authorization header like Google — the token
 * is embedded in the request body.
 */
async function alexaSmartHomeHandler(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "Method not allowed" });
  }

  const { directive } = req.body;
  if (!directive) {
    return res.status(400).json({ error: "No directive in request body" });
  }

  // Extract access token from the appropriate location in the directive
  const token = directive.endpoint?.scope?.token
      || directive.payload?.scope?.token;

  // Validate token using the same OAuth token store as Google
  const uid = await validateBearerToken(`Bearer ${token}`);
  if (!uid) {
    return res.status(401).json({
      event: {
        header: { namespace: "Alexa.Authorization", name: "ErrorResponse", payloadVersion: "3" },
        payload: { type: "INVALID_AUTHORIZATION_CREDENTIAL", message: "Invalid access token" },
      },
    });
  }

  const { namespace, name } = directive.header;
  let response;

  try {
    if (namespace === "Alexa.Discovery" && name === "Discover") {
      response = await handleDiscovery(uid, directive);
    } else if (namespace === "Alexa" && name === "ReportState") {
      response = await handleReportState(uid, directive);
    } else {
      // All control directives (PowerController, BrightnessController, etc.)
      response = await handleDirective(uid, directive);
    }
  } catch (err) {
    console.error(`[Alexa] ${namespace}.${name} error:`, err);
    return res.status(500).json({
      event: {
        header: { namespace: "Alexa.ErrorResponse", name: "ErrorResponse", payloadVersion: "3" },
        payload: { type: "INTERNAL_ERROR", message: err.message },
      },
    });
  }

  return res.json(response);
}

module.exports = { alexaSmartHomeHandler };
