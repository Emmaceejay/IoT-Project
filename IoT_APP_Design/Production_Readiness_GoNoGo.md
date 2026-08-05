# DSGV Hub — Production Readiness: Go / No-Go

**As of:** 2026-08-03, current working tree (includes uncommitted device-groups feature and firmware component-refactor cleanup).

## Verdict: **No-Go** (one item remaining — down from three)

Not because the platform is weak — the architecture (component-based firmware, offline-first app, dual-broker MQTT) is sound and well-documented. The app-level OTA gaps (unauthenticated trigger, unverified integrity, unverified TLS) that made this a hard No-Go are now closed in software. What's left is Secure Boot v2 + Flash Encryption — a deeper hardware-rooted hardening layer, not "OTA is currently exploitable." Still treating this as No-Go until that's deliberately enabled, since it can't be safely bundled into a routine code change (see item 5).

---

## Blocking Items (must close before Go)

| # | Item | Area | Status |
|---|---|---|---|
| 1 | OTA trigger (`devices/{id}/ota-trigger`) had no authentication — anyone able to publish could flash arbitrary firmware | Firmware | ✅ Closed — `handle_ota()` now requires the same `auth_token` gate `handle_config()` already used |
| 2 | OTA payload hash accepted but never actually read/verified | Firmware | ✅ Closed — `dsgv_ota.c` now requires a SHA-256 `hash`, verifies it against the downloaded image before `esp_https_ota_finish()` can mark it bootable, aborts on mismatch |
| 3 | OTA HTTPS download had no TLS server verification at all (not just "unpinned" — no CA check of any kind) | Firmware | ✅ Closed — `esp_crt_bundle_attach` (public CA bundle), same pattern `dsgv_gateway.c` already used correctly |
| 4 | ~~Local HTTP/Tasmota API has no authentication~~ | Firmware | ✅ Closed — `dsgv_http_server.c` now requires `Authorization: Bearer <auth_token>` on all routes; app updated to send it |
| 5 | ~~Device Groups feature (`GroupsScreen`) is fully built but not wired into app navigation~~ | Mobile | ✅ Closed — wired into `AppShell`'s bottom nav as a 3rd tab; bulk-control multi-gang no-op also fixed |
| 6 | Flash Encryption / Secure Boot v2 not enabled in `sdkconfig.defaults` | Firmware | 🔴 Open — `PRE_PRODUCTION_GUIDE.md` §4, unchecked. Deliberately scoped as its own follow-up ("Phase 2"): enabling it burns a signing-key digest to eFuse **permanently per device**, so it needs a deliberate hands-on rollout (test on a spare unit, Development mode before Release mode) rather than a code change applied blind. |

Item 6 is now the sole remaining blocking item. It's a real gap (no hardware-rooted trust chain, auth token not encrypted at rest) but a materially smaller risk than before — the practical "anyone can push arbitrary code to the fleet" exploit path (items 1-3) is closed.

---

## Evaluated Against PRE_PRODUCTION_GUIDE.md §9 Checklist

### Firmware
- [ ] Secure Boot / Flash Encryption enabled — **not done** (Phase 2, hardware rollout)
- [x] OTA auth, hash verification, and TLS server verification — all closed this pass
- [x] `.gitignore` updated to cover future Secure Boot signing keys (`*.pem`, `secure_boot_signing_key*`, `*.key`) ahead of Phase 2
- [x] Component refactor (`main/`+`include/` → `components/dsgv_common/`) is structurally complete and builds cleanly for all 11 device targets — confirmed via code read, old files safe to delete
- [ ] New event system (`dsgv_events.c`) — wired up and live (telemetry decoupling), but **untested by this review**; needs a hardware smoke test since it's new since the last commit
- Everything else in this section (BLE naming, factory reset, GPIO) — unchanged from last verified state per `TEST_CHECKLIST.md`, not re-verified here

### Mobile App
- [x] Groups feature wired into `AppShell` navigation (3rd bottom-nav tab)
- [x] ObjectBox schema change (new `DeviceGroupEntity`, additive `DeviceEntity.typeId`) confirmed additive/safe for existing installs — no migration risk
- [ ] `flutter analyze` / build verification — run after this pass's changes; confirm clean before sign-off
- [x] Group bulk-control multi-gang no-op (see Security Review) — fixed, now expands per device's actual relay capabilities

### Security (from PRE_PRODUCTION_GUIDE §9)
- [ ] No hardcoded credentials — spot-checked clean, not exhaustively scanned
- [ ] Secure Boot key not in repo — not verified (no key file found in tree, but confirm `.gitignore` coverage before generating one)
- [ ] MQTT broker auth/TLS on production broker — depends on broker deployment, out of scope for a code review

### Documentation
- [x] Stale file paths from the firmware refactor patched (`PRE_PRODUCTION_GUIDE.md`, `FLASHING_GUIDE.md`) as part of this pass
- [x] Whitepaper's "dynamic schema, no app update needed" claim annotated to match current `DeviceTypeRegistry` implementation (static compiled map, not device-broadcast schema)

---

## What's Genuinely Ready

- Firmware component architecture: clean, self-contained, all 11 device targets consume `dsgv_common` correctly with no duplicated logic.
- Auth-token design (generation, BLE-only exchange, constant-time comparison, NVS isolation, rollback timer): sound as documented.
- ObjectBox local persistence: safe additive migration path for the groups feature.
- Provisioning/captive-portal trust model: proximity-based, reasonable for initial setup.

## Recommended Path to Go

1. Enable Secure Boot v2 + Flash Encryption (closes item 6) — the one remaining blocking item. Deliberately not a routine code change: generate and safely back up the signing key, test Flash Encryption in Development mode on a spare unit first, only then move to Release mode for units that ship.
2. ~~OTA auth + hash verification + TLS~~ — done (items 1-3).
3. ~~Add minimal auth to the local HTTP API~~ — done (item 4).
4. ~~Decide on Groups~~ — shipped: navigation wired up, bulk-control bug fixed (item 5).
5. Run `idf.py build` across all 11 device targets and `flutter analyze` + a full app build as a final gate — neither was executed as part of this review.
6. Re-run this checklist; flip to Go once item 6 clears.
