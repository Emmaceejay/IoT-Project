# Security Review — DSGV IoT Platform

> **Status:** OPEN — items pending fixes after complete build
> **Audit date:** 2026-06-09
> **Scope:** ESP-IDF 5.x firmware (`dsgv_firmware/`) + Flutter app (`dsgv_hub_app/`)
> **Auditor:** Automated + manual code review

---

## How to Use This Document

- Work through findings in severity order: Critical → High → Medium → Low.
- Tick `[x]` when a finding is resolved and note the commit SHA.
- Run the Re-audit Checklist at the bottom before final production release.

---

## CRITICAL (4 findings)

---

### [C1] OTA triggered by untrusted MQTT without validation

- [ ] Fixed — commit: ___________
- **Location:** `dsgv_firmware/components/dsgv_common/ota/dsgv_ota.c` · `dsgv_hub_app/lib/domain/services/ota_service.dart`
- **Issue:** Device accepts an OTA URL + SHA256 hash from the MQTT broker without verifying the message was authorised by the device owner. Any party that can publish to `devices/<id>/ota-trigger` can push arbitrary firmware.
- **Impact:** Complete fleet compromise — attacker who controls or compromises the broker flashes malicious firmware to every device.
- **Fix:** Require `auth_token` in the OTA JSON payload and validate it on-device (identical pattern to `handle_config`'s existing auth check) before starting the download.

---

### [C2] Unintentional plaintext MQTT fallback in firmware

- [x] Fixed — commit: see below
- **Location:** `dsgv_firmware/main/mqtt/dsgv_mqtt.c` · `dsgv_firmware/components/dsgv_common/mqtt/dsgv_mqtt.c`
- **Issue:** The `MQTT_EVENT_ERROR` handler silently fell back to `MQTT_LOCAL_HOST:1883` (plaintext TCP) when the TLS cloud broker was unreachable. This behaviour was NOT part of the intentional design — local control is HTTP-only.
- **Resolution:** Removed `s_using_local_broker` flag, the fallback block in `MQTT_EVENT_ERROR`, and all plaintext `connect_to_broker()` calls. On error the device now logs a warning and lets the ESP-MQTT client handle automatic TLS reconnection. Both firmware copies updated identically.

---

### [C3] Unauthenticated local HTTP server

- [ ] Fixed — commit: ___________
- **Location:** `dsgv_firmware/components/dsgv_common/http/dsgv_http_server.c` — all routes (`/api/cmd`, `/api/status`, `/cm`)
- **Issue:** Every device on the home Wi-Fi can toggle relays, read full device state, and send any command with zero authentication — no token, no password, nothing.
- **Impact:** A guest on the Wi-Fi network (or attacker who joins the network) can silently turn devices on or off with no audit trail.
- **Fix:** Require the `auth_token` in a query parameter (`?auth=<32hex>`) or `X-Auth-Token` header on every state-changing route; return HTTP 401 otherwise.

---

### [C4] Auth token stored unencrypted in NVS flash

- [ ] Fixed — commit: ___________
- **Location:** `dsgv_firmware/components/dsgv_common/config/dsgv_device_config.c` — NVS namespace `"DSGV_cfg"`, key `"auth_tok"`
- **Issue:** The 32-char auth token is written to NVS in plaintext. A physical attacker with a USB-serial adapter can dump flash (`esptool.py read_flash`) and extract it in under a minute.
- **Impact:** Physical access to the device yields the auth token → attacker can authorise broker-change commands and OTA triggers indefinitely.
- **Fix:** Enable `CONFIG_NVS_ENCRYPTION=y` in `sdkconfig` (pairs with Secure Boot or a dedicated key partition). This encrypts the entire NVS partition at rest with no code changes needed.

---

## HIGH (4 findings)

---

### [H1] Factory reset does not wipe the auth token

- [ ] Fixed — commit: ___________
- **Location:** `dsgv_firmware/components/dsgv_common/wifi/wifi_manager.c` — `wifi_manager_factory_reset()`
- **Issue:** Factory reset erases the `wifi_creds` NVS namespace but leaves `DSGV_cfg` intact. If a device is resold or given away, the previous owner's auth token survives on the device.
- **Impact:** Previous owner can issue authorised commands (broker change, OTA) to the device indefinitely, even after the new owner re-provisions it.
- **Fix:** Add `nvs_flash_erase_partition_ptr` (or `nvs_erase_all` on the `DSGV_cfg` handle) inside `wifi_manager_factory_reset()` so the token is regenerated on next boot.

---

### [H2] Auth token transmitted over unencrypted BLE during provisioning

- [ ] Fixed — commit: ___________
- **Location:** `dsgv_firmware/components/dsgv_common/provisioning/dsgv_provisioning.c:189-194` · `dsgv_hub_app/lib/domain/services/ble_provisioning_service.dart:244-250`
- **Issue:** On successful provisioning the firmware sends `"success:<32hex-token>:<MAC>"` as a plain BLE GATT notification. BLE without pairing/bonding is broadcast in the clear within ~100 m.
- **Impact:** Attacker with a Bluetooth sniffer (e.g. nRF Sniffer, Wireshark + BLE dongle) within range during provisioning captures the token and can authorise all future commands.
- **Fix:** Require BLE pairing before the provisioning GATT service is accessible (set `esp_ble_auth_req_t` to `ESP_LE_AUTH_REQ_SC_MITM_BOND`), or derive an ephemeral session key from the Wi-Fi credentials to encrypt the token before sending it.

---

### [H3] No certificate pinning on OTA HTTPS download (firmware)

- [ ] Fixed — commit: ___________
- **Location:** `dsgv_firmware/components/dsgv_common/ota/dsgv_ota.c:61-66` — the `.cert_pem` field is commented out
- **Issue:** OTA binary downloads over HTTPS use the default system CA bundle without pinning the CDN certificate. A compromised CA or a local MITM can serve a malicious firmware binary over a valid-looking TLS session.
- **Impact:** Attacker on the network injects malicious firmware at OTA time, even without broker access.
- **Fix:** Uncomment `.cert_pem` and populate it with the PEM of the leaf or intermediate certificate of your OTA CDN (Firebase Storage / AWS S3 / Cloudflare).

---

### [H4] No certificate pinning on MQTT TLS connection (Flutter app)

- [ ] Fixed — commit: ___________
- **Location:** `dsgv_hub_app/lib/domain/services/mqtt_service.dart:189-195`
- **Issue:** The app validates the full TLS certificate chain but does not pin the broker's public key hash. A compromised root CA (there are hundreds trusted by Android/iOS) allows a MITM to forge a valid certificate for the broker hostname.
- **Impact:** MITM attacker intercepts all app→broker traffic: reads telemetry, injects relay commands, triggers OTA.
- **Fix:** Extract the SHA-256 fingerprint of the broker's certificate and embed it in the app. Verify on connection using `SecurityContext.setTrustedCertificatesBytes` with only the broker's cert (or use `package:http_certificate_pinning`).

---

## MEDIUM (3 findings)

---

### [M1] HTTP server returns `Access-Control-Allow-Origin: *`

- [ ] Fixed — commit: ___________
- **Location:** `dsgv_firmware/components/dsgv_common/http/dsgv_http_server.c:98, 148, 200`
- **Issue:** All HTTP responses include a wildcard CORS header. Combined with C3 (no auth), any website the user visits while on home Wi-Fi can send CORS requests to control the device (CSRF).
- **Impact:** User visits a malicious website → page silently toggles relays via CORS requests to the device IP.
- **Fix:** Remove the `Access-Control-Allow-Origin` header entirely (devices don't need browser cross-origin access), or restrict to `null` if a local web UI is ever added.

---

### [M2] Auth token stored unencrypted in ObjectBox database (Flutter app)

- [ ] Fixed — commit: ___________
- **Location:** `dsgv_hub_app/lib/data/models/device_entity.dart:30-32`
- **Issue:** The auth token field is persisted in the ObjectBox `.mdb` database file without encryption. ObjectBox encryption is not enabled.
- **Impact:** On a rooted device or via phone forensics, the auth token for every provisioned device can be extracted from the database file.
- **Fix:** Do not store the auth token in ObjectBox. Store it exclusively in `flutter_secure_storage` (already used for MQTT credentials), keyed by device ID.

---

### [M3] Auth token travels inside MQTT payload (broker-change command)

- [ ] Fixed — commit: ___________
- **Location:** `dsgv_firmware/components/dsgv_common/mqtt/dsgv_mqtt.c` — `handle_config()`
- **Issue:** The broker-change JSON command includes the raw auth token in the payload body. If TLS is downgraded (C2) or pinning fails (H4), the token is visible in transit.
- **Impact:** Token exposure under degraded TLS conditions. Lower severity because it requires MQTT compromise first.
- **Fix:** This finding becomes low-severity once C2 and H4 are resolved. If further hardening is needed, use an HMAC of the payload signed with the token rather than sending the token itself.

---

## LOW (2 findings)

---

### [L1] NVS credentials namespace not locked after provisioning

- [ ] Fixed — commit: ___________
- **Location:** `dsgv_firmware/components/dsgv_common/provisioning/dsgv_provisioning.c:176-178`
- **Issue:** After writing Wi-Fi credentials to the `wifi_creds` NVS namespace, the handle is closed but the namespace remains writable on subsequent boots. A future firmware bug could silently overwrite credentials.
- **Impact:** Low direct risk; relevant only if a separate vulnerability enables arbitrary NVS writes.
- **Fix:** Store a SHA-256 hash of the credentials on first provision; verify on each boot and log a warning if the hash mismatches.

---

### [L2] OTA progress published in 5 % increments to MQTT telemetry

- [ ] Fixed — commit: ___________
- **Location:** `dsgv_firmware/components/dsgv_common/ota/dsgv_ota.c:91-94`
- **Issue:** Progress messages (`{"ota_progress": N}`) are published to `devices/<id>/telemetry` every 5 %, revealing to any broker observer exactly when a device is mid-update.
- **Impact:** Information disclosure only; attacker cannot modify the OTA process through this channel.
- **Fix:** Replace incremental progress publishes with a single start event and a single success/failure event.

---

## Priority Fix Order

| # | ID | Title | Effort | Status |
|---|----|-------|--------|--------|
| 1 | C3 | Add auth to HTTP server routes | ~1 h | [ ] |
| 2 | C2 | Remove plaintext MQTT fallback | ~30 min | [x] |
| 3 | C1 | Require auth_token in OTA trigger | ~1 h | [ ] |
| 4 | H1 | Wipe DSGV_cfg on factory reset | ~30 min | [ ] |
| 5 | H3 | Pin OTA HTTPS certificate | ~30 min | [ ] |
| 6 | M1 | Remove CORS wildcard header | ~15 min | [ ] |
| 7 | M2 | Move auth token to flutter_secure_storage | ~1 h | [ ] |
| 8 | H4 | Pin MQTT TLS cert in Flutter app | ~2 h | [ ] |
| 9 | C4 | Enable NVS encryption (sdkconfig) | Requires Secure Boot setup | [ ] |
| 10 | H2 | Require BLE pairing before provisioning | Complex — plan separately | [ ] |
| 11 | M3 | Token-in-payload (resolved by C2 + H4) | — | [ ] |
| 12 | L1 | Hash-verify NVS credentials on boot | ~1 h | [ ] |
| 13 | L2 | Replace OTA progress with start/done events | ~30 min | [ ] |

---

## Re-audit Checklist

Run these checks after all findings are resolved:

- [ ] **C1** — Send a raw MQTT message to `devices/<id>/ota-trigger` without a valid `auth_token`; device must ignore it and log an auth failure.
- [ ] **C2** — Kill the cloud broker; confirm device does NOT connect to `192.168.1.100:1883` (check serial monitor; no `"Retrying with local broker"` log).
- [ ] **C3** — `curl http://<device-ip>/api/cmd -d '{"capability":"power","value":true}'` without auth header must return HTTP 401.
- [ ] **C4** — Run `esptool.py read_flash` on a flashed device; confirm the NVS partition is encrypted and `auth_tok` is not readable as plain ASCII.
- [ ] **H1** — Hold factory reset button; confirm serial log shows `DSGV_cfg` erased; confirm new token is generated on next boot.
- [ ] **H2** — Sniff BLE with nRF Sniffer during provisioning; confirm token is not visible in plaintext GATT notifications.
- [ ] **H3** — Run `mitmproxy` between device and OTA CDN; confirm connection is rejected by the firmware.
- [ ] **H4** — Run `mitmproxy` between app and MQTT broker; confirm app refuses the connection.
- [ ] **M1** — `curl -I http://<device-ip>/api/status`; confirm no `Access-Control-Allow-Origin` header in response.
- [ ] **M2** — On a rooted emulator, inspect ObjectBox database; confirm `auth_token` field is empty or absent.
