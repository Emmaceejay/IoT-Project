import { getRecord, putRecord, updateRecord } from "./store.js";
import { safeEqual } from "./safeEqual.js";

/**
 * index.js — DSGV Hub device-config gateway.
 *
 * Cloudflare Workers replacement for dsgv_hub_app/functions/index.js
 * (Firebase Cloud Functions, which requires the Blaze plan to deploy at all)
 * — and its data store (Firebase Realtime Database) too, now on Workers KV
 * instead, so this has zero external dependencies: no Firebase project, no
 * service account, nothing but Cloudflare's own free tier. Route logic and
 * auth-token validation are a straight port of the old Cloud Functions —
 * only the transport (fetch-based routing) and storage (KV via store.js,
 * instead of admin.database()) differ. Keep both files in sync by hand if
 * either changes.
 */

const DEVICE_ID_RE  = /^[A-Fa-f0-9]{12}$/;
const AUTH_TOKEN_RE = /^[A-Fa-f0-9]{32}$/;

// Factory broker shipped in every firmware binary.
// Host/port/tls must match MQTT_CLOUD_HOST/PORT/TLS in dsgv_config.h and
// factoryDefault in mqtt_config.dart.
const FACTORY_CONFIG_BASE = {
  broker_host: "ebcc0da5f0064096845e7234ab714b7b.s1.eu.hivemq.cloud",
  broker_port: 8883,
  broker_tls: true,
};

// Broker credentials come from Wrangler secrets, never from source — set
// with `wrangler secret put MQTT_BROKER_USERNAME` (and ..._PASSWORD).
function getFactoryConfig(env) {
  return {
    ...FACTORY_CONFIG_BASE,
    broker_username: env.MQTT_BROKER_USERNAME || "",
    broker_password: env.MQTT_BROKER_PASSWORD || "",
  };
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
    },
  });
}

async function readJson(request) {
  try {
    return await request.json();
  } catch {
    return {};
  }
}

const registryKey = (deviceId) => `device_registry:${deviceId}`;
const configKey   = (deviceId) => `device_configs:${deviceId}`;

// ── registerDevice ────────────────────────────────────────────────────────────
// Called by the Flutter app immediately after BLE provisioning succeeds.
// Stores the device's auth token in the private registry and seeds a factory
// broker config for it. Idempotent — safe to call more than once.
async function handleRegisterDevice(request, env) {
  const { device_id, auth_token } = await readJson(request);

  if (!device_id || !auth_token) {
    return json({ error: "Missing device_id or auth_token" }, 400);
  }
  if (!DEVICE_ID_RE.test(device_id)) {
    return json({ error: "device_id must be 12 hex characters (WiFi MAC)" }, 400);
  }
  if (!AUTH_TOKEN_RE.test(auth_token)) {
    return json({ error: "auth_token must be 32 hex characters" }, 400);
  }

  const deviceId = device_id.toUpperCase();
  const token    = auth_token.toUpperCase();

  // If already registered keep existing token (prevents token hijacking via re-registration)
  const existing = await getRecord(env, registryKey(deviceId));
  if (existing) {
    await updateRecord(env, registryKey(deviceId), { last_seen: Date.now() });
    return json({ success: true, already_registered: true });
  }

  await putRecord(env, registryKey(deviceId), {
    auth_token: token,
    registered_at: Date.now(),
    last_seen: Date.now(),
  });

  // Seed factory config only if none exists yet
  const existingConfig = await getRecord(env, configKey(deviceId));
  if (!existingConfig) {
    await putRecord(env, configKey(deviceId), {
      ...getFactoryConfig(env),
      is_factory: true,
      updated_at: Date.now(),
    });
  }

  return json({ success: true });
}

// ── getDeviceConfig ───────────────────────────────────────────────────────────
// Called by ESP32 firmware over HTTPS on every boot after WiFi connects.
// Returns the broker config for the requesting device.
// Auth: device_id + auth_token (token verified against private registry).
//
// Does NOT touch last_seen — that's the one write that would scale with how
// often devices boot, and KV's free tier caps writes at 1,000/day. It's
// purely informational and never read back by app or firmware, so it's only
// recorded once in registerDevice (a rare, one-time write per device).
async function handleGetDeviceConfig(request, env) {
  const { device_id, auth_token } = await readJson(request);

  if (!device_id || !auth_token) {
    return json({ error: "Missing fields" }, 400);
  }

  const deviceId = device_id.toUpperCase();
  const token    = auth_token.toUpperCase();
  const factory  = getFactoryConfig(env);

  // Verify auth token against private registry
  const registry = await getRecord(env, registryKey(deviceId));
  if (!registry) {
    // Return factory config to un-registered devices so they still work
    // (handles the case where the app hasn't registered the device yet)
    return json(factory);
  }
  if (!safeEqual(registry.auth_token, token)) {
    return json({ error: "Unauthorized" }, 401);
  }

  const cfg = await getRecord(env, configKey(deviceId));
  if (!cfg) {
    return json(factory);
  }

  return json({
    broker_host:      cfg.broker_host     || factory.broker_host,
    broker_port:      cfg.broker_port     || factory.broker_port,
    broker_tls:       cfg.broker_tls      !== false,
    broker_username:  cfg.broker_username || "",
    broker_password:  cfg.broker_password || "",
  });
}

// ── updateDeviceConfig ────────────────────────────────────────────────────────
// Called by the Flutter app when the user pushes a new broker to a device.
// Auth: device_id + auth_token (app already holds the token from provisioning).
async function handleUpdateDeviceConfig(request, env) {
  const {
    device_id, auth_token,
    broker_host, broker_port, broker_tls,
    broker_username, broker_password,
  } = await readJson(request);

  if (!device_id || !auth_token) {
    return json({ error: "Missing device_id or auth_token" }, 400);
  }

  const deviceId = device_id.toUpperCase();
  const token    = auth_token.toUpperCase();
  const factory  = getFactoryConfig(env);

  const registry = await getRecord(env, registryKey(deviceId));
  if (!registry || !safeEqual(registry.auth_token, token)) {
    return json({ error: "Unauthorized" }, 401);
  }

  await updateRecord(env, configKey(deviceId), {
    broker_host:      broker_host     || factory.broker_host,
    broker_port:      broker_port     || factory.broker_port,
    broker_tls:       broker_tls      !== false,
    broker_username:  broker_username || "",
    broker_password:  broker_password || "",
    is_factory: false,
    updated_at: Date.now(),
  });

  return json({ success: true });
}

// ── revertDeviceToFactory ─────────────────────────────────────────────────────
// Called by the Flutter app when the user taps "Restore factory broker".
// Resets the device's config to the factory broker.
// Auth: device_id + auth_token.
async function handleRevertDeviceToFactory(request, env) {
  const { device_id, auth_token } = await readJson(request);

  if (!device_id || !auth_token) {
    return json({ error: "Missing device_id or auth_token" }, 400);
  }

  const deviceId = device_id.toUpperCase();
  const token    = auth_token.toUpperCase();

  const registry = await getRecord(env, registryKey(deviceId));
  if (!registry || !safeEqual(registry.auth_token, token)) {
    return json({ error: "Unauthorized" }, 401);
  }

  await updateRecord(env, configKey(deviceId), {
    ...getFactoryConfig(env),
    is_factory: true,
    updated_at: Date.now(),
  });

  return json({ success: true });
}

// ── Router ───────────────────────────────────────────────────────────────────

const ROUTES = {
  "/registerDevice":        handleRegisterDevice,
  "/getDeviceConfig":       handleGetDeviceConfig,
  "/updateDeviceConfig":    handleUpdateDeviceConfig,
  "/revertDeviceToFactory": handleRevertDeviceToFactory,
};

export default {
  async fetch(request, env) {
    // Manual CORS handling — Workers has no built-in equivalent of the
    // `cors` npm middleware the old Cloud Functions used.
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type",
        },
      });
    }

    if (request.method !== "POST") {
      return json({ error: "Method not allowed" }, 405);
    }

    const { pathname } = new URL(request.url);
    const handler = ROUTES[pathname];
    if (!handler) {
      return json({ error: "Not found" }, 404);
    }

    try {
      return await handler(request, env);
    } catch (err) {
      return json({ error: "Internal error", detail: String(err) }, 500);
    }
  },
};
