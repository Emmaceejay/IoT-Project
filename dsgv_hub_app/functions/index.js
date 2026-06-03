const functions = require("firebase-functions");
const admin = require("firebase-admin");
const cors = require("cors")({ origin: true });

admin.initializeApp();
const db = admin.database();

// ── Helpers ───────────────────────────────────────────────────────────────────

const DEVICE_ID_RE   = /^[A-Fa-f0-9]{12}$/;
const AUTH_TOKEN_RE  = /^[A-Fa-f0-9]{32}$/;

// Factory broker shipped in every firmware binary.
// Must match MQTT_CLOUD_HOST in dsgv_config.h and factoryDefault in mqtt_config.dart.
const FACTORY_CONFIG = {
  broker_host: "mqtt.dsgv.io",
  broker_port: 8883,
  broker_tls: true,
  broker_username: "",
  broker_password: "",
};

/**
 * Constant-time string comparison to prevent timing attacks on auth tokens.
 */
function safeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

// ── registerDevice ────────────────────────────────────────────────────────────
// Called by the Flutter app immediately after BLE provisioning succeeds.
// Stores the device's auth token in the private registry and seeds a factory
// broker config for it. Idempotent — safe to call more than once.

exports.registerDevice = functions.https.onRequest((req, res) => {
  cors(req, res, async () => {
    if (req.method !== "POST") {
      return res.status(405).json({ error: "Method not allowed" });
    }

    const { device_id, auth_token } = req.body || {};

    if (!device_id || !auth_token) {
      return res.status(400).json({ error: "Missing device_id or auth_token" });
    }
    if (!DEVICE_ID_RE.test(device_id)) {
      return res.status(400).json({ error: "device_id must be 12 hex characters (WiFi MAC)" });
    }
    if (!AUTH_TOKEN_RE.test(auth_token)) {
      return res.status(400).json({ error: "auth_token must be 32 hex characters" });
    }

    const deviceId = device_id.toUpperCase();
    const token    = auth_token.toUpperCase();

    // If already registered keep existing token (prevents token hijacking via re-registration)
    const existing = await db.ref(`device_registry/${deviceId}`).once("value");
    if (existing.exists()) {
      await db.ref(`device_registry/${deviceId}/last_seen`).set(Date.now());
      return res.json({ success: true, already_registered: true });
    }

    // Write registry entry — only Cloud Functions can read this path (rules: false)
    await db.ref(`device_registry/${deviceId}`).set({
      auth_token: token,
      registered_at: Date.now(),
      last_seen: Date.now(),
    });

    // Seed factory config only if none exists yet
    const configSnap = await db.ref(`device_configs/${deviceId}`).once("value");
    if (!configSnap.exists()) {
      await db.ref(`device_configs/${deviceId}`).set({
        ...FACTORY_CONFIG,
        is_factory: true,
        updated_at: Date.now(),
      });
    }

    return res.json({ success: true });
  });
});

// ── getDeviceConfig ───────────────────────────────────────────────────────────
// Called by ESP32 firmware over HTTPS on every boot after WiFi connects.
// Returns the broker config for the requesting device.
// Auth: device_id + auth_token (token verified against private registry).

exports.getDeviceConfig = functions.https.onRequest((req, res) => {
  cors(req, res, async () => {
    if (req.method !== "POST") {
      return res.status(405).json({ error: "Method not allowed" });
    }

    const { device_id, auth_token } = req.body || {};

    if (!device_id || !auth_token) {
      return res.status(400).json({ error: "Missing fields" });
    }

    const deviceId = device_id.toUpperCase();
    const token    = auth_token.toUpperCase();

    // Verify auth token against private registry
    const registrySnap = await db.ref(`device_registry/${deviceId}`).once("value");
    if (!registrySnap.exists()) {
      // Return factory config to un-registered devices so they still work
      // (handles the case where the app hasn't registered the device yet)
      return res.json(FACTORY_CONFIG);
    }

    const registry = registrySnap.val();
    if (!safeEqual(registry.auth_token, token)) {
      return res.status(401).json({ error: "Unauthorized" });
    }

    // Update last_seen non-blocking
    db.ref(`device_registry/${deviceId}/last_seen`).set(Date.now());

    // Return broker config
    const configSnap = await db.ref(`device_configs/${deviceId}`).once("value");
    if (!configSnap.exists()) {
      return res.json(FACTORY_CONFIG);
    }

    const cfg = configSnap.val();
    return res.json({
      broker_host:      cfg.broker_host     || FACTORY_CONFIG.broker_host,
      broker_port:      cfg.broker_port     || FACTORY_CONFIG.broker_port,
      broker_tls:       cfg.broker_tls      !== false,
      broker_username:  cfg.broker_username || "",
      broker_password:  cfg.broker_password || "",
    });
  });
});

// ── updateDeviceConfig ────────────────────────────────────────────────────────
// Called by the Flutter app when the user pushes a new broker to a device.
// Auth: device_id + auth_token (app already holds the token from provisioning).

exports.updateDeviceConfig = functions.https.onRequest((req, res) => {
  cors(req, res, async () => {
    if (req.method !== "POST") {
      return res.status(405).json({ error: "Method not allowed" });
    }

    const {
      device_id, auth_token,
      broker_host, broker_port, broker_tls,
      broker_username, broker_password,
    } = req.body || {};

    if (!device_id || !auth_token) {
      return res.status(400).json({ error: "Missing device_id or auth_token" });
    }

    const deviceId = device_id.toUpperCase();
    const token    = auth_token.toUpperCase();

    const registrySnap = await db.ref(`device_registry/${deviceId}`).once("value");
    if (!registrySnap.exists() || !safeEqual(registrySnap.val().auth_token, token)) {
      return res.status(401).json({ error: "Unauthorized" });
    }

    await db.ref(`device_configs/${deviceId}`).update({
      broker_host:      broker_host     || FACTORY_CONFIG.broker_host,
      broker_port:      broker_port     || FACTORY_CONFIG.broker_port,
      broker_tls:       broker_tls      !== false,
      broker_username:  broker_username || "",
      broker_password:  broker_password || "",
      is_factory: false,
      updated_at: Date.now(),
    });

    return res.json({ success: true });
  });
});

// ── revertDeviceToFactory ─────────────────────────────────────────────────────
// Called by the Flutter app when the user taps "Restore factory broker".
// Resets the device's config to the factory broker in Firebase.
// Auth: device_id + auth_token.

exports.revertDeviceToFactory = functions.https.onRequest((req, res) => {
  cors(req, res, async () => {
    if (req.method !== "POST") {
      return res.status(405).json({ error: "Method not allowed" });
    }

    const { device_id, auth_token } = req.body || {};

    if (!device_id || !auth_token) {
      return res.status(400).json({ error: "Missing device_id or auth_token" });
    }

    const deviceId = device_id.toUpperCase();
    const token    = auth_token.toUpperCase();

    const registrySnap = await db.ref(`device_registry/${deviceId}`).once("value");
    if (!registrySnap.exists() || !safeEqual(registrySnap.val().auth_token, token)) {
      return res.status(401).json({ error: "Unauthorized" });
    }

    await db.ref(`device_configs/${deviceId}`).update({
      ...FACTORY_CONFIG,
      is_factory: true,
      updated_at: Date.now(),
    });

    return res.json({ success: true });
  });
});
