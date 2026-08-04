// Constant-time string comparison to prevent timing attacks on auth tokens.
// Same logic as dsgv_hub_app/functions/index.js's safeEqual() — kept in sync
// by hand since this project runs in a different JS runtime, not a shared import.
export function safeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}
