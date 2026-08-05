# Firmware Publishing Guide — build once, publish with one click

This is the full start-to-finish process for shipping a firmware update to
the DSGV Hub fleet: how to build the `.bin`, how to set up the publish system
(one time only), and how to actually publish a release afterward.

**The two halves of this are different skill levels, on purpose:**
- **Building firmware** still requires ESP-IDF and embedded know-how — that
  part can't be made "no developer needed," someone has to actually write and
  compile the code.
- **Publishing a built `.bin` to the fleet** needs none of that, once set up.
  It's a web page: pick the device type, choose the file, click Publish.
  No git, no command line, no GitHub account.

See `IoT_APP_Design/OTA_Update_Design.md` for the security model (auth,
integrity, TLS) this all sits on top of — this guide is the operational
"how," that doc is the "why."

---

## Part A — One-time setup (do this once, ever)

You did something very similar already when you first set up
`cloudflare_gateway/` (per `SETUP_GUIDE.md`), so the tools below should
already be installed. This section assumes nothing, though — read it even if
you think you remember.

**What you're about to do, in plain terms:** Cloudflare hosts two things for
you — a password that proves it's really you publishing (called a "secret"),
and the actual code that runs the publish button (the "Worker"). Firmware
files themselves get stored in the same KV namespace you already set up when
you first deployed `cloudflare_gateway/` — nothing new to create there. You're
just setting the password and uploading the updated code. Both are one-time.

### Step 0 — Open a terminal in the right folder

A "terminal" (also called PowerShell, Command Prompt, or a shell) is a
text-based window where you type commands instead of clicking buttons. On
Windows:

1. Open **File Explorer** and navigate to
   `C:\Users\Chijioke\Documents\IoT-Project\cloudflare_gateway`.
2. Right-click inside that folder (on empty space, not on a file) and choose
   **Open in Terminal** (Windows 11) or **Open PowerShell window here**
   (Windows 10). If neither option appears, open PowerShell normally from the
   Start menu and type `cd C:\Users\Chijioke\Documents\IoT-Project\cloudflare_gateway`
   then press Enter.
3. You should now see a blinking cursor after a line that ends in
   `...\cloudflare_gateway>`. Every command below gets typed here, then you
   press **Enter** to run it.

### Step 1 — Confirm Wrangler is installed

Wrangler is Cloudflare's own command-line tool — it's what actually talks to
your Cloudflare account to create things and upload code. Type:
```
wrangler --version
```
and press Enter. You should see a version number print out (e.g.
`⛅️ wrangler 4.x.x`). **If instead you see an error like "wrangler is not
recognized,"** it's not installed — go back to `SETUP_GUIDE.md` step 2 and
run `npm install -g wrangler`, then come back here.

> **A storage option we deliberately did *not* use:** Cloudflare R2 (their
> S3-equivalent) would have been the obvious choice for storing `.bin` files,
> but R2 requires adding a credit card to your Cloudflare account to enable
> it at all — even though usage within its free tier costs $0, the
> requirement itself breaks the "genuinely free, no card" bar this whole
> project holds itself to. Firmware binaries here are small enough (a few MB
> at most) to just live in the same Workers KV namespace you already have —
> no card, no new service, one less thing to set up.

### Step 2 — Set your admin password (the "secret")

This is the password you'll type into the publish web page every time you
want to ship an update. Cloudflare stores it securely on their servers — it
never appears anywhere in this repo, and once you set it you can't view it
again (only replace it).

**First, pick a password.** Anything long and hard to guess works — for
example, mash your keyboard for 20-30 characters, or use a password manager's
"generate password" feature. Write it down somewhere you'll find again (a
password manager, a note app, anywhere private) — **if you lose it, you
simply set a new one with the same command below, no harm done.**

Then type:
```
wrangler secret put ADMIN_PUBLISH_KEY
```
Press Enter. It will ask you to paste or type your password. **Important:**
when you type or paste it, you usually won't see any characters appear on
screen at all (not even dots) — this is completely normal for password
entry in a terminal, it's not frozen or broken. Just paste/type it and press
Enter once. You'll see a confirmation message once it's saved.

### Step 3 — Upload the new code to Cloudflare ("deploy")

Everything so far just prepared Cloudflare's side. This step actually
uploads the Worker's code (the logic behind the publish button) so it's live
and working. Type:
```
wrangler deploy
```
Press Enter and wait a few seconds. You'll see some build output, and at the
end a line showing your Worker's web address again — something like
`https://dsgv-hub-gateway.tectinkers.workers.dev`. **Seeing that URL print
successfully means it worked.** If you see red error text instead, copy it
and we can troubleshoot — most commonly it means Step 2 above wasn't
completed first.

**You will only repeat this one command (`wrangler deploy`) if the Worker's
code itself ever changes in the future** — for example, if I make further
improvements to `cloudflare_gateway/src/index.js`. Step 2 (setting the
password) never needs to be repeated.

### Step 4 — Open the publish page for the first time

`cloudflare_gateway/admin/publish.html` is a single file — not a website you
need to visit, not something that needs installing. It's just a web page
saved on your computer.

1. In File Explorer, go to
   `C:\Users\Chijioke\Documents\IoT-Project\cloudflare_gateway\admin`.
2. **Double-click `publish.html`.** It opens directly in your default web
   browser (Chrome, Edge, whatever you normally use) — no internet loading
   spinner, because the page itself is just sitting on your computer.
3. You'll see a page titled "DSGV Hub — Publish Firmware" with a few boxes:
   - **Gateway URL** — already filled in for you, leave it as is.
   - **Admin key** — paste the password you created in Step 2 here.
   - Click the **"Remember for this tab"** button next to it. This saves the
     password just for as long as this browser tab stays open, so you don't
     have to retype it every time you publish something in this session. It
     is **not** saved permanently anywhere, and closing the tab clears it —
     that's intentional, for security.
4. Below that you'll see the actual publish form (device type, version,
   notes, file) and a table showing what's currently published — it'll say
   "Nothing published yet" until you publish your first release in Part C.

**You can bookmark this file, or just remember where it is** — you'll come
back to this exact page every time you want to ship an update, from now on.

*Optional, not required:* if you'd like a proper web address for this page
instead of a file on your computer (e.g. so a teammate without access to
this folder could use it too), you can host it for free via Cloudflare
Pages — this is covered as an optional extra later in this guide, skip it
for now if it's just you publishing.

---

## Part B — Building a `.bin` (needed every release; requires ESP-IDF)

1. Bump the version somewhere you track it (e.g. `project(dsgv_<device>
   VERSION "1.3.0")` in that device's `CMakeLists.txt`, if you use that as
   your source of truth — otherwise just remember what version you're about
   to publish, you'll type it into the publish page directly).
2. Build:
   ```powershell
   .\scripts\build_device.ps1 <device> <chip> [-FlashMB 4|8]
   ```
   or the raw ESP-IDF flow from inside `devices/<device>/`:
   ```bash
   idf.py -DIDF_TARGET=<chip> build
   ```
   `<chip>` is whichever this device's hardware actually is (esp32 / esp32c3
   / esp32c6 / esp32s3) — see `FLASHING_GUIDE.md` for the per-device mapping.
3. The output binary lands at `devices/<device>/build/dsgv_<device>.bin`
   (check the exact filename in that folder if your project name differs).

That `.bin` is now ready for Part C — no manual hashing step needed anymore,
the publish page computes the SHA-256 for you server-side.

---

## Part C — Publishing a release (no developer tools needed)

This is the part you'll repeat every single time you have a new firmware
build ready — and it's short. Once Part A is done, you never touch a
terminal for this again.

1. **Open the publish page.** Go to
   `C:\Users\Chijioke\Documents\IoT-Project\cloudflare_gateway\admin` in File
   Explorer and double-click `publish.html`. It opens in your browser.
2. **Enter your admin key**, if this browser tab doesn't already remember it
   from earlier (see Part A, Step 4). If the "Admin key" box already has dots
   in it, you're set — skip to the next step.
3. **Fill in the form**, one field at a time:
   - **Device type** — click the dropdown and pick the one matching the
     firmware you built. For example, if you built firmware for a single-gang
     wall switch, pick `1gang_switch`. This has to match exactly, or the app
     won't recognize it.
   - **Version** — type a version number, e.g. `1.3.0`. This is just a label
     you're choosing — pick something higher/newer-looking than whatever the
     device is currently running, so the app knows an update exists. A
     simple `major.minor.patch` scheme (like `1.0.0` → `1.0.1` → `1.1.0`)
     works fine; there's no required format.
   - **Release notes** *(optional)* — a short plain-English sentence about
     what changed, e.g. "Fixed the light flickering when dimmed below 10%."
     This gets shown in the app to whoever updates the device — helpful for
     yourself later, or for anyone else using the app.
   - **Firmware file** — click **Choose File** (or the box next to it) and
     browse to the `.bin` file you built in Part B (it's inside that
     device's `build` folder). Select it.
4. **Click the Publish button.** A few things happen automatically, in
   about 1-3 seconds:
   - The file uploads to Cloudflare's storage.
   - Cloudflare calculates a security fingerprint (the SHA-256 hash) of the
     exact file you uploaded — you don't calculate or type this yourself
     anywhere, which removes the step most likely to go wrong if done by
     hand.
   - The "what's the current version for this device type" record gets
     updated.
5. **Look for the confirmation message** under the Publish button. It'll turn
   green and show something like:
   ```
   Published 1gang_switch v1.3.0
   SHA-256: 3f9a2b1c...
   ```
   If instead it turns red with an error message, see the Troubleshooting
   table near the bottom of this guide.
6. **Check the table at the bottom of the page** ("Currently published") —
   it refreshes itself right after a successful publish, so you can see at a
   glance every device type and what version is live for it.

**That's the whole process.** No git commit, no pull request, no version
tag, no waiting for a build pipeline. From the moment you click Publish,
anyone opening that device type in the app will see the update is available.

### What happens on the device side
The app already polls the gateway's manifest (`getFirmwareManifest`) —
nothing to configure there. When a user opens a device with an older
`firmwareVersion` than what's published, the app shows an "Update to vX.Y.Z"
button. Tapping it sends the auth-gated OTA trigger over MQTT exactly as
before; the device downloads from `/firmware/{device_type}` (TLS-verified),
verifies the SHA-256 you saw on the publish page, and only then reboots into
the new image.

---

## Verifying it worked

```bash
curl https://dsgv-hub-gateway.<your-subdomain>.workers.dev/getFirmwareManifest
```
Should show the device type you just published, with its version and hash.

```bash
curl -I https://dsgv-hub-gateway.<your-subdomain>.workers.dev/firmware/1gang_switch
```
Should return `200 OK` with a `Content-Length` matching your `.bin`'s size.

On real hardware: trigger the update from the app, watch the device's serial
log for `OTA: SHA-256 verified OK.` followed by a reboot into the new
version.

---

## Rotating the admin key

If the key ever leaks, or someone who had it shouldn't anymore:
```bash
wrangler secret put ADMIN_PUBLISH_KEY
```
This immediately replaces it — the old key stops working the moment the new
one is set. Update anyone who legitimately still needs to publish.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Publish page shows "Unauthorized" | Wrong or expired admin key — re-paste it, or re-run `wrangler secret put ADMIN_PUBLISH_KEY` if you're not sure what it currently is |
| "Unknown device_type" | Device-type dropdown value doesn't match `CONFIG_DSGV_DEVICE_TYPE` exactly — check spelling/underscores |
| App still shows the old version after publishing | The app's manifest fetch is on-demand (tap "Check for updates") — it doesn't push, it's pulled when the device screen is opened |
| Device downloads but SHA-256 mismatch on-device | You published a different file than the one you actually flashed to a test unit, or the file got corrupted mid-transfer — re-publish and retry |
| Publish fails with "File must be between 1 byte and..." | The `.bin` is larger than the sanity cap (`MAX_FIRMWARE_BYTES` in `src/index.js`) — check you selected the right file, not an old/corrupt build |
| `wrangler r2 bucket create...` / "Please enable R2" error | You don't need R2 for this project — that command isn't part of this guide. Firmware storage uses the KV namespace you already set up; if you see this error it means an old step was followed by mistake |
