# DSGV Hub — Security Review

**Scope:** ESP-IDF firmware (`dsgv_firmware/`), Flutter app (`dsgv_hub_app/`), Cloudflare device-config gateway (`cloudflare_gateway/`).
**Method:** Static review of the current tree (including uncommitted working-directory changes) against `PRE_PRODUCTION_GUIDE.md` §4–7. Not a penetration test — treat as a prioritized punch list, not a certification.
**Date:** 2026-08-03

Severity: 🔴 Critical (ship-blocking) · 🟠 High (fix before general release) · 🟡 Medium (fix soon after) · 🟢 Low / hardening.

---

## Firmware

### ✅ OTA trigger had no authentication at all — CLOSED
`handle_ota()` in `dsgv_mqtt.c` forwarded any payload published to `devices/{id}/ota-trigger` straight to `DSGV_ota_begin()` with **zero auth check** — unlike `handle_config()`, which already required the 32-hex `auth_token`. Anyone able to publish on that topic (or spoof/MITM the broker connection) could trigger a firmware flash with attacker-supplied code, no token needed. Found during the OTA-integrity review below and closed in the same pass, since it's a bigger, cheaper-to-exploit gap than the missing hash check ever was.
- **Fix:** `handle_ota()` now requires and verifies the same `auth_token` field, `memcmp`-checked against `g_device_config.auth_token`, exactly matching `handle_config()`'s existing pattern, before ever calling `DSGV_ota_begin()`.

### ✅ OTA integrity was not actually verified — CLOSED
`components/dsgv_common/ota/dsgv_ota.c` accepted a `hash` field in the OTA payload but **never read it** (not "unverified" — literally dead, never parsed). The code comment deferred to Secure Boot, which is **still not enabled** anywhere in this project (`sdkconfig.defaults` has `CONFIG_SECURE_BOOT`/`CONFIG_FLASH_ENCRYPTION_ENABLED` present only as comments) — so prior to this fix there was no integrity verification of any kind, app-level or bootloader-level.
- **Fix:** `hash` is now a required field (64-char SHA-256 hex). After the download completes but *before* `esp_https_ota_finish()` (which is what marks an image bootable), the code calls ESP-IDF's own `esp_partition_get_sha256()` (`esp_partition.h`) on the just-written OTA partition and compares against the app-supplied hash. This is image-aware (hashes the actual app image content, not raw partition capacity) and validates the image structure as a side effect — a malformed image is rejected outright. A mismatch calls `esp_https_ota_abort()` instead of `finish()` — the bad image is discarded and current firmware stays active. (An earlier draft of this fix hand-rolled the hash with direct `mbedtls_sha256_*` calls; switched away from that after confirming against the actual installed ESP-IDF v6.0.1 source that `mbedtls/sha256.h` isn't on the public include path in this version — its API moved behind a private header as part of an mbedtls/TF-PSA-Crypto backend migration. `esp_partition_get_sha256()` is the stable, IDF-blessed API for exactly this purpose and sidesteps that entirely.)
- **Note:** this is app-level hash verification, not a cryptographic signature — it stops corrupted/tampered-in-transit images and (combined with the auth-token fix above and the TLS fix below) closes the practical attack surface, but it doesn't replace Secure Boot v2's hardware-rooted trust chain. Secure Boot v2 + Flash Encryption remain the deeper fix, tracked separately below as Phase 2 — not bundled here because enabling them burns an eFuse permanently per device and needs its own hands-on hardware rollout, not a code change.

### ✅ OTA channel had no TLS server verification at all — CLOSED
Worse than "unpinned": `components/dsgv_common/ota/dsgv_ota.c`'s `esp_http_client_config_t` set none of `.cert_pem`, `.cacert_buf`, or `.crt_bundle_attach`. The only related line was commented out and referenced `server_cert_pem_start` — a symbol that doesn't exist anywhere in the repo (no embedded `.pem`, no `EMBED_TXTFILES` directive); it was unfinished, dead code, not "pinning that got disabled." Nothing stopped a MITM (rogue AP, compromised DNS, CA-store trust abuse) from serving a malicious binary that the device would download and (previously) never even hash-check.
- **Fix:** `.crt_bundle_attach = esp_crt_bundle_attach` — the same pattern `dsgv_gateway.c` already uses correctly for its own HTTPS calls, validating against ESP-IDF's compiled-in public CA bundle (`CONFIG_MBEDTLS_CERTIFICATE_BUNDLE=y`, already enabled project-wide). This is real server authentication, not pinning to one specific certificate — true pinning to a single CDN cert is a stricter future hardening step if wanted, not required for this fix to be meaningful.

### ✅ Local HTTP server now requires authentication — CLOSED
`components/dsgv_common/http/dsgv_http_server.c` previously exposed a Tasmota-compatible REST API (`/api/status`, `/api/cmd`, `/cm?cmnd=`) on port 80 with no auth check. All three routes now require `Authorization: Bearer <auth_token>`, validated against the same per-device token the MQTT config-command handler already trusts (`request_is_authorized()` in `dsgv_http_server.c`). `local_http_service.dart` (app side) now sends the header using `SmartDevice.authToken`; if the device has no token yet (mid-pairing), local HTTP is skipped and the command falls through to MQTT rather than failing silently.
- **Residual risk:** `memcmp()` token comparison is not constant-time (matches the existing pattern in `dsgv_mqtt.c`'s config-command handler — see that file's misleading "constant-time memcmp" comment). Low practical risk given the token is 128 bits and LAN-only, but worth a follow-up pass if a stricter threat model is adopted.

### ✅ Firebase client wired up — broker credential no longer compiled into firmware — CLOSED
`dsgv_firebase.c` is now built into every device target and called from `dsgv_app_main.c` after the local HTTP server starts (so a slow/absent internet connection never blocks local control). It fetches `broker_username`/`broker_password` from `getDeviceConfig` (authenticated with the device's own `auth_token`) and caches them in the `mqtt_cfg` NVS namespace, which `connect_to_broker()` now reads directly — `MQTT_CLOUD_USERNAME`/`PASSWORD` no longer exist in `dsgv_config.h` at all. A device connects anonymously (and is rejected) until its first successful Firebase fetch — accepted tradeoff, matches the existing internet requirement BLE provisioning already has via `registerDevice`.

Two related bugs found and fixed while wiring this up: the custom-broker-change command (`handle_config`) was overwriting `host`/`port`/`tls` in NVS without touching `username`/`password`, which would have leaked the factory HiveMQ credential to any third-party broker a user pointed a device at; and the 60-second broker-rollback timer wasn't preserving credentials across a rollback. Both now handle all five fields consistently.

Cloud Function side: `functions/index.js`'s `FACTORY_CONFIG` no longer hardcodes the credential either — moved to Secret Manager via `runWith({ secrets: [...] })`, read from `process.env` per-request. Real values are set with `firebase functions:secrets:set MQTT_BROKER_USERNAME`/`..._PASSWORD` (not stored in source).

**Residual/accepted:** the app itself (`mqtt_config.dart`'s `MqttConfig.factoryDefault`) still ships the broker password as a compiled-in constant — fixing that needs new infrastructure (Firebase Anonymous Auth + App Check) and was explicitly scoped out of this pass.

### 🟢 Confirmed adequate (per PRE_PRODUCTION_GUIDE.md §7, spot-checked)
Auth-token generation via `esp_fill_random()`, BLE-only exchange, constant-time `memcmp()` validation, NVS namespace isolation, and the 60s broker-rollback timer are all documented as in place. Flash Encryption is the one still-open item gating full protection of the token at rest — same root cause as the OTA item above (Secure Boot/Flash Encryption not yet enabled).

### 🟢 Provisioning surface
`components/dsgv_common/provisioning/dsgv_provisioning.c` (BLE GATT provisioning) and `components/dsgv_common/http/dsgv_captive_portal.c` (AP-mode captive portal recovery) both require physical/RF proximity to the device, which is a reasonable trust boundary for initial setup — no findings here beyond ensuring the captive portal is only served while the device is in its own setup AP, not reachable once joined to the home network.

---

## Mobile App

### ✅ Group bulk-control silent partial-failure — CLOSED
`device_group_notifier.dart` (`sendCommandToGroup`) previously sent `{'power': bool}` to every device in a group regardless of device type, silently no-op'ing multi-gang switches' extra gangs (`power_2`/`power_3`/`power_4`) and non-relay device types. It now expands a bare `'power'` command per device to every relay capability that device actually has (via `DeviceTypeRegistry`), and skips devices with no relay capability entirely instead of sending a command they can't act on.

### 🟢 No hardcoded secrets found
Spot-checked the modified/new files for this review (device group stack, device_manager.dart, registry) — no embedded credentials, API keys, or broker passwords. Consistent with `PRE_PRODUCTION_GUIDE.md` §9 checklist item.

### 🟡 Local DB has no field-level encryption noted
ObjectBox stores device state, group membership, and (per the wifi_manager/provisioning flow) potentially cached broker settings locally in plaintext SQLite-like storage. Not reviewed in depth here — flag as an open question: does anything security-sensitive (auth tokens, broker credentials) get cached in the Isar/ObjectBox layer, and if so, is Android's app-sandbox isolation considered sufficient, or does it need `flutter_secure_storage`/Keystore-backed storage instead?

---

## Cloud (Cloudflare Gateway)

The device-config gateway (`cloudflare_gateway/`) moved off Firebase Cloud Functions/RTDB to Cloudflare Workers/KV — see `cloudflare_gateway/SETUP_GUIDE.md` for the full rationale. This section covers findings specific to that gateway.

### ✅ `getDeviceConfig` was leaking the live broker credential to unauthenticated callers — CLOSED
`src/index.js`'s `handleGetDeviceConfig()` returned the **full** factory config — including `broker_username`/`broker_password` — for any `device_id` with no matching registry entry, with no `auth_token` check on that branch at all. Since `device_id` is just a 12-hex-character WiFi MAC and only a small fraction of the address space is ever actually registered, this meant anyone could `POST` a random/guessed `device_id` and get HiveMQ Cloud's real username/password back in plaintext — no valid token needed. This fully undid the point of the Firebase→Cloudflare migration: the broker credential was no longer compiled into firmware, but it was sitting behind what was effectively an open endpoint instead.
- **Fix:** the unregistered-device branch now returns only `broker_host`/`port`/`tls` (already public — compiled into every firmware binary) with empty `broker_username`/`broker_password`. Credentials are only ever returned once `auth_token` is verified against a real registry entry (`safeEqual(registry.auth_token, token)`).
- **Side effect handled:** closing this reopened a narrow, legitimate race — a device's very first `getDeviceConfig` call (at first boot after provisioning) can now land before the app's `registerDevice` call has, meaning that first fetch returns no credentials where it previously (insecurely) always did. Firmware (`dsgv_gateway.c`) now retries up to `GATEWAY_MAX_ATTEMPTS` (3), `GATEWAY_RETRY_DELAY_MS` (2s) apart, whenever the gateway responds successfully but with no credentials, before falling back to "anonymous until next boot" — the same accepted tradeoff already documented for a device with no internet at all.

### 🟡 Not independently reviewed beyond the above
Route-level input validation (`DEVICE_ID_RE`/`AUTH_TOKEN_RE` regex, `safeEqual` constant-time comparison) matches the old Cloud Functions logic and looks sound on read, but hasn't had a dedicated pass — worth revisiting alongside the local-storage question below if a stricter threat model is adopted. No rate limiting exists on any route (Cloudflare's free tier has no built-in per-IP throttling); `registerDevice` writes to KV on every unrecognized `device_id`, so a scripted flood of fake `device_id`s could in principle burn into the 1,000-writes/day KV cap and deny real devices a same-day registration — low real-world likelihood (no public knowledge of valid `device_id` format incentivizes this) but not yet mitigated.

---

## Priority Order

1. ~~🔴 OTA trigger had no authentication~~ ✅ Closed
2. ~~🔴 OTA hash/signature verification~~ ✅ Closed — app-level SHA-256, verified before the image can be marked bootable
3. ~~🟠 OTA TLS server verification~~ ✅ Closed — `esp_crt_bundle_attach`, not pinning (pinning to one cert is optional future hardening)
4. ~~🔴 Gateway leaking live broker credential to unauthenticated callers~~ ✅ Closed
5. ~~🟠 Auth on the local HTTP/Tasmota API~~ ✅ Closed
6. ~~🟡 Confirm live broker-config delivery path (Firebase client dead code question)~~ ✅ Closed — wired up, no compile-time broker credential remains
7. ~~🟡 Fix multi-gang/non-relay no-op in group bulk control~~ ✅ Closed
8. 🟡 Decide on secure storage for any sensitive local app data
9. 🟡 Rate limiting / write-cap protection on gateway `registerDevice`
10. 🟢 Secure Boot v2 + Flash Encryption ("Phase 2" — hardware-rooted trust chain and the auth-token-at-rest gap; deliberately not bundled with the app-level OTA fixes above since enabling it burns an eFuse permanently per device and needs its own hands-on hardware rollout, tested on a spare unit first — see `PRE_PRODUCTION_GUIDE.md` §4 for the exact config)
