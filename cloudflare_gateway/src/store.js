/**
 * store.js — thin wrapper over the Workers KV binding (DSGV_KV).
 *
 * Replaces the old Firebase Realtime Database bridge (rtdb.js +
 * firebaseAuth.js) — no external auth needed, Workers reads/writes its own
 * KV namespace via a zero-config binding declared in wrangler.toml.
 *
 * Keys mirror the old RTDB paths, flattened:
 *   device_registry:{deviceId}
 *   device_configs:{deviceId}
 *
 * KV has no native partial update like RTDB's PATCH — updateRecord() does a
 * read-merge-write instead.
 */

export const getRecord = (env, key) => env.DSGV_KV.get(key, "json");

export const putRecord = (env, key, value) =>
  env.DSGV_KV.put(key, JSON.stringify(value));

export async function updateRecord(env, key, partial) {
  const existing = await getRecord(env, key);
  const merged = { ...existing, ...partial };
  await putRecord(env, key, merged);
  return merged;
}
