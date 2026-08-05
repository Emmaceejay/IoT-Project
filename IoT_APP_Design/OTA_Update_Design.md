# DSGV Hub — OTA Update System: Design Reference

**Purpose:** how firmware updates work end to end, why the security model looks
the way it does, and how to cut a release. Written after closing out the OTA
security gaps that were blocking commercial readiness — kept here as the
reference for extending this system later, and as a template for how any
future "device does something powerful on remote command" feature should be
designed.

---

## 1. Architecture overview

```
Release build (.bin) ──admin/publish.html (upload, no git/CLI needed)
        │
        ▼
Cloudflare Worker: /publishFirmware → hashes server-side, stores the binary
                    and {version, hash, notes} in KV per device_type
                    (not R2 — R2 needs a credit card to enable, KV doesn't)
        │
        ▼
Cloudflare Worker: /getFirmwareManifest ── fetched by app
        │
        ▼
App: ManifestNotifier.fetch() → compares against device.firmwareVersion
        │  user taps "Update"
        ▼
App: OtaOrchestratorService.triggerUpdate() → MQTT publish
        │  devices/{id}/ota-trigger : {"auth_token","url","hash"}
        ▼
Device: handle_ota() (dsgv_mqtt.c) → verifies auth_token → DSGV_ota_begin()
        │
        ▼
Device: chunked HTTPS download (esp_https_ota, esp_crt_bundle_attach)
        │  progress published to devices/{id}/telemetry every 5%
        ▼
Device: esp_partition_get_sha256() vs "hash" → mismatch = esp_https_ota_abort()
        │  match
        ▼
Device: esp_https_ota_finish() → marks new partition bootable → esp_restart()
        │
        ▼
Dual-bank partition: if new firmware crash-loops, bootloader auto-rolls back
```

Key files: `dsgv_mqtt.c` (`handle_ota`, topic wiring), `dsgv_ota.c`
(`DSGV_ota_begin`, download + verify), `ota_service.dart` (app orchestration),
`device_detail_screen.dart` (UI), `cloudflare_gateway/src/index.js`
(`publishFirmware`/`getFirmwareManifest`/`/firmware/{type}` routes),
`cloudflare_gateway/admin/publish.html` (the release UI, no git/CLI needed).

---

## 2. Security model — three independent controls

Each closes a different failure mode; none of them substitutes for another.

| Control | Closes | Mechanism |
|---|---|---|
| **Auth** | Anyone able to publish on the topic triggering a flash | `auth_token` (same 32-hex BLE-provisioned token every other sensitive command uses), `memcmp`-checked in `handle_ota()` before `DSGV_ota_begin()` is ever called |
| **Integrity** | Corrupted download, tampered-in-transit binary, wrong file | `hash` (SHA-256, required) checked via `esp_partition_get_sha256()` — **before** `esp_https_ota_finish()`, so a mismatch routes to `esp_https_ota_abort()` and the bad image never becomes bootable |
| **Transport** | MITM serving a malicious binary over the download connection | `esp_crt_bundle_attach` — validates the server against ESP-IDF's compiled-in public CA bundle |

**What this deliberately is not:** a hardware-rooted trust chain. All three
controls above are app-level software checks — meaningful, but a determined
attacker with physical flash access or a way to bypass this specific code
path isn't stopped by them. That's what Secure Boot v2 + Flash Encryption is
for (see §5) — a different, deeper layer, not a replacement for these three.

### Why auth was the most important of the three
Before this fix, `handle_ota()` had **zero** authentication — unlike
`handle_config()`, which already gated broker/WiFi changes behind
`auth_token`. That asymmetry was the actual finding: OTA triggers arbitrary
code execution and was *less* protected than a broker-hostname change. **Any
new MQTT/HTTP command handler that can change device behavior must be
auth-gated from the moment it's written** — it's cheap to add up front and
easy to forget once a feature already "works" without it.

---

## 3. Release workflow

Full step-by-step is in `cloudflare_gateway/FIRMWARE_PUBLISHING_GUIDE.md` —
summary here:

1. **Build:** `idf.py -DIDF_TARGET=<chip> build` → `.bin` in
   `devices/<device>/build/`.
2. **Publish:** open `cloudflare_gateway/admin/publish.html` (a local file,
   no hosting required), pick the device type, choose the `.bin`, fill in the
   version, click Publish. The Worker hashes it server-side, stores it in
   Workers KV (not R2 — see the storage-choice note in §5), and updates the
   manifest for that device type — no git, no manual hashing, no hand-editing
   JSON.
3. **Trigger:** in the app, "Check for updates" → "Update to vX.Y.Z" per
   device. Requires the device to already have an `authToken` (i.e., it's
   been through BLE provisioning) — the button is disabled with "Device not
   paired yet" otherwise.

This replaced an earlier GitHub-based flow (manual hashing, hand-edited
`firmware_manifest.json`, commit + push) — retired because it required git/CLI
knowledge for what should be a routine operational task. See the "why"
reasoning in the git history of this file if the old approach is ever
relevant again, but don't resurrect it — the publish page is strictly better
on every axis (fewer manual steps, server-computed hash instead of
trust-the-human-copied-it-right, and the manifest is no longer a public
GitHub file).

---

## 4. Design lessons worth carrying forward

These are general, not OTA-specific — apply them to the next feature that
lets the app tell a device to do something, not just this one.

1. **Auth-gate every state-changing command at the handler, on day one.**
   `handle_config()` already had this pattern; `handle_ota()` didn't, and
   that gap sat unnoticed until a dedicated review. When adding a new MQTT/
   HTTP command handler, copy the `auth_token` check pattern first, write the
   feature logic second — not the other way round.

2. **A new firmware-side auth requirement always has an app-side echo.**
   Adding the `auth_token` check to `handle_ota()` silently broke the app's
   existing `triggerUpdate()` call, which didn't send one — caught only
   because the release workflow was walked through end to end. Any time a
   device-side command gets a new required field, grep the app for every call
   site publishing to that topic before considering the change done.

3. **Verify ESP-IDF APIs against the actual installed version, not memory or
   general documentation.** `mbedtls/sha256.h` looked like the obvious way to
   hash a buffer, and would have failed to compile against this project's
   ESP-IDF v6.0.1 (its public header moved behind a private path as part of
   an mbedtls/TF-PSA-Crypto backend migration). Caught by grepping the actual
   installed IDF source tree, not by assumption. When in doubt, the installed
   `esp-idf/components/*/include/*.h` is the ground truth — a local IDF
   checkout is normally available at `C:\esp\<version>\esp-idf` on this
   machine for exactly this kind of check.

4. **Prefer ESP-IDF's own purpose-built helpers over hand-rolled crypto.**
   `esp_partition_get_sha256()` ended up simpler *and* more correct than a
   manual `mbedtls_sha256_*` loop — it's image-aware (hashes actual app
   content, not raw partition capacity) and validates image structure as a
   free side effect. If IDF ships a function for exactly your use case,
   assume it's already handled edge cases a hand-rolled version would miss.

5. **Validate before you commit, structurally.** The hash check runs after
   `esp_https_ota_is_complete_data_received()` but strictly *before*
   `esp_https_ota_finish()`, because `finish()` is the point of no return
   (marks the partition bootable). Any similar "download → verify → commit"
   flow elsewhere in this codebase should follow the same shape: the abort
   path must be reachable *before* the commit call, never after.

6. **Toolchain build verification isn't always available — have a fallback.**
   This session's sandbox was missing the ESP-IDF Python virtualenv, so a
   real `idf.py build` wasn't possible here. Cross-referencing every API call
   against the installed IDF source headers directly was the fallback, and it
   caught a real compile-time bug the "just trust the pattern" approach would
   have missed. Don't skip verification just because the primary method is
   unavailable — find the next-best one.

---

## 5. Recommendations

**Near-term, low effort:**
- **Set up CI** (GitHub Actions) running `idf.py build` across all 11 device
  targets on every push touching `dsgv_firmware/`. This project doesn't have
  CI today — finding #6 above (toolchain unavailable, had to manually verify
  against headers) wouldn't have been necessary with an automated build gate,
  and it would catch the *next* API-compatibility surprise immediately
  instead of requiring header archaeology again.
- ~~Script the release workflow~~ — done, superseded by the
  `admin/publish.html` page (§3): the manual hash-copy-into-JSON step this
  recommendation was about no longer exists at all — the Worker computes the
  hash server-side and writes the manifest directly, no script needed.
- **Storage choice: Workers KV, not R2.** R2 was the initial choice for
  storing firmware binaries but got reverted after discovering Cloudflare
  requires a credit card on file to enable R2 at all, even within its free
  tier — that broke this project's explicit "genuinely free, no card"
  requirement (see `SETUP_GUIDE.md`'s original free-tier verification).
  Binaries here are small enough (a few MB) to fit comfortably in Workers
  KV's 25MiB-per-value limit instead, which needs no card. Worth remembering
  if a future feature needs to store something KV can't hold (KV's limit is
  per-value, not a good fit for anything approaching tens of MB) — R2 is
  still the right tool for that case, just budget for the card requirement
  when it comes up.
- **Add a "sensitive command checklist"** to whatever contributor docs exist
  (`PRE_PRODUCTION_GUIDE.md` is the natural home) codifying lesson #1 above:
  any new MQTT/HTTP handler that changes device state or behavior must be
  auth-gated before merge, not after a security review finds it missing.

**Medium-term:**
- **Phase 2: Secure Boot v2 + Flash Encryption**, tracked separately in
  `Security_Review.md`/`Production_Readiness_GoNoGo.md` — the one remaining
  item before this project clears its own Go/No-Go bar. Deliberately not
  bundled with the app-level fixes above since it's a one-way eFuse burn per
  device. Recommend treating it as its own milestone: generate and back up
  the signing key, test Flash Encryption in Development mode on a spare unit,
  only then Release mode for units that ship.
- **Consider a real code-signing step** (not just a hash) once Secure Boot v2
  is in place — the hash check here proves the download wasn't corrupted or
  substituted in transit, but doesn't prove the binary was produced by you
  specifically. Secure Boot v2's signature verification is what actually
  closes that gap; worth revisiting whether the app-level hash check becomes
  redundant or stays as defense-in-depth once that's live.

**Longer-term / optional hardening:**
- True TLS cert pinning (one specific CDN/host cert, not just the public CA
  bundle) if the firmware host is ever a single fixed domain long-term —
  traded off against the cert-rotation maintenance cost, not worth it today
  given the CA-bundle check is already a large improvement over the previous
  "no verification at all" state.
- Rate-limiting or a cooldown on OTA triggers per device, mirroring the same
  reasoning as the gateway `registerDevice` rate-limiting item already open
  in `Security_Review.md` — low priority, no known exploit path today, but
  cheap to add if the threat model tightens.
