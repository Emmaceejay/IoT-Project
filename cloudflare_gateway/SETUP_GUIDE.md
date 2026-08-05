# Cloudflare Gateway Setup Guide

This is the device-config gateway: a small server (`registerDevice`,
`getDeviceConfig`, `updateDeviceConfig`, `revertDeviceToFactory`) that both
the DSGV Hub app and every device's firmware talk to, so devices can get
their MQTT broker credential without that credential ever being compiled
into firmware. Runs entirely on Cloudflare's free tier: **no credit card, no
Firebase, no paid plan of any kind.**

## Why this exists (read this first — for future-you)

### The problem it solves
Devices need MQTT broker credentials (host, port, TLS, username, password)
to talk to HiveMQ Cloud. The naive approach — compile one shared
username/password into every device's firmware — has a real security cost:
**a single flash dump or leaked firmware binary from any one device exposes
the login for the entire fleet**, since HiveMQ Cloud uses one credential per
cluster. Not acceptable for a commercial product.

The fix: every device already gets its own unique `auth_token` at
BLE-provisioning time (this token also gates the device's local HTTP API —
see `Security_Review.md`). This gateway is what a device calls, authenticated
with *that* per-device token, to fetch the *shared* broker credential
server-side. The broker credential itself never lives in firmware. If one
device is compromised, only its own `auth_token` leaks — not the fleet's
broker password.

A second, related benefit: **credential rotation.** If the broker password
ever needs to change (suspected leak, routine rotation), it's one
`wrangler secret put` here — every device picks up the new value on its next
boot/reconnect. Without this gateway, rotation would mean re-flashing every
device in the field.

### Why Cloudflare, and not Firebase (the first thing tried)
Firebase Cloud Functions was the original design and was fully built before
being abandoned: **Firebase requires the paid "Blaze" (pay-as-you-go) plan to
deploy *any* Cloud Function at all** — not just ones that touch paid
features. Confirmed empirically (not assumed) via two separate
`firebase deploy` attempts, both blocked on Google Cloud trying to enable
`secretmanager.googleapis.com` / `artifactregistry.googleapis.com`, which
only provision on Blaze.

Cloudflare Workers has no equivalent restriction. Verified directly against
Cloudflare's own pricing docs before committing to this migration:

| Resource | Free tier limit |
|---|---|
| Workers requests | 100,000 / day |
| Workers CPU time | 10 ms / invocation |
| Workers KV reads | 100,000 / day |
| Workers KV writes | 1,000 / day |
| Workers KV deletes | 1,000 / day |
| Workers KV storage | 1 GB |
| Credit card required | No |

This project's usage (register a device once at provisioning, occasional
broker-config pushes, one config fetch per boot) sits far inside every one
of those limits.

### Why Workers KV, and not Cloudflare Workers + Firebase Realtime Database
An intermediate design used Cloudflare Workers for compute but kept Firebase
Realtime Database for storage, bridged with a Firebase service-account/OAuth
flow. That still meant a Firebase project, a service-account key, and
Firebase-specific setup for something meant to be simple and free. Moving
storage onto **Workers KV** (Cloudflare's own key-value store, bound to the
Worker with a one-line config, no separate account or credential) removed
Firebase from the architecture entirely — no service account, no JWT
signing, no extra dependency (`jose` was dropped). One platform to sign up
for, not two.

The one real tradeoff: KV is *eventually consistent* (a write can take up to
~60s to reach all edge locations) and caps writes at 1,000/day. Neither
matters here — broker changes are rare and user-initiated, and the device
already treats a broker change as "takes effect next reboot" with a 60s
rollback watchdog already built into the firmware (`dsgv_mqtt.c`).

### Why `getDeviceConfig` doesn't update `last_seen` on every call
It's called on **every device boot**, so a write there would scale with
fleet size × reboot frequency and could realistically burn through the
1,000-writes/day cap on a large fleet. `last_seen` is written once, in
`registerDevice` (provisioning-time only), and was never read back by app or
firmware anyway — so dropping the per-boot write costs nothing and keeps
write volume flat regardless of usage.

### Other problems fixed in the same effort (bundled into this migration)
- **Local HTTP API had no authentication** — any device on the same WiFi
  network could hit a device's local REST endpoints with no credential.
  Fixed by requiring `Authorization: Bearer <auth_token>` on every route
  (`dsgv_http_server.c`) — the same token this gateway uses.
- **Broker-credential leak across broker switches** — when a user pushed a
  custom MQTT broker from the app, the device didn't always overwrite its
  stored username/password, so it could silently keep using a *previous*
  broker's credential against a *new* host. Fixed: `handle_config()` now
  always explicitly writes (or clears) username/password on every broker
  change, and snapshots the prior ones for the rollback watchdog.

### Where this sits in the device boot sequence
NVS init → device config load → TCP/IP + event loop → GPIO → WiFi connect →
**HTTP server starts** → **gateway fetch (this service)** → MQTT connect.

The HTTP server deliberately starts *before* the gateway fetch, so local
WiFi control keeps working even if this gateway is unreachable (no internet,
Worker down, etc.) — only the cloud/MQTT path depends on it.

### Quick recall reference (fill in as your own deployment changes)
| What | Where |
|---|---|
| Live gateway URL | `https://dsgv-hub-gateway.tectinkers.workers.dev` |
| KV namespace | `DSGV_KV` — id recorded in `wrangler.toml` |
| Broker | HiveMQ Cloud — host in `MQTT_CLOUD_HOST` (`dsgv_config.h`) and `FACTORY_CONFIG_BASE` (`src/index.js`), must match |
| Secrets | Only in Cloudflare (`wrangler secret put`) — never committed to this repo |
| Firmware call site | `dsgv_gateway.c`, URL constant `GATEWAY_GET_CONFIG_URL` in `dsgv_config.h` |
| App call site | `gateway_config_service.dart`, URL constant `_kGatewayBase` |
| Auth | Per-device `auth_token` from BLE provisioning, reused for both local HTTP API and gateway calls |

---

## Setup Steps

Every step below shows the CLI command (what this project has used
throughout — reproducible, scriptable) with the equivalent Cloudflare
dashboard path noted alongside, since the dashboard UI works just as well if
you'd rather click through it.

---

## 1. Create a Cloudflare account

Sign up at https://dash.cloudflare.com/sign-up — email + password, no
payment method requested anywhere in this flow.

## 2. Install Wrangler and log in

```bash
npm install -g wrangler
wrangler login
```

This opens a browser tab to authorize the CLI against your account, then
returns control to the terminal — same pattern as `firebase login` if you've
used that before. Confirm it worked:

```bash
wrangler --version
wrangler whoami
```

*Dashboard equivalent:* none needed for this step — logging in is CLI-only,
the dashboard uses your normal browser session.

## 3. Create the KV namespace

This is where `device_registry` and `device_configs` live — the replacement
for Firebase Realtime Database.

```bash
cd cloudflare_gateway
wrangler kv namespace create DSGV_KV
```

This prints an `id`. Open `wrangler.toml` and replace
`REPLACE_WITH_ID_FROM_wrangler_kv_namespace_create` with that value:

```toml
[[kv_namespaces]]
binding = "DSGV_KV"
id = "the id wrangler just printed"
```

*Dashboard equivalent:* **Workers & Pages → KV** (left sidebar) → **Create
instance** → name it `DSGV_KV` → **Create**. If you go this route, still add
the `[[kv_namespaces]]` block above to `wrangler.toml` yourself using the ID
shown on the namespace's page — Wrangler needs it there to build the binding
when you deploy.

## 4. Set the two secrets

```bash
wrangler secret put MQTT_BROKER_USERNAME
wrangler secret put MQTT_BROKER_PASSWORD
```

Each prompts interactively — type or paste the value and press Enter. These
never appear in any file in this repo.

*Dashboard equivalent:* deploy the Worker first (next step), then **Workers &
Pages → Overview → select your Worker → Settings → Variables and Secrets →
Add** → type **Secret** → enter the variable name and value → **Deploy**.
Secret values aren't visible again in the dashboard or CLI once set, on
either path — only replaceable.

## 5. Install dependencies and deploy

```bash
npm install
wrangler deploy
```

First deploy creates the Worker and prints its URL:

```
https://dsgv-hub-gateway.<your-subdomain>.workers.dev
```

`<your-subdomain>` is assigned to your account the first time you ever
deploy any Worker — it's yours from then on for every future Worker too.

*Dashboard equivalent:* **Workers & Pages → Overview → Create → Workers →
Deploy with CLI** still requires Wrangler for the actual code upload (the
dashboard's own code editor is meant for quick edits, not this project's
multi-file source) — so deployment itself is CLI-only here, even if you used
the dashboard for steps 3–4.

## 6. Verify it's live

```bash
curl -X POST https://dsgv-hub-gateway.<your-subdomain>.workers.dev/registerDevice \
  -H "Content-Type: application/json" \
  -d "{\"device_id\":\"AABBCCDDEEFF\",\"auth_token\":\"00000000000000000000000000000000\"}"
```

(That `auth_token` is 32 zeros — fine for this connectivity check, replace
`AABBCCDDEEFF` with any 12 hex chars.) A JSON response like
`{"success":true}` confirms routing, validation, and KV read/write all work.
Check **Workers & Pages → KV → DSGV_KV** in the dashboard — you should see a
new `device_registry:AABBCCDDEEFF` key.

## 7. Point the app and firmware at your deployed URL

Replace the placeholder base URL in these two files with the URL from step 5:

```
dsgv_hub_app/lib/domain/services/gateway_config_service.dart   _kGatewayBase
dsgv_firmware/components/dsgv_common/include/dsgv_config.h     GATEWAY_GET_CONFIG_URL (append /getDeviceConfig)
```

## 8. Local testing before redeploying changes

```bash
wrangler dev
```

Runs the Worker locally at `http://localhost:8787`. For local secret values
(so `wrangler dev` doesn't need the real ones), create a `.dev.vars` file in
`cloudflare_gateway/` (already gitignored):

```
MQTT_BROKER_USERNAME=admin1
MQTT_BROKER_PASSWORD=your-local-test-password
```

This file is never deployed or committed — it's purely for local `wrangler
dev` runs.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `wrangler: command not found` after install | npm's global bin dir isn't on PATH, or your terminal was open before the install — open a fresh terminal (or fully restart your IDE, not just its terminal panel — see below) |
| PATH fix doesn't take effect in a new terminal tab | If you're in VS Code, a new terminal *tab* inherits the environment VS Code itself started with. Fully quit and relaunch VS Code (not just the terminal panel) to pick up a PATH change |
| `curl` returns `{"error":"Not found"}` | Check the path matches exactly one of the four routes (case-sensitive: `/registerDevice`, not `/registerdevice`) |
| `curl` returns `{"error":"Internal error", ...}` | Usually the KV namespace `id` in `wrangler.toml` doesn't match a real namespace — re-check step 3 |
| Device's serial log shows `Gateway config fetch failed` | Confirm `GATEWAY_GET_CONFIG_URL` in `dsgv_config.h` has your real subdomain, not the `YOUR_SUBDOMAIN` placeholder, and that the device has internet access |
