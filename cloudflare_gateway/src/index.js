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

// Single KV key holding the whole firmware manifest, keyed by device_type —
// mirrors the shape dsgv_hub_app's FirmwareManifest.fromJson() expects.
// One key (not one-per-device) keeps publishFirmware a single read-merge-write,
// same pattern as store.js's updateRecord but nested one level deeper.
const FIRMWARE_MANIFEST_KEY = "firmware_manifest";

// Must match CONFIG_DSGV_DEVICE_TYPE values / firmware_manifest.json's old keys.
const KNOWN_DEVICE_TYPES = new Set([
  "1gang_switch", "2gang_switch", "3gang_switch", "4gang_switch",
  "dimmer", "colour_temp", "rgb_light",
  "temp_sensor", "motion_sensor", "contact_sensor", "thermostat",
]);

// 4MB cap — generous above the largest OTA partition slot (3MB on the 8MB
// layout, ~1.9MB on 4MB) any device in this fleet actually has, just a sanity
// ceiling against accidental wrong-file uploads, not a hard product limit.
const MAX_FIRMWARE_BYTES = 4 * 1024 * 1024;

function toHex(buf) {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

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

  // Verify auth token against private registry.
  //
  // SECURITY: an unregistered device_id must NEVER get broker_username/
  // broker_password back — device_id is just a 12-hex WiFi MAC, so almost
  // any guessed value is "unregistered", and an unauthenticated caller could
  // otherwise harvest the live broker credential with a single POST. Only
  // broker_host/port/tls (already public — compiled into every firmware
  // binary) go out on this path; credentials require a registry match below.
  const registry = await getRecord(env, registryKey(deviceId));
  if (!registry) {
    return json({
      broker_host: factory.broker_host,
      broker_port: factory.broker_port,
      broker_tls:  factory.broker_tls,
      broker_username: "",
      broker_password: "",
    });
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

// ── publishFirmware ──────────────────────────────────────────────────────────
// Called by the admin/publish.html page (not by the app or a device). Accepts
// a multipart/form-data upload: device_type, version, notes (optional), and
// the .bin file itself. Stores the binary as a raw value in Workers KV
// (deliberately not R2 — R2 requires a credit card on file to enable, even
// within its free tier, which breaks the "genuinely free, no card" bar this
// whole project holds itself to; KV's 25MiB-per-value limit comfortably
// covers these binaries, which top out around 3MB per check_binary_size.py's
// OTA partition limits). Computes SHA-256 server-side (never trusts a
// client-supplied hash for this — the whole point is this becomes the value
// every device verifies against), and records the new current version for
// that device type in the firmware manifest.
//
// Auth: X-Admin-Key header, checked with the same constant-time safeEqual()
// every other credential check in this file uses. This is a different,
// higher-privilege secret than any device's auth_token — anyone who can
// publish here controls what code every device in the fleet will run.
async function handlePublishFirmware(request, env) {
  const adminKey = request.headers.get("X-Admin-Key") || "";
  if (!env.ADMIN_PUBLISH_KEY || !safeEqual(adminKey, env.ADMIN_PUBLISH_KEY)) {
    return json({ error: "Unauthorized" }, 401);
  }

  let form;
  try {
    form = await request.formData();
  } catch {
    return json({ error: "Expected multipart/form-data" }, 400);
  }

  const deviceType = String(form.get("device_type") || "");
  const version    = String(form.get("version") || "").trim();
  const notes      = String(form.get("notes") || "").trim();
  const file       = form.get("file");

  if (!KNOWN_DEVICE_TYPES.has(deviceType)) {
    return json({ error: `Unknown device_type. Must be one of: ${[...KNOWN_DEVICE_TYPES].join(", ")}` }, 400);
  }
  if (!version) {
    return json({ error: "Missing version" }, 400);
  }
  if (!file || typeof file.arrayBuffer !== "function") {
    return json({ error: "Missing file" }, 400);
  }
  if (file.size === 0 || file.size > MAX_FIRMWARE_BYTES) {
    return json({ error: `File must be between 1 byte and ${MAX_FIRMWARE_BYTES} bytes` }, 400);
  }

  const fileBuf = await file.arrayBuffer();
  const hashHex = toHex(await crypto.subtle.digest("SHA-256", fileBuf));
  const binKey  = `firmware_bin:${deviceType}:${version}`;

  // Raw binary value, not JSON — putRecord/getRecord (store.js) always
  // JSON-encode, so this goes straight through the KV binding instead.
  await env.DSGV_KV.put(binKey, fileBuf);

  const manifest = (await getRecord(env, FIRMWARE_MANIFEST_KEY)) || {};
  manifest[deviceType] = {
    version,
    hash: hashHex,
    notes,
    bin_key: binKey,
    size: file.size,
    uploaded_at: Date.now(),
  };
  await putRecord(env, FIRMWARE_MANIFEST_KEY, manifest);

  return json({ success: true, device_type: deviceType, version, hash: hashHex });
}

// ── getFirmwareManifest ──────────────────────────────────────────────────────
// Called by the app (ota_service.dart). Public — this is the same trust level
// as the old public GitHub-hosted firmware_manifest.json (version/hash aren't
// secret; every download is hash-verified on-device regardless of who fetches
// this). Builds the download URL for each entry from the current request's
// own origin, so it never needs the deployed hostname hardcoded anywhere.
async function handleGetFirmwareManifest(request, env) {
  const manifest = (await getRecord(env, FIRMWARE_MANIFEST_KEY)) || {};
  const origin = new URL(request.url).origin;

  const devices = {};
  for (const [deviceType, entry] of Object.entries(manifest)) {
    devices[deviceType] = {
      version: entry.version,
      hash: entry.hash,
      notes: entry.notes || "",
      url: `${origin}/firmware/${deviceType}`,
    };
  }
  return json({ devices });
}

// ── firmware download ────────────────────────────────────────────────────────
// GET /firmware/{device_type} — streams the current binary for that device
// type from KV. Called by ESP-IDF's esp_https_ota on the device (TLS verified
// via esp_crt_bundle_attach, hash re-verified on-device before the image can
// boot — this route being unauthenticated is not a new exposure, the old
// GitHub-hosted .bin was equally public).
async function handleFirmwareDownload(deviceType, env) {
  if (!KNOWN_DEVICE_TYPES.has(deviceType)) {
    return json({ error: "Unknown device_type" }, 404);
  }
  const manifest = (await getRecord(env, FIRMWARE_MANIFEST_KEY)) || {};
  const entry = manifest[deviceType];
  if (!entry) {
    return json({ error: "No firmware published for this device_type yet" }, 404);
  }

  const bin = await env.DSGV_KV.get(entry.bin_key, "arrayBuffer");
  if (!bin) {
    return json({ error: "Firmware binary missing from storage" }, 500);
  }

  return new Response(bin, {
    status: 200,
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Length": String(entry.size),
      "Access-Control-Allow-Origin": "*",
    },
  });
}

// ── Router ───────────────────────────────────────────────────────────────────

const POST_ROUTES = {
  "/registerDevice":        handleRegisterDevice,
  "/getDeviceConfig":       handleGetDeviceConfig,
  "/updateDeviceConfig":    handleUpdateDeviceConfig,
  "/revertDeviceToFactory": handleRevertDeviceToFactory,
  "/publishFirmware":       handlePublishFirmware,
};

const GET_ROUTES = {
  "/getFirmwareManifest": (request, env) => handleGetFirmwareManifest(request, env),
};

export default {
  async fetch(request, env) {
    // Manual CORS handling — Workers has no built-in equivalent of the
    // `cors` npm middleware the old Cloud Functions used.
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type, X-Admin-Key",
        },
      });
    }

    const { pathname } = new URL(request.url);

    try {
      if (request.method === "GET") {
        if (pathname.startsWith("/firmware/")) {
          return await handleFirmwareDownload(pathname.slice("/firmware/".length), env);
        }
        const getHandler = GET_ROUTES[pathname];
        if (getHandler) return await getHandler(request, env);
        return json({ error: "Not found" }, 404);
      }

      if (request.method === "POST") {
        const postHandler = POST_ROUTES[pathname];
        if (!postHandler) return json({ error: "Not found" }, 404);
        return await postHandler(request, env);
      }

      return json({ error: "Method not allowed" }, 405);
    } catch (err) {
      return json({ error: "Internal error", detail: String(err) }, 500);
    }
  },
};
