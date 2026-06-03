/**
 * mqtt_bridge/bridge.js — MQTT → Firebase Realtime Database State Bridge.
 *
 * This is a standalone long-running Node.js process (NOT a Cloud Function).
 * Deploy it on the same VPS as your MQTT broker, or any always-on server.
 *
 * What it does:
 *   Subscribes to all DSGV device telemetry and status topics on the MQTT
 *   broker. Each incoming message is written to the Firebase Realtime Database
 *   under "device_states/{mac}". This creates a real-time state mirror that
 *   the Google Home and Alexa Cloud Functions can read synchronously when a
 *   QUERY / ReportState request arrives.
 *
 * Why not a Cloud Function?
 *   Cloud Functions are stateless and have execution time limits. Maintaining
 *   a persistent MQTT subscription requires a long-lived process.
 *
 * --- Deployment ---
 *
 *   1. Copy this file and package.json to the VPS where your MQTT broker runs.
 *   2. Run: npm install
 *   3. Set environment variables (or use a .env file + dotenv):
 *        MQTT_BROKER_URL=mqtts://mqtt.dsgv.io:8883
 *        MQTT_USERNAME=bridge_user
 *        MQTT_PASSWORD=bridge_password
 *        GOOGLE_APPLICATION_CREDENTIALS=/path/to/firebase-service-account.json
 *   4. Run as a systemd service (example unit file at the bottom of this file).
 *
 * --- Monitored MQTT topics ---
 *
 *   devices/+/telemetry   — full state snapshot from device (every 30 s + on change)
 *   devices/+/status      — "online" or "offline" (LWT)
 *
 * --- Firebase data written ---
 *
 *   device_states/{MAC}/power         ← from telemetry.power
 *   device_states/{MAC}/brightness    ← from telemetry.brightness
 *   device_states/{MAC}/color_temp    ← from telemetry.color_temp
 *   device_states/{MAC}/red/green/blue← from telemetry (RGB)
 *   device_states/{MAC}/current_temp  ← from telemetry.temperature
 *   device_states/{MAC}/humidity      ← from telemetry.humidity
 *   device_states/{MAC}/motion        ← from telemetry.motion
 *   device_states/{MAC}/contact       ← from telemetry.contact
 *   device_states/{MAC}/target_temp   ← from telemetry.target_temp
 *   device_states/{MAC}/mode          ← from telemetry.mode
 *   device_states/{MAC}/online        ← true / false (from status topic)
 *   device_states/{MAC}/last_updated  ← timestamp (ms)
 */

const mqtt  = require("mqtt");
const admin = require("firebase-admin");

// ── Firebase Admin SDK initialisation ────────────────────────────────────────
// GOOGLE_APPLICATION_CREDENTIALS must point to a Firebase service account JSON.
// Download from: Firebase Console → Project Settings → Service Accounts → Generate key.
admin.initializeApp();
const db = admin.database();

// ── MQTT connection ───────────────────────────────────────────────────────────
const BROKER_URL = process.env.MQTT_BROKER_URL || "mqtts://mqtt.dsgv.io:8883";
const USERNAME   = process.env.MQTT_USERNAME   || "";
const PASSWORD   = process.env.MQTT_PASSWORD   || "";

console.log(`[Bridge] Connecting to MQTT broker: ${BROKER_URL}`);

const client = mqtt.connect(BROKER_URL, {
  username:       USERNAME,
  password:       PASSWORD,
  clientId:       `dsgv_bridge_${Math.random().toString(16).slice(2, 8)}`,
  keepalive:      60,
  reconnectPeriod: 5000,   // retry every 5 s on disconnect
  connectTimeout:  10000,
  rejectUnauthorized: true, // enforce TLS certificate validation
  will: {
    // LWT: if the bridge disconnects unexpectedly, log it on a debug topic
    topic:   "bridge/status",
    payload: "offline",
    qos:     1,
    retain:  true,
  },
});

// ── Event handlers ────────────────────────────────────────────────────────────

client.on("connect", () => {
  console.log("[Bridge] Connected to MQTT broker.");
  client.publish("bridge/status", "online", { qos: 1, retain: true });

  // Subscribe to telemetry from ALL devices using the MQTT wildcard '+'.
  // '+' matches exactly one topic level. "devices/+/telemetry" matches:
  //   devices/A1B2C3D4E5F6/telemetry  ✓
  //   devices/A1B2C3D4E5F6/            ✗ (wrong depth)
  client.subscribe(["devices/+/telemetry", "devices/+/status"], { qos: 1 }, (err) => {
    if (err) console.error("[Bridge] Subscribe error:", err);
    else console.log("[Bridge] Subscribed to devices/+/telemetry and devices/+/status");
  });
});

client.on("reconnect", () => {
  console.log("[Bridge] Reconnecting to MQTT broker…");
});

client.on("error", (err) => {
  console.error("[Bridge] MQTT error:", err.message);
});

client.on("offline", () => {
  console.warn("[Bridge] MQTT client is offline.");
});

// ── Message processing ────────────────────────────────────────────────────────

client.on("message", async (topic, payload) => {
  // Parse the MAC address from the topic: "devices/<MAC>/telemetry"
  // topic.split('/') → ["devices", "A1B2C3D4E5F6", "telemetry"]
  const parts = topic.split("/");
  if (parts.length !== 3 || parts[0] !== "devices") return;

  const mac  = parts[1].toUpperCase();
  const type = parts[2]; // "telemetry" or "status"

  if (type === "telemetry") {
    // Parse the JSON telemetry payload from the device
    let state;
    try {
      state = JSON.parse(payload.toString());
    } catch (err) {
      console.error(`[Bridge] Failed to parse telemetry from ${mac}:`, err.message);
      return;
    }

    // Sanitise: remove fields we don't want in the state mirror.
    // "device_id" and "name" are identity fields, not state.
    const { device_id, name, capabilities, firmware_version, local_ip, ...stateFields } = state;

    // Write to Firebase Realtime Database using update() which merges the
    // new fields without overwriting fields not present in this payload.
    // For example, if a telemetry message contains only { power, brightness },
    // the existing color_temp field in Firebase is preserved.
    try {
      await db.ref(`device_states/${mac}`).update({
        ...stateFields,
        online:       true,
        last_updated: Date.now(),
      });
    } catch (err) {
      console.error(`[Bridge] Firebase write failed for ${mac}:`, err.message);
    }

  } else if (type === "status") {
    // The status topic carries the LWT payload: "online" or "offline"
    const statusStr = payload.toString().trim().toLowerCase();
    const isOnline  = statusStr === "online";

    try {
      await db.ref(`device_states/${mac}`).update({
        online:       isOnline,
        last_updated: Date.now(),
      });
      console.log(`[Bridge] ${mac} is now ${statusStr}`);
    } catch (err) {
      console.error(`[Bridge] Firebase status write failed for ${mac}:`, err.message);
    }
  }
});

// ── Graceful shutdown ─────────────────────────────────────────────────────────
// When the process receives SIGTERM (e.g., from systemd stop), cleanly
// disconnect from MQTT and flush pending Firebase writes.

process.on("SIGTERM", () => {
  console.log("[Bridge] SIGTERM received — shutting down gracefully.");
  client.end(false, {}, () => {
    console.log("[Bridge] MQTT disconnected. Exiting.");
    process.exit(0);
  });
});

process.on("SIGINT", () => {
  console.log("[Bridge] SIGINT received — shutting down.");
  client.end(false, {}, () => process.exit(0));
});

/*
──────────────────────────────────────────────────────────────────────────────
 systemd unit file — save as /etc/systemd/system/dsgv-bridge.service
──────────────────────────────────────────────────────────────────────────────

[Unit]
Description=DSGV Hub MQTT→Firebase State Bridge
After=network.target mosquitto.service

[Service]
Type=simple
User=dsgv
WorkingDirectory=/opt/dsgv-bridge
ExecStart=/usr/bin/node bridge.js
Restart=always
RestartSec=5
EnvironmentFile=/opt/dsgv-bridge/.env

[Install]
WantedBy=multi-user.target

──────────────────────────────────────────────────────────────────────────────
 .env file — /opt/dsgv-bridge/.env
──────────────────────────────────────────────────────────────────────────────

MQTT_BROKER_URL=mqtts://mqtt.dsgv.io:8883
MQTT_USERNAME=bridge_user
MQTT_PASSWORD=YOUR_BRIDGE_PASSWORD
GOOGLE_APPLICATION_CREDENTIALS=/opt/dsgv-bridge/firebase-service-account.json

──────────────────────────────────────────────────────────────────────────────
 To deploy:
   sudo systemctl daemon-reload
   sudo systemctl enable dsgv-bridge
   sudo systemctl start dsgv-bridge
   sudo journalctl -u dsgv-bridge -f   # tail logs
──────────────────────────────────────────────────────────────────────────────
*/
