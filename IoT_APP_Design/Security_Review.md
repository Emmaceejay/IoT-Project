# DSGV Hub — Security Review

**Scope:** ESP-IDF firmware (`dsgv_firmware/`), Flutter app (`dsgv_hub_app/`), Firebase cloud gateway.
**Method:** Static review of the current tree (including uncommitted working-directory changes) against `PRE_PRODUCTION_GUIDE.md` §4–7. Not a penetration test — treat as a prioritized punch list, not a certification.
**Date:** 2026-08-03

Severity: 🔴 Critical (ship-blocking) · 🟠 High (fix before general release) · 🟡 Medium (fix soon after) · 🟢 Low / hardening.

---

## Firmware

### 🔴 OTA integrity is not actually verified
`components/dsgv_common/ota/dsgv_ota.c:28-29` accepts a SHA-256 hash in the OTA payload but does not verify it — the code comment defers to Secure Boot, and Secure Boot is **not confirmed enabled** (`sdkconfig.defaults` does not set `CONFIG_SECURE_BOOT=y`; `PRE_PRODUCTION_GUIDE.md` §4 lists it as a pre-ship action item, still unchecked). As shipped, a device that reaches the OTA URL will flash whatever binary is served there with no cryptographic check that it's genuine.
- **Fix:** either verify the SHA-256 (and ideally a signature, not just a hash) in `dsgv_ota.c` before writing to the OTA partition, or enable Secure Boot v2 + Flash Encryption per `PRE_PRODUCTION_GUIDE.md` §4 and treat that as the actual control — don't rely on an unverified hash field as if it were one.

### 🟠 OTA channel has no TLS certificate pinning
`components/dsgv_common/ota/dsgv_ota.c:65` — `.cert_pem` is commented out:
```c
// .cert_pem = server_cert_pem_start, // Pin S3/CDN cert for production
```
Combined with the missing hash verification above, this is the same gap from two angles: nothing stops a MITM (rogue AP, compromised DNS, CA-store trust abuse) from serving a malicious binary that the device will accept. `PRE_PRODUCTION_GUIDE.md` §5 already documents the fix — it just isn't applied yet.

### 🟠 Local HTTP server has no authentication
`components/dsgv_common/http/dsgv_http_server.c` exposes a Tasmota-compatible REST API (`/api/status`, `/api/cmd`, `/cm?cmnd=`) on port 80 with no visible auth check. Anyone on the same LAN/WiFi (including a compromised IoT VLAN neighbor, or anyone who joins the setup AP during provisioning) can query state and issue relay/GPIO commands directly, bypassing MQTT auth entirely.
- **Fix:** at minimum HTTP Basic Auth with a per-device credential provisioned over BLE alongside the MQTT auth token, or disable the endpoint outside of provisioning mode.

### 🟡 Firebase client is dead code, not a live gap — but don't let it rot
`components/dsgv_common/firebase/dsgv_firebase.c` (fetches broker config via `device_id` + `auth_token`, persists to NVS) is not referenced in any `CMakeLists.txt` in the component or any device target — it isn't compiled into any current build. Not an active vulnerability, but it means the "Firebase-secured config" data path described in `README.md` §2 either isn't live yet on-device or is implemented elsewhere; worth confirming which is true before it's assumed shipped.

### 🟢 Confirmed adequate (per PRE_PRODUCTION_GUIDE.md §7, spot-checked)
Auth-token generation via `esp_fill_random()`, BLE-only exchange, constant-time `memcmp()` validation, NVS namespace isolation, and the 60s broker-rollback timer are all documented as in place. Flash Encryption is the one still-open item gating full protection of the token at rest — same root cause as the OTA item above (Secure Boot/Flash Encryption not yet enabled).

### 🟢 Provisioning surface
`components/dsgv_common/provisioning/dsgv_provisioning.c` (BLE GATT provisioning) and `components/dsgv_common/http/dsgv_captive_portal.c` (AP-mode captive portal recovery) both require physical/RF proximity to the device, which is a reasonable trust boundary for initial setup — no findings here beyond ensuring the captive portal is only served while the device is in its own setup AP, not reachable once joined to the home network.

---

## Mobile App

### 🟡 Group bulk-control has a silent partial-failure mode
`device_group_notifier.dart:50` (`sendCommandToGroup`) sends `{'power': bool}` to every device in a group regardless of device type. Multi-gang switches (`power_2`, `power_3`, `power_4`) and non-relay device types silently no-op. Not a security defect, but a group "all off" that appears to succeed while leaving some devices powered on is a safety-adjacent correctness issue worth fixing before the feature ships (see also Critical Review).

### 🟢 No hardcoded secrets found
Spot-checked the modified/new files for this review (device group stack, device_manager.dart, registry) — no embedded credentials, API keys, or broker passwords. Consistent with `PRE_PRODUCTION_GUIDE.md` §9 checklist item.

### 🟡 Local DB has no field-level encryption noted
ObjectBox stores device state, group membership, and (per the wifi_manager/provisioning flow) potentially cached broker settings locally in plaintext SQLite-like storage. Not reviewed in depth here — flag as an open question: does anything security-sensitive (auth tokens, broker credentials) get cached in the Isar/ObjectBox layer, and if so, is Android's app-sandbox isolation considered sufficient, or does it need `flutter_secure_storage`/Keystore-backed storage instead?

---

## Cloud (Firebase)

Not independently reviewed here — `PRE_PRODUCTION_GUIDE.md` and the whitepaper describe the intended model (Cloud Functions gate `device_registry`/`device_configs`, auth token required). Given the firmware-side Firebase client is currently dead code (see above), **confirm which component actually owns the broker-config delivery path in the current build** before relying on the documented security model — reviewing Firebase Security Rules and Cloud Function auth checks should be the next follow-up once that's confirmed.

---

## Priority Order

1. 🔴 OTA hash/signature verification (or confirm+enable Secure Boot as the real control)
2. 🟠 OTA TLS cert pinning
3. 🟠 Auth on the local HTTP/Tasmota API
4. 🟡 Confirm live broker-config delivery path (Firebase client dead code question)
5. 🟡 Fix multi-gang/non-relay no-op in group bulk control
6. 🟡 Decide on secure storage for any sensitive local app data
7. 🟢 Flash Encryption (closes the auth-token-at-rest gap)
