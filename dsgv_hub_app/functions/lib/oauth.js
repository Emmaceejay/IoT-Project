/**
 * oauth.js — OAuth 2.0 Authorization Server for C2C Account Linking.
 *
 * Both Google Home and Amazon Alexa require your cloud to implement an
 * OAuth 2.0 server so users can "link" their DSGV account to their voice
 * assistant. This is how Google / Alexa proves to your cloud that it has
 * permission to control a specific user's devices.
 *
 * --- The flow (simplified) ---
 *
 *   1. User opens Google Home app and taps "Link Account".
 *   2. Google redirects the user's browser to /oauth/authorize?client_id=...
 *   3. The user sees a login form (served by /oauth/loginPage).
 *   4. User enters their DSGV email + password.
 *   5. We verify with Firebase Auth. On success we create an auth code.
 *   6. We redirect the browser back to Google with ?code=<auth_code>.
 *   7. Google immediately calls /oauth/token to exchange the code for tokens.
 *   8. We return { access_token, refresh_token, expires_in }.
 *   9. Google stores the access_token and sends it with every future request.
 *
 * --- Security design ---
 *
 *   • Tokens are stored as SHA-256 hashes in Firebase — never in plaintext.
 *   • Auth codes expire in 10 minutes and can only be used once.
 *   • client_secret is verified with crypto.timingSafeEqual (no timing leaks).
 *   • redirect_uri is validated against a per-client whitelist.
 *   • User passwords are never stored by us — we verify via Firebase Auth REST.
 *
 * --- Configuration (set via Firebase Functions config) ---
 *
 *   firebase functions:config:set \
 *     oauth.google_client_id="GOOGLE_CLIENT_ID_HERE" \
 *     oauth.google_client_secret="GOOGLE_CLIENT_SECRET_HERE" \
 *     oauth.alexa_client_id="ALEXA_CLIENT_ID_HERE" \
 *     oauth.alexa_client_secret="ALEXA_CLIENT_SECRET_HERE" \
 *     oauth.firebase_web_api_key="YOUR_FIREBASE_WEB_API_KEY" \
 *     oauth.token_secret="RANDOM_32_BYTE_HEX_FOR_SIGNING"
 *
 * Retrieve your Firebase Web API key from:
 *   Firebase Console → Project Settings → General → Web API key
 */

const crypto  = require("crypto");
const admin   = require("firebase-admin");
const fetch   = require("node-fetch");     // included with Firebase Functions runtime
const functions = require("firebase-functions");

const db = admin.database();

// ── Configuration ─────────────────────────────────────────────────────────────
// Read from Firebase Functions runtime config so secrets stay out of source code.
// Fall back to environment variables for local emulator testing.

function getCfg() {
  const cfg = functions.config();
  return {
    googleClientId:     cfg.oauth?.google_client_id     || process.env.GOOGLE_CLIENT_ID,
    googleClientSecret: cfg.oauth?.google_client_secret || process.env.GOOGLE_CLIENT_SECRET,
    alexaClientId:      cfg.oauth?.alexa_client_id      || process.env.ALEXA_CLIENT_ID,
    alexaClientSecret:  cfg.oauth?.alexa_client_secret  || process.env.ALEXA_CLIENT_SECRET,
    firebaseWebApiKey:  cfg.oauth?.firebase_web_api_key || process.env.FIREBASE_WEB_API_KEY,
    tokenSecret:        cfg.oauth?.token_secret         || process.env.TOKEN_SECRET || "changeme",
  };
}

// ── Token generation helpers ──────────────────────────────────────────────────

/**
 * Generate a cryptographically secure random token.
 * Returns a 48-byte buffer encoded as 96 hex characters.
 */
function generateToken() {
  return crypto.randomBytes(48).toString("hex");
}

/**
 * Hash a token for safe storage in Firebase.
 * We store sha256(token) so that even a database breach reveals nothing usable.
 */
function hashToken(token) {
  return crypto.createHash("sha256").update(token).digest("hex");
}

/**
 * Constant-time string comparison to prevent timing attacks.
 * Always compare secrets using this instead of ===.
 */
function safeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

// ── Client registry (which OAuth clients are allowed) ────────────────────────

/**
 * Validate that the incoming client_id + client_secret pair is legitimate.
 * Returns the client record (with its allowed redirect URIs) or null.
 *
 * Google and Alexa get separate client_id values so we can revoke one
 * independently without affecting the other.
 */
function getOAuthClient(clientId) {
  const cfg = getCfg();
  const clients = {
    [cfg.googleClientId]: {
      name: "google_home",
      secret: cfg.googleClientSecret,
      // Google provides its redirect URI during Smart Home Action setup.
      // It always matches this pattern for production actions:
      allowedRedirectPrefixes: ["https://oauth-redirect.googleusercontent.com"],
    },
    [cfg.alexaClientId]: {
      name: "alexa",
      secret: cfg.alexaClientSecret,
      allowedRedirectPrefixes: ["https://pitangui.amazon.com", "https://layla.amazon.com", "https://alexa.amazon.co.jp"],
    },
  };
  return clients[clientId] || null;
}

// ── Firebase Auth verification ────────────────────────────────────────────────

/**
 * Verify a user's email + password against Firebase Authentication.
 * Returns the Firebase UID on success, or throws on failure.
 *
 * We use the Firebase Auth REST API because the Admin SDK does not expose
 * a password-verification method (by design — it's a server-side SDK).
 * The REST API is the documented approach for custom auth flows.
 */
async function verifyFirebaseCredentials(email, password) {
  const { firebaseWebApiKey } = getCfg();
  if (!firebaseWebApiKey) {
    throw new Error("FIREBASE_WEB_API_KEY not configured");
  }

  // Firebase Auth REST sign-in endpoint
  const url = `https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${firebaseWebApiKey}`;
  const resp = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, password, returnSecureToken: true }),
  });

  const data = await resp.json();
  if (!resp.ok || data.error) {
    // Normalise error so we don't leak whether the email or password was wrong
    throw new Error("Invalid credentials");
  }

  // Verify the returned ID token with the Admin SDK to get the authoritative UID
  const decoded = await admin.auth().verifyIdToken(data.idToken);
  return decoded.uid;
}

// ── /oauth/loginPage ──────────────────────────────────────────────────────────

/**
 * GET /oauth/loginPage?client_id=…&redirect_uri=…&state=…&scope=…
 *
 * Serves a minimal HTML login form. The form POSTs back to /oauth/authorize
 * with all the original parameters preserved as hidden fields.
 *
 * In production you would serve a properly styled page from Firebase Hosting.
 * This inline HTML is functional for testing and initial launch.
 */
exports.oauthLoginPage = functions.https.onRequest((req, res) => {
  const { client_id, redirect_uri, state, scope, response_type } = req.query;

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>DSGV Hub — Sign In</title>
  <style>
    body { font-family: sans-serif; background: #0A0E1A; color: #fff;
           display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; }
    .card { background: #121826; padding: 40px; border-radius: 16px; width: 320px; }
    h2 { margin: 0 0 8px; color: #00E5FF; }
    p  { margin: 0 0 24px; color: #ffffff60; font-size: 14px; }
    input { width: 100%; padding: 12px; margin-bottom: 16px; background: #1E2736;
            border: 1px solid #ffffff20; border-radius: 8px; color: #fff; font-size: 14px;
            box-sizing: border-box; }
    button { width: 100%; padding: 14px; background: #00E5FF; color: #000;
             border: none; border-radius: 8px; font-size: 16px; font-weight: bold; cursor: pointer; }
    .err { color: #ff5555; font-size: 13px; margin-bottom: 12px; }
  </style>
</head>
<body>
  <div class="card">
    <h2>DSGV Hub</h2>
    <p>Sign in to link your smart home devices</p>
    ${req.query.error ? `<p class="err">Invalid email or password. Try again.</p>` : ""}
    <form method="POST" action="/oauth/authorize">
      <input type="hidden" name="client_id"     value="${client_id     || ""}"/>
      <input type="hidden" name="redirect_uri"  value="${redirect_uri  || ""}"/>
      <input type="hidden" name="state"         value="${state         || ""}"/>
      <input type="hidden" name="scope"         value="${scope         || ""}"/>
      <input type="hidden" name="response_type" value="${response_type || "code"}"/>
      <input type="email"    name="email"    placeholder="Email address"  required/>
      <input type="password" name="password" placeholder="Password"       required/>
      <button type="submit">Sign In &amp; Link</button>
    </form>
  </div>
</body>
</html>`;

  res.set("Content-Type", "text/html");
  res.send(html);
});

// ── /oauth/authorize ──────────────────────────────────────────────────────────

/**
 * POST /oauth/authorize
 *
 * Receives the login form submission. Validates the client, verifies the
 * user credentials against Firebase Auth, creates a one-time auth code,
 * and redirects to the platform's redirect_uri with ?code=…&state=….
 *
 * Auth codes:
 *   - 96-character hex string
 *   - Valid for 10 minutes
 *   - Single-use (marked as used on first redemption)
 *   - Stored as sha256(code) in Firebase so the raw code never persists
 */
exports.oauthAuthorize = functions.https.onRequest(async (req, res) => {
  // Support both GET (initial redirect from Google/Alexa) and POST (form submit)
  const params = req.method === "POST" ? req.body : req.query;
  const { client_id, redirect_uri, state, email, password, response_type } = params;

  // Validate redirect to the login page for GET requests (no credentials yet)
  if (req.method === "GET") {
    return res.redirect(
      `/oauth/loginPage?${new URLSearchParams(params).toString()}`
    );
  }

  // --- Validate client ---
  const client = getOAuthClient(client_id);
  if (!client) {
    return res.status(400).send("Unknown client_id");
  }

  // Validate redirect_uri against the client's allowed prefixes
  const redirectOk = client.allowedRedirectPrefixes.some(
    (prefix) => (redirect_uri || "").startsWith(prefix)
  );
  if (!redirectOk) {
    return res.status(400).send("Invalid redirect_uri");
  }

  // --- Verify user credentials ---
  let uid;
  try {
    uid = await verifyFirebaseCredentials(email, password);
  } catch {
    // Redirect back to the login page with an error flag
    const errParams = new URLSearchParams({
      client_id, redirect_uri, state,
      scope: params.scope || "",
      response_type: response_type || "code",
      error: "1",
    });
    return res.redirect(`/oauth/loginPage?${errParams.toString()}`);
  }

  // --- Issue auth code ---
  const code = generateToken(); // 96-char hex
  const codeHash = hashToken(code);

  // Store code metadata. The hash is the key — the raw code is never stored.
  await db.ref(`oauth_codes/${codeHash}`).set({
    uid,
    client_id,
    redirect_uri,
    issued_at: Date.now(),
    used: false,
  });

  // Redirect the user back to Google / Alexa with the auth code
  const callbackUrl = new URL(redirect_uri);
  callbackUrl.searchParams.set("code", code);
  if (state) callbackUrl.searchParams.set("state", state);

  res.redirect(callbackUrl.toString());
});

// ── /oauth/token ──────────────────────────────────────────────────────────────

/**
 * POST /oauth/token
 *
 * Handles two grant types:
 *
 *   grant_type=authorization_code
 *     Exchanges a one-time auth code for access + refresh tokens.
 *     Called by Google/Alexa immediately after receiving the auth code.
 *
 *   grant_type=refresh_token
 *     Exchanges a refresh token for a new access token.
 *     Called by Google/Alexa when the access token expires (every hour).
 *
 * Returns:
 *   { access_token, token_type: "Bearer", expires_in: 3600, refresh_token }
 */
exports.oauthToken = functions.https.onRequest(async (req, res) => {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "method_not_allowed" });
  }

  const { grant_type, code, refresh_token, client_id, client_secret } = req.body;

  // --- Validate client credentials ---
  const client = getOAuthClient(client_id);
  if (!client) {
    return res.status(401).json({ error: "invalid_client" });
  }
  if (!safeEqual(client_secret || "", client.secret || "")) {
    return res.status(401).json({ error: "invalid_client" });
  }

  let uid;

  if (grant_type === "authorization_code") {
    // Exchange auth code for tokens
    if (!code) return res.status(400).json({ error: "invalid_request" });

    const codeHash = hashToken(code);
    const snap = await db.ref(`oauth_codes/${codeHash}`).once("value");

    if (!snap.exists()) {
      return res.status(400).json({ error: "invalid_grant", error_description: "Unknown code" });
    }

    const codeData = snap.val();

    // Check expiry (10 minutes)
    if (Date.now() - codeData.issued_at > 10 * 60 * 1000) {
      return res.status(400).json({ error: "invalid_grant", error_description: "Code expired" });
    }

    // Single-use check
    if (codeData.used) {
      return res.status(400).json({ error: "invalid_grant", error_description: "Code already used" });
    }

    // Validate redirect_uri must match what was used during /authorize
    if (req.body.redirect_uri && req.body.redirect_uri !== codeData.redirect_uri) {
      return res.status(400).json({ error: "invalid_grant", error_description: "redirect_uri mismatch" });
    }

    // Mark the code as used (prevents replay)
    await db.ref(`oauth_codes/${codeHash}/used`).set(true);
    uid = codeData.uid;

  } else if (grant_type === "refresh_token") {
    // Exchange refresh token for a new access token
    if (!refresh_token) return res.status(400).json({ error: "invalid_request" });

    const rtHash = hashToken(refresh_token);
    const snap = await db.ref(`oauth_tokens/${rtHash}`).once("value");

    if (!snap.exists()) {
      return res.status(400).json({ error: "invalid_grant", error_description: "Unknown refresh token" });
    }

    const tokenData = snap.val();
    if (tokenData.type !== "refresh" || tokenData.client_id !== client_id) {
      return res.status(400).json({ error: "invalid_grant" });
    }

    uid = tokenData.uid;

  } else {
    return res.status(400).json({ error: "unsupported_grant_type" });
  }

  // --- Issue access token + refresh token ---
  const accessToken  = generateToken();
  const refreshToken = grant_type === "authorization_code"
      ? generateToken()
      : refresh_token; // reuse existing refresh token on token refresh

  const atHash = hashToken(accessToken);
  const rtHash = hashToken(grant_type === "authorization_code" ? refreshToken : refresh_token);

  // Store access token with 1-hour TTL
  await db.ref(`oauth_tokens/${atHash}`).set({
    uid,
    client_id,
    type: "access",
    expires_at: Date.now() + 3600 * 1000, // 1 hour
  });

  // Store refresh token with 6-month TTL (only on initial code exchange)
  if (grant_type === "authorization_code") {
    await db.ref(`oauth_tokens/${rtHash}`).set({
      uid,
      client_id,
      type: "refresh",
      expires_at: Date.now() + 180 * 24 * 3600 * 1000, // 6 months
    });
  }

  return res.json({
    access_token:  accessToken,
    token_type:    "Bearer",
    expires_in:    3600,
    refresh_token: grant_type === "authorization_code" ? refreshToken : refresh_token,
  });
});

// ── Token validation (used by Google and Alexa handlers) ─────────────────────

/**
 * Validate a Bearer access token from the Authorization header.
 * Returns the Firebase UID associated with the token, or null if invalid/expired.
 *
 * @param {string} authHeader - The full "Authorization: Bearer <token>" header value
 * @returns {Promise<string|null>} - Firebase UID or null
 */
async function validateBearerToken(authHeader) {
  if (!authHeader || !authHeader.startsWith("Bearer ")) return null;
  const token = authHeader.slice(7); // strip "Bearer "
  const tokenHash = hashToken(token);

  const snap = await db.ref(`oauth_tokens/${tokenHash}`).once("value");
  if (!snap.exists()) return null;

  const data = snap.val();
  if (data.type !== "access") return null;
  if (data.expires_at < Date.now()) return null;

  return data.uid;
}

module.exports = { validateBearerToken };
