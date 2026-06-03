/**
 * smarthome_google.js — Google Smart Home Cloud-to-Cloud Fulfillment.
 *
 * Google Home calls this Cloud Function whenever:
 *   • A user links their DSGV account (SYNC intent)
 *   • Google needs the current state of devices (QUERY intent)
 *   • The user gives a voice command (EXECUTE intent)
 *   • The user unlinks their account (DISCONNECT intent)
 *
 * Setup checklist:
 *   1. Create a Smart Home project in Google Cloud Console / Actions on Google.
 *   2. Set the fulfillment URL to:
 *        https://us-central1-YOUR_PROJECT_ID.cloudfunctions.net/googleSmartHome
 *   3. Configure account linking (OAuth 2.0, Authorization Code flow):
 *        Authorization URL: …/oauth/authorize
 *        Token URL:         …/oauth/token
 *        Client ID:         value of GOOGLE_CLIENT_ID in your config
 *        Scopes:            dsgv.devices.control
 *   4. In the Google Home Developer Console, enable "Request Sync" so Google
 *      is notified when devices are added/removed.
 *
 * Reference: https://developers.home.google.com/cloud-to-cloud/guides
 */

const admin  = require("firebase-admin");
const mqtt   = require("mqtt");
const { validateBearerToken } = require("./oauth");
const helpers = require("./state_helpers");

const db = admin.database();

// ── MQTT client (module-level for connection reuse across warm invocations) ───
//
// Cloud Functions are stateless but the runtime may reuse the same Node.js
// process for multiple invocations (called "warm start"). We keep the MQTT
// client at module scope so reconnecting on every EXECUTE call is avoided.
// The client will reconnect automatically if the broker drops the connection.
//
// Replace the placeholder broker URL with your real EMQX/Mosquitto address.
// Use environment variables or Functions config — never hardcode credentials.
let mqttClient = null;

function getMqttClient() {
  if (mqttClient && mqttClient.connected) return mqttClient;

  const { functions } = require("firebase-functions");
  const cfg = functions.config();
  const brokerUrl = cfg.mqtt?.url      || process.env.MQTT_BROKER_URL  || "mqtts://mqtt.dsgv.io:8883";
  const username  = cfg.mqtt?.username || process.env.MQTT_USERNAME     || "";
  const password  = cfg.mqtt?.password || process.env.MQTT_PASSWORD     || "";

  mqttClient = mqtt.connect(brokerUrl, {
    username,
    password,
    keepalive:      30,
    reconnectPeriod: 2000,
    connectTimeout:  5000,
    rejectUnauthorized: true,
  });

  mqttClient.on("error", (err) => {
    console.error("[Google] MQTT error:", err.message);
  });

  return mqttClient;
}

// ── Device list helper ────────────────────────────────────────────────────────

/**
 * Fetch the list of device IDs registered to this user.
 * Reads from user_devices/{uid} which is written when the user links
 * a device to their account via linkDeviceToUser Cloud Function.
 */
async function getUserDeviceIds(uid) {
  const snap = await db.ref(`user_devices/${uid}`).once("value");
  if (!snap.exists()) return [];
  return Object.keys(snap.val());
}

/**
 * Fetch device registry metadata (capabilities, name) for a device.
 * Reads from device_registry/{mac} and device_configs/{mac}.
 */
async function getDeviceMeta(deviceId) {
  const [regSnap, cfgSnap] = await Promise.all([
    db.ref(`device_registry/${deviceId}`).once("value"),
    db.ref(`device_configs/${deviceId}`).once("value"),
  ]);
  return {
    registry: regSnap.val() || {},
    config:   cfgSnap.val() || {},
  };
}

// ── Intent handlers ───────────────────────────────────────────────────────────

/**
 * SYNC intent — Google asks "what devices does this user have?".
 *
 * Called when:
 *   • The user links their account for the first time.
 *   • The user asks Google to "sync devices".
 *   • You call the Request Sync API to notify Google of changes.
 *
 * Response: a list of device objects with their types, traits, and attributes.
 */
async function handleSync(uid, requestId) {
  const deviceIds = await getUserDeviceIds(uid);

  // Build device objects for each registered device
  const devices = await Promise.all(deviceIds.map(async (mac) => {
    const meta = await getDeviceMeta(mac);
    const caps = JSON.parse(meta.registry.capabilities || "[]");
    const { type, traits, attributes } = helpers.googleDeviceProfile(caps);

    return {
      id: mac,
      type,
      traits,
      attributes,
      name: {
        // defaultNames: suggested names for auto-detection
        defaultNames: [`DSGV ${meta.registry.device_type || "Device"}`],
        // name: the user's assigned name (stored in device_registry)
        name: meta.registry.device_name || mac,
      },
      // willReportState: we proactively send state via Report State API (future)
      willReportState: false,
      deviceInfo: {
        manufacturer: "DSGV",
        model:        meta.registry.device_type || "smart-device",
        swVersion:    meta.registry.firmware_version || "1.0.0",
      },
    };
  }));

  return {
    requestId,
    payload: {
      agentUserId: uid,
      devices,
    },
  };
}

/**
 * QUERY intent — Google asks "what is the current state of these devices?".
 *
 * Called when:
 *   • User asks "Hey Google, is the kitchen light on?".
 *   • Google needs to read state before executing a command.
 *
 * We read from the Firebase device_states mirror (kept current by the
 * MQTT state bridge process).
 */
async function handleQuery(uid, requestId, devices) {
  const deviceIds = await getUserDeviceIds(uid);
  const devicesOut = {};

  for (const { id } of devices) {
    // Security: only return state for devices the user actually owns
    if (!deviceIds.includes(id)) {
      devicesOut[id] = { online: false, status: "ERROR", errorCode: "deviceNotFound" };
      continue;
    }

    const meta  = await getDeviceMeta(id);
    const caps  = JSON.parse(meta.registry.capabilities || "[]");
    const state = await helpers.getDeviceState(id);

    devicesOut[id] = helpers.toGoogleState(state, caps);
  }

  return {
    requestId,
    payload: { devices: devicesOut },
  };
}

/**
 * EXECUTE intent — Google delivers a command to control a device.
 *
 * Called when:
 *   • "Hey Google, turn on the kitchen light."
 *   • "Hey Google, set the bedroom brightness to 50%."
 *   • Automations and routines trigger device actions.
 *
 * We:
 *   1. Translate the Google command to an MQTT payload.
 *   2. Publish to devices/{mac}/command on the MQTT broker.
 *   3. Optimistically update the Firebase state mirror.
 *   4. Return SUCCESS to Google immediately (don't wait for device ACK).
 */
async function handleExecute(uid, requestId, commands) {
  const userDeviceIds = await getUserDeviceIds(uid);
  const results = [];

  const mqttPub = (topic, payload) => new Promise((resolve, reject) => {
    const client = getMqttClient();
    client.publish(topic, JSON.stringify(payload), { qos: 1 }, (err) => {
      if (err) reject(err); else resolve();
    });
  });

  for (const command of commands) {
    const successIds = [];
    const failedIds  = [];

    for (const device of command.devices) {
      const mac = device.id;

      // Security: only control devices owned by the authenticated user
      if (!userDeviceIds.includes(mac)) {
        failedIds.push(mac);
        continue;
      }

      // There can be multiple execution objects per command (e.g. set colour + set brightness)
      for (const execution of command.execution) {
        const mqttPayload = helpers.googleCommandToMqtt(execution.command, execution.params);

        if (Object.keys(mqttPayload).length === 0) {
          console.warn(`[Google] Unsupported command: ${execution.command}`);
          continue;
        }

        try {
          // Publish the command to the device via MQTT broker
          await mqttPub(`devices/${mac}/command`, mqttPayload);

          // Optimistically update Firebase state so QUERY sees the new state immediately
          await helpers.optimisticStateUpdate(mac, mqttPayload);

          successIds.push(mac);
        } catch (err) {
          console.error(`[Google] MQTT publish failed for ${mac}:`, err.message);
          failedIds.push(mac);
        }
      }
    }

    if (successIds.length > 0) {
      results.push({ ids: successIds, status: "SUCCESS" });
    }
    if (failedIds.length > 0) {
      results.push({ ids: failedIds, status: "ERROR", errorCode: "hardError" });
    }
  }

  return {
    requestId,
    payload: { commands: results },
  };
}

/**
 * DISCONNECT intent — user has unlinked their DSGV account from Google Home.
 *
 * We remove the user_devices mapping so Google no longer has access.
 * We do NOT delete the devices themselves — only the ownership link.
 */
async function handleDisconnect(uid, requestId) {
  await db.ref(`user_devices/${uid}`).remove();
  // Optionally revoke OAuth tokens here — for now we let them expire naturally
  return { requestId, payload: {} };
}

// ── Main Cloud Function export ─────────────────────────────────────────────────

/**
 * Google Smart Home Cloud Function.
 *
 * Google POSTs a JSON body to this endpoint with:
 *   headers.authorization = "Bearer <access_token>"
 *   body.requestId        = request correlation ID (echo back in response)
 *   body.inputs[0].intent = "action.devices.SYNC" | ".QUERY" | ".EXECUTE" | ".DISCONNECT"
 */
async function googleSmartHomeHandler(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "Method not allowed" });
  }

  // Validate the OAuth access token — this is how we know which user is calling
  const uid = await validateBearerToken(req.headers.authorization);
  if (!uid) {
    return res.status(401).json({ error: "Unauthorized" });
  }

  const { requestId, inputs } = req.body;
  if (!requestId || !inputs || !inputs[0]) {
    return res.status(400).json({ error: "Malformed request" });
  }

  const intent = inputs[0].intent;
  let response;

  try {
    switch (intent) {
      case "action.devices.SYNC":
        response = await handleSync(uid, requestId);
        break;

      case "action.devices.QUERY":
        response = await handleQuery(uid, requestId, inputs[0].payload.devices);
        break;

      case "action.devices.EXECUTE":
        response = await handleExecute(uid, requestId, inputs[0].payload.commands);
        break;

      case "action.devices.DISCONNECT":
        response = await handleDisconnect(uid, requestId);
        break;

      default:
        return res.status(400).json({ error: `Unknown intent: ${intent}` });
    }
  } catch (err) {
    console.error(`[Google] ${intent} error:`, err);
    return res.status(500).json({ error: "Internal server error" });
  }

  return res.json(response);
}

module.exports = { googleSmartHomeHandler };
