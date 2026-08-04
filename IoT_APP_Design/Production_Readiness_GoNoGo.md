# DSGV Hub — Production Readiness: Go / No-Go

**As of:** 2026-08-03, current working tree (includes uncommitted device-groups feature and firmware component-refactor cleanup).

## Verdict: **No-Go**

Not because the platform is weak — the architecture (component-based firmware, offline-first app, dual-broker MQTT) is sound and well-documented. It's a No-Go because two ship-blocking security gaps are open (see `Security_Review.md`) and one just-added user-facing feature isn't reachable in the UI. Neither is a large fix; both must close before a device batch or app release goes out.

---

## Blocking Items (must close before Go)

| # | Item | Area | Status |
|---|---|---|---|
| 1 | OTA payload hash/signature not actually verified; Secure Boot not confirmed enabled | Firmware | 🔴 Open — `dsgv_ota.c:28-29` |
| 2 | OTA TLS certificate pinning commented out | Firmware | 🔴 Open — `dsgv_ota.c:65`, tracked in `PRE_PRODUCTION_GUIDE.md` §5 |
| 3 | ~~Local HTTP/Tasmota API has no authentication~~ | Firmware | ✅ Closed — `dsgv_http_server.c` now requires `Authorization: Bearer <auth_token>` on all routes; app updated to send it |
| 4 | ~~Device Groups feature (`GroupsScreen`) is fully built but not wired into app navigation~~ | Mobile | ✅ Closed — wired into `AppShell`'s bottom nav as a 3rd tab; bulk-control multi-gang no-op also fixed |
| 5 | Flash Encryption / Secure Boot not enabled in `sdkconfig.defaults` | Firmware | 🔴 Open — `PRE_PRODUCTION_GUIDE.md` §4, unchecked |

Items 1, 2, 5 are one root cause wearing three hats — enabling Secure Boot v2 + Flash Encryption and pinning the OTA cert closes all three at once. That's the single highest-leverage piece of remaining work now that items 3 and 4 are closed.

---

## Evaluated Against PRE_PRODUCTION_GUIDE.md §9 Checklist

### Firmware
- [ ] Secure Boot / Flash Encryption enabled — **not done**
- [ ] OTA server TLS certificate pinned — **not done**
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

1. Enable Secure Boot v2 + Flash Encryption, pin the OTA cert (closes items 1, 2, 5) — the one remaining blocking item.
2. ~~Add minimal auth to the local HTTP API~~ — done (item 3).
3. ~~Decide on Groups~~ — shipped: navigation wired up, bulk-control bug fixed (item 4).
4. Run `idf.py build` across all 11 device targets and `flutter analyze` + a full app build as a final gate — neither was executed as part of this review.
5. Re-run this checklist; flip to Go once all 🔴/🟠 rows clear.
