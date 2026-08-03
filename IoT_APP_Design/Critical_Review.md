# DSGV Hub — Critical Review

A principal-engineer-style pass over the current architecture and the in-flight changes, not assuming any prior decision is correct. Prioritized, most important first.

---

## 1. The "dynamic capability schema" premise doesn't match what's being built

`IoT_Architecture_Whitepaper.md` §2 sells a specific promise: ship new hardware without an app update, because the app parses a device-broadcast JSON schema at runtime. The change actually landed (`device_type_registry.dart`) moves the opposite direction — capability metadata is now a **static, compiled Dart map**, centralizing what used to be scattered inline in `schema_driven_ui_builder.dart`. That's a legitimate refactor (less duplication, one source of truth for labels/icons/ranges), but it quietly abandons the headline architectural claim without anyone deciding to.

**Why this matters:** if "new hardware, no app update" is actually a product requirement (it's positioned as one in the whitepaper), the team is currently building away from it, not toward it, and nobody has flagged that trade-off explicitly. If it's *not* actually a hard requirement, the whitepaper is overselling and should say so — a false promise in an architecture doc is worse than no promise, because it will surface as a surprised stakeholder or a customer commitment made on outdated information.

**Recommendation:** make this an explicit decision, not a side effect. Either (a) keep the registry approach and rewrite whitepaper §2 to describe the real model — "app ships with known device types, adding one is a minor version bump" — or (b) if the dynamic-schema promise is load-bearing for sales/partnerships, treat the registry as an interim step and put the device-broadcast-schema work back on the roadmap explicitly.

## 2. A fully-built feature just shipped dark — that's a process smell, not just a bug

`GroupsScreen` is complete: create/delete groups, add/remove devices, bulk on/off, all correctly persisted. It is not reachable from anywhere in the app. That's not "almost done," it's **done and then not connected** — which usually means the navigation-wiring step got dropped between two work sessions, or scope was intentionally held back and nobody left a note saying so.

**Why this matters:** shipping unreachable code isn't free — it's untested from a real-user path (no one has actually clicked through the flow the way a user would, e.g. does the FAB dialog handle a duplicate group name gracefully?), and it will bit-rot silently if forgotten, becoming a liability the next time `device_entity.dart` changes shape.

**Recommendation:** treat "wire it in" as part of the definition of done for this feature, not a follow-up. If it's being held back deliberately (e.g., pending design review of the UX), say so in a code comment or tracking issue — right now there's no signal distinguishing "forgot" from "on purpose."

## 3. Bulk group control was designed for the simple case and will misbehave on the real fleet

`sendCommandToGroup` sends `{'power': bool}` uniformly. The product already ships multi-gang switches (1/2/3/4-gang) and non-relay types (sensors, thermostats, RGB, colour-temp) per the 11 device targets in firmware. A group containing a mix of these — which is the *normal* case for a "living room" or "downstairs" group, not an edge case — will silently do nothing for most of its members on "all off."

**Why this matters:** this is a trust-eroding bug, not a cosmetic one. A user who presses "all off" and later discovers a device stayed on will stop trusting the group feature (and by extension the app) for anything safety-adjacent (space heaters, humidifiers).

**Recommendation:** before this ships, `sendCommandToGroup` needs to branch on each member's type/capabilities (using the very `DeviceTypeRegistry` just introduced) and send the right command shape per device, or the UI needs to restrict grouping to same-type devices until that logic exists.

## 4. Security posture: the gaps are the well-known ones, and the guide already knew about them

Nothing found in this review is novel — `PRE_PRODUCTION_GUIDE.md` already documents the OTA cert-pinning and Secure Boot gaps as known pre-ship TODOs. The finding here isn't "here's a hidden vulnerability," it's: **these are the last-mile items and they're still open**, which means the project has been in "documented but not yet done" state for at least the last few commits (the guide predates this session). That's fine as an interim state during active feature work (device groups, event system), but it means production hardening has been consistently deprioritized behind feature work.

**Recommendation:** given items 1, 2, 5 in the Go/No-Go doc collapse to one fix (enable Secure Boot v2 + Flash Encryption, pin the cert), this is a half-day of focused work, not a redesign. Worth doing before the next feature lands rather than after, since it only gets more disruptive to enable Secure Boot once more devices are in the field running unsigned firmware.

## 5. The Firebase broker-config path may be dead in the water, and that's worth confirming now, not discovering later

`dsgv_firebase.c` implements exactly what the README and whitepaper describe (fetch broker config from Firebase, persist to NVS) but isn't compiled into any build target. Either:
- it's genuinely obsolete (config delivery happens some other way now, and the docs are stale), or
- it's a regression (got dropped during the `main/`→`components/` refactor and nobody noticed because nothing currently depends on it failing).

**Why this matters:** the difference between those two is the difference between "no action needed, update the docs" and "the core value prop of the platform (change the broker from the app, every device picks it up silently) is currently broken in firmware." This is a five-minute check with a potentially large blast radius if it's the second case.

**Recommendation:** confirm which is true before the next release, and either wire `dsgv_firebase.c` into a `CMakeLists.txt` or remove it and update the README/whitepaper to describe the actual config-delivery mechanism.

## 6. Cost/complexity note: dual-broker + Matter dual-stack + custom app is a lot of ongoing surface for a small team

Not a defect, but worth naming: the whitepaper commits to EMQX cloud + local Mosquitto bridge/failover + Matter CHIP SDK dual-stack + a fully custom Flutter app with its own capability registry. Each of those is independently reasonable; together they're four separate integration surfaces that all need to stay in sync (e.g., item 1 above shows the capability registry already drifting from the schema story). If the team is small, this is the kind of architecture that looks right on a whiteboard and then consumes disproportionate maintenance time keeping the pieces mutually consistent as any one of them evolves.

**Recommendation:** no immediate action, but worth a periodic (quarterly?) check that the four surfaces haven't drifted from each other the way the schema story already has — cheaper to catch a second drift early than to discover three simultaneously.

---

## Priority Order

1. Decide and document the capability-schema trade-off (registry vs. dynamic) — item 1
2. Fix or gate the group bulk-control per-type command bug — item 3
3. Confirm whether Firebase config delivery is live or dead, act accordingly — item 5
4. Wire up or explicitly shelve `GroupsScreen` — item 2
5. Close the Secure Boot / OTA pinning gap — item 4 (see `Security_Review.md` for detail)
6. Ongoing: watch for further drift across the four architectural surfaces — item 6
