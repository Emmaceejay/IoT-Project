# Cloudflare Gateway Setup Guide

Full walkthrough for deploying `cloudflare_gateway/` — the device-config
gateway (`registerDevice`, `getDeviceConfig`, `updateDeviceConfig`,
`revertDeviceToFactory`) that the app and firmware both talk to. Runs
entirely on Cloudflare's free tier: **no credit card, no Firebase, no paid
plan of any kind.**

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
