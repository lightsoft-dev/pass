import {
  authenticateDeviceCredential,
  authenticateOIDCUser,
  compactUUID,
  createCredentialMaterial,
  hashSecret,
  randomBase64URL,
  type AuthenticationResult,
  type CredentialIdentity,
  type CredentialMaterial,
  type UserIdentity,
} from "./auth";

const PAIRING_LIFETIME_MS = 5 * 60 * 1_000;
const MAX_JSON_BODY_BYTES = 16 * 1_024;
const INTERNAL_DESKTOP_ID_HEADER = "X-Pass-Internal-Desktop-ID";
const INTERNAL_DEVICE_ID_HEADER = "X-Pass-Internal-Device-ID";
const MOBILE_SCOPES = [
  "sessions:read",
  "sessions:write",
  "sessions:stream",
  "sessions:terminal",
  "projects:read",
  "decisions:answer",
] as const;

type ControlEnv = Env & {
  DEVICE_CREDENTIAL_PEPPER?: string;
  OIDC_ISSUER?: string;
  OIDC_AUDIENCE?: string;
  OIDC_JWKS_URL?: string;
};

type Account = {
  id: string;
  email?: string;
  displayName?: string;
};

type CredentialPair = {
  access: CredentialMaterial;
  refresh: CredentialMaterial;
};

type JSONBody = Record<string, unknown>;

export async function handleControlRequest(
  request: Request,
  env: ControlEnv,
): Promise<Response | null> {
  const url = new URL(request.url);
  if (url.pathname !== "/v2" && !url.pathname.startsWith("/v2/")) return null;

  if (url.pathname === "/v2/me" && request.method === "GET") {
    return handleMe(request, env);
  }
  if (url.pathname === "/v2/account" && request.method === "DELETE") {
    return handleDeleteAccount(request, env);
  }
  if (url.pathname === "/v2/desktops" && request.method === "GET") {
    return handleListDesktops(request, env);
  }
  if (url.pathname === "/v2/desktops" && request.method === "POST") {
    return handleRegisterDesktop(request, env);
  }
  if (/^\/v2\/desktops\/[A-Za-z0-9._:-]+$/.test(url.pathname) && request.method === "DELETE") {
    return handleRevokeDesktop(request, env, url.pathname.split("/").at(-1) ?? "");
  }
  if (url.pathname === "/v2/pairings" && request.method === "POST") {
    return handleCreatePairing(request, env);
  }
  const pairingClaim = /^\/v2\/pairings\/([A-Za-z0-9._:-]+)\/claim$/.exec(url.pathname);
  if (pairingClaim?.[1] && request.method === "POST") {
    return handleClaimPairing(request, env, pairingClaim[1]);
  }
  if (url.pathname === "/v2/deck-pairings" && request.method === "POST") {
    return handleCreateDeckPairing(request, env);
  }
  const deckPairing = /^\/v2\/deck-pairings\/([A-Za-z0-9._:-]+)\/(approve|poll)$/.exec(url.pathname);
  if (deckPairing?.[1] && deckPairing[2] === "approve" && request.method === "POST") {
    return handleApproveDeckPairing(request, env, deckPairing[1]);
  }
  if (deckPairing?.[1] && deckPairing[2] === "poll" && request.method === "POST") {
    return handlePollDeckPairing(request, env, deckPairing[1]);
  }
  if (url.pathname === "/v2/token/refresh" && request.method === "POST") {
    return handleRefreshToken(request, env);
  }
  if (url.pathname === "/v2/devices" && request.method === "GET") {
    return handleListDevices(request, env);
  }
  const device = /^\/v2\/devices\/([A-Za-z0-9._:-]+)$/.exec(url.pathname);
  if (device?.[1] && request.method === "DELETE") {
    return handleRevokeDevice(request, env, device[1]);
  }
  return apiError(404, "not_found", "API route not found.");
}

async function handleCreateDeckPairing(request: Request, env: ControlEnv): Promise<Response> {
  const body = await parseJSONBody(request);
  if (body instanceof Response) return body;
  const deviceName = boundedString(body.deviceName, 100);
  const publicKey = parseDeckPublicKey(body.publicKey);
  if (!deviceName || publicKey === null) {
    return apiError(400, "invalid_request", "Device name and an RSA-OAEP public key are required.");
  }
  const pepper = requiredPepper(env);
  if (pepper instanceof Response) return pepper;
  const now = Date.now();
  const pairingId = `deckpair_${compactUUID()}`;
  const approvalSecret = randomBase64URL(24);
  const pollSecret = randomBase64URL(32);
  const expiresAt = now + PAIRING_LIFETIME_MS;
  const [approveHash, pollHash] = await Promise.all([
    hashSecret(approvalSecret, pepper),
    hashSecret(pollSecret, pepper),
  ]);
  await env.CONTROL_DB.prepare(
    `INSERT INTO deck_pairing_challenges
      (id, approve_secret_hash, poll_secret_hash, public_key_jwk, device_name, created_at, expires_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
  ).bind(pairingId, approveHash, pollHash, JSON.stringify(publicKey), deviceName, now, expiresAt).run();
  return apiResponse({
    pairing: {
      v: 3,
      relayUrl: publicRelayURL(request),
      pairingId,
      approvalSecret,
      pollSecret,
      deviceName,
      expiresAt: isoDate(expiresAt),
    },
  }, 201);
}

async function handleApproveDeckPairing(
  request: Request,
  env: ControlEnv,
  pairingId: string,
): Promise<Response> {
  const context = await accountContext(request, env);
  if (context instanceof Response) return context;
  const body = await parseJSONBody(request);
  if (body instanceof Response) return body;
  const approvalSecret = boundedString(body.approvalSecret, 256);
  const desktopId = boundedString(body.desktopId, 200);
  if (!approvalSecret || !desktopId) return apiError(400, "invalid_request", "Approval secret and desktop id are required.");
  const pepper = requiredPepper(env);
  if (pepper instanceof Response) return pepper;
  const now = Date.now();
  const approvalHash = await hashSecret(approvalSecret, pepper);
  const challenge = await env.CONTROL_DB.prepare(
    `SELECT public_key_jwk, device_name FROM deck_pairing_challenges
      WHERE id = ? AND approve_secret_hash = ? AND approved_at IS NULL AND expires_at > ?`,
  ).bind(pairingId, approvalHash, now).first<{ public_key_jwk: string; device_name: string }>();
  if (challenge === null) return apiError(409, "pairing_unavailable", "Deck pairing code is invalid, expired, or already used.");
  const desktop = await env.CONTROL_DB.prepare(
    "SELECT id, name FROM desktops WHERE id = ? AND account_id = ? AND revoked_at IS NULL",
  ).bind(desktopId, context.account.id).first<{ id: string; name: string }>();
  if (desktop === null) return apiError(404, "not_found", "Desktop not found for this account.");

  const deviceId = `device_${compactUUID()}`;
  const credentials = await createCredentialPair(pepper, now);
  const scopesJSON = JSON.stringify(MOBILE_SCOPES);
  const encrypted = await encryptDeckCredentials(challenge.public_key_jwk, {
    relayUrl: publicRelayURL(request),
    desktopId,
    desktopName: desktop.name,
    deviceId,
    credentials: credentialResponse(credentials),
    scopes: MOBILE_SCOPES,
  });
  if (encrypted instanceof Response) return encrypted;
  const results = await env.CONTROL_DB.batch([
    env.CONTROL_DB.prepare(
      "INSERT INTO devices (id, account_id, name, platform, created_at) VALUES (?, ?, ?, 'unknown', ?)",
    ).bind(deviceId, context.account.id, challenge.device_name, now),
    env.CONTROL_DB.prepare(
      "INSERT INTO desktop_devices (desktop_id, device_id, scopes_json, paired_at) VALUES (?, ?, ?, ?)",
    ).bind(desktopId, deviceId, scopesJSON, now),
    credentialInsert(env.CONTROL_DB, credentials.access, { accountId: context.account.id, subjectType: "device", subjectId: deviceId, desktopId, role: "mobile", scopesJSON }),
    credentialInsert(env.CONTROL_DB, credentials.refresh, { accountId: context.account.id, subjectType: "device", subjectId: deviceId, desktopId, role: "mobile", scopesJSON }),
    env.CONTROL_DB.prepare(
      `UPDATE deck_pairing_challenges SET account_id = ?, desktop_id = ?, device_id = ?,
         credential_envelope = ?, approved_at = ?
       WHERE id = ? AND approve_secret_hash = ? AND approved_at IS NULL AND expires_at > ?`,
    ).bind(context.account.id, desktopId, deviceId, JSON.stringify(encrypted), now, pairingId, approvalHash, now),
  ]);
  if (changes(results[4]) === 0) return apiError(409, "pairing_unavailable", "Deck pairing code was already used.");
  await auditInsert(env.CONTROL_DB, context.account.id, "user", context.identity.subject, "deck_pairing.approve", "device", deviceId, now).run();
  return apiResponse({ approved: true, device: { id: deviceId, name: challenge.device_name }, desktop });
}

async function handlePollDeckPairing(request: Request, env: ControlEnv, pairingId: string): Promise<Response> {
  const body = await parseJSONBody(request);
  if (body instanceof Response) return body;
  const pollSecret = boundedString(body.pollSecret, 256);
  if (!pollSecret) return apiError(400, "invalid_request", "Poll secret is required.");
  const pepper = requiredPepper(env);
  if (pepper instanceof Response) return pepper;
  const pollHash = await hashSecret(pollSecret, pepper);
  const now = Date.now();
  const challenge = await env.CONTROL_DB.prepare(
    `SELECT credential_envelope FROM deck_pairing_challenges
      WHERE id = ? AND poll_secret_hash = ? AND expires_at > ?`,
  ).bind(pairingId, pollHash, now).first<{ credential_envelope: string | null }>();
  if (challenge === null) return apiError(410, "pairing_expired", "Deck pairing code expired or is invalid.");
  if (challenge.credential_envelope === null) return apiResponse({ status: "pending" }, 202);
  await env.CONTROL_DB.prepare(
    "UPDATE deck_pairing_challenges SET delivered_at = COALESCE(delivered_at, ?) WHERE id = ?",
  ).bind(now, pairingId).run();
  return apiResponse({ status: "approved", envelope: JSON.parse(challenge.credential_envelope) as unknown });
}

async function handleMe(request: Request, env: ControlEnv): Promise<Response> {
  const authenticated = await authenticateOIDCUser(request, env);
  if (!authenticated.ok) return authenticationError(authenticated);
  const account = await ensureAccount(env.CONTROL_DB, authenticated.value);
  return apiResponse({ account });
}

async function handleDeleteAccount(request: Request, env: ControlEnv): Promise<Response> {
  const authenticated = await authenticateOIDCUser(request, env);
  if (!authenticated.ok) return authenticationError(authenticated);
  const account = await ensureAccount(env.CONTROL_DB, authenticated.value);
  const desktops = await env.CONTROL_DB.prepare(
    "SELECT id FROM desktops WHERE account_id = ? AND revoked_at IS NULL",
  ).bind(account.id).all<{ id: string }>();
  await env.CONTROL_DB.prepare("DELETE FROM accounts WHERE id = ?").bind(account.id).run();
  await Promise.all(desktops.results.map((desktop) => disconnectRoom(env, desktop.id)));
  return apiResponse({ deleted: true });
}

async function handleListDesktops(request: Request, env: ControlEnv): Promise<Response> {
  const context = await accountContext(request, env);
  if (context instanceof Response) return context;
  const rows = await env.CONTROL_DB.prepare(
    `SELECT id, name, created_at, last_seen_at
       FROM desktops
      WHERE account_id = ? AND revoked_at IS NULL
      ORDER BY created_at DESC`,
  ).bind(context.account.id).all<{
    id: string;
    name: string;
    created_at: number;
    last_seen_at: number | null;
  }>();
  return apiResponse({
    desktops: rows.results.map((row) => ({
      id: row.id,
      name: row.name,
      createdAt: isoDate(row.created_at),
      ...(row.last_seen_at === null ? {} : { lastSeenAt: isoDate(row.last_seen_at) }),
    })),
  });
}

async function handleRegisterDesktop(request: Request, env: ControlEnv): Promise<Response> {
  const context = await accountContext(request, env);
  if (context instanceof Response) return context;
  const body = await parseJSONBody(request);
  if (body instanceof Response) return body;
  const name = boundedString(body.name, 100);
  if (!name) return apiError(400, "invalid_request", "Desktop name is required.");
  const pepper = requiredPepper(env);
  if (pepper instanceof Response) return pepper;

  const now = Date.now();
  const desktopId = `desk_${compactUUID()}`;
  const credentials = await createCredentialPair(pepper, now);
  const scopesJSON = JSON.stringify(["relay:desktop"]);
  await env.CONTROL_DB.batch([
    env.CONTROL_DB.prepare(
      "INSERT INTO desktops (id, account_id, name, created_at) VALUES (?, ?, ?, ?)",
    ).bind(desktopId, context.account.id, name, now),
    credentialInsert(env.CONTROL_DB, credentials.access, {
      accountId: context.account.id,
      subjectType: "desktop",
      subjectId: desktopId,
      desktopId,
      role: "desktop",
      scopesJSON,
    }),
    credentialInsert(env.CONTROL_DB, credentials.refresh, {
      accountId: context.account.id,
      subjectType: "desktop",
      subjectId: desktopId,
      desktopId,
      role: "desktop",
      scopesJSON,
    }),
    auditInsert(env.CONTROL_DB, context.account.id, "user", context.identity.subject, "desktop.register", "desktop", desktopId, now),
  ]);
  return apiResponse({
    desktop: { id: desktopId, name, createdAt: isoDate(now) },
    credentials: credentialResponse(credentials),
    relayUrl: publicRelayURL(request),
  }, 201);
}

async function handleRevokeDesktop(
  request: Request,
  env: ControlEnv,
  desktopId: string,
): Promise<Response> {
  const context = await accountContext(request, env);
  if (context instanceof Response) return context;
  const now = Date.now();
  const results = await env.CONTROL_DB.batch([
    env.CONTROL_DB.prepare(
      "UPDATE desktops SET revoked_at = ? WHERE id = ? AND account_id = ? AND revoked_at IS NULL",
    ).bind(now, desktopId, context.account.id),
    env.CONTROL_DB.prepare(
      "UPDATE credentials SET revoked_at = ? WHERE desktop_id = ? AND account_id = ? AND revoked_at IS NULL",
    ).bind(now, desktopId, context.account.id),
    env.CONTROL_DB.prepare(
      "UPDATE desktop_devices SET revoked_at = ? WHERE desktop_id = ? AND revoked_at IS NULL",
    ).bind(now, desktopId),
    auditInsert(env.CONTROL_DB, context.account.id, "user", context.identity.subject, "desktop.revoke", "desktop", desktopId, now),
  ]);
  if (changes(results[0]) === 0) return apiError(404, "not_found", "Desktop not found.");
  await disconnectRoom(env, desktopId);
  return apiResponse({ revoked: true, desktopId });
}

async function handleCreatePairing(request: Request, env: ControlEnv): Promise<Response> {
  const authenticated = await authenticateDeviceCredential(request, env, "access");
  if (!authenticated.ok) return authenticationError(authenticated);
  if (authenticated.value.role !== "desktop") {
    return apiError(403, "forbidden", "Only a desktop can create a pairing code.");
  }
  const pepper = requiredPepper(env);
  if (pepper instanceof Response) return pepper;

  const now = Date.now();
  const pairingId = `pair_${compactUUID()}`;
  const pairingSecret = randomBase64URL(32);
  const secretHash = await hashSecret(pairingSecret, pepper);
  const expiresAt = now + PAIRING_LIFETIME_MS;
  await env.CONTROL_DB.batch([
    env.CONTROL_DB.prepare(
      `INSERT INTO pairing_challenges
        (id, account_id, desktop_id, secret_hash, created_at, expires_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    ).bind(
      pairingId,
      authenticated.value.accountId,
      authenticated.value.desktopId,
      secretHash,
      now,
      expiresAt,
    ),
    auditInsert(
      env.CONTROL_DB,
      authenticated.value.accountId,
      "desktop",
      authenticated.value.subjectId,
      "pairing.create",
      "pairing",
      pairingId,
      now,
    ),
  ]);
  return apiResponse({
    pairing: {
      v: 2,
      relayUrl: publicRelayURL(request),
      pairingId,
      pairingSecret,
      desktopId: authenticated.value.desktopId,
      expiresAt: isoDate(expiresAt),
    },
  }, 201);
}

async function handleClaimPairing(
  request: Request,
  env: ControlEnv,
  pairingId: string,
): Promise<Response> {
  const context = await accountContext(request, env);
  if (context instanceof Response) return context;
  const body = await parseJSONBody(request);
  if (body instanceof Response) return body;
  const pairingSecret = boundedString(body.pairingSecret, 256);
  const deviceName = boundedString(body.deviceName, 100);
  const platform = parsePlatform(body.platform);
  if (!pairingSecret || !deviceName || platform === null) {
    return apiError(400, "invalid_request", "Pairing secret, device name, and platform are required.");
  }
  const pepper = requiredPepper(env);
  if (pepper instanceof Response) return pepper;

  const now = Date.now();
  const deviceId = `device_${compactUUID()}`;
  const secretHash = await hashSecret(pairingSecret, pepper);
  const credentials = await createCredentialPair(pepper, now);
  const scopesJSON = JSON.stringify(MOBILE_SCOPES);
  const results = await env.CONTROL_DB.batch([
    env.CONTROL_DB.prepare(
      `INSERT INTO devices (id, account_id, name, platform, created_at)
       SELECT ?, account_id, ?, ?, ? FROM pairing_challenges
        WHERE id = ? AND account_id = ? AND secret_hash = ?
          AND claimed_at IS NULL AND expires_at > ?`,
    ).bind(
      deviceId,
      deviceName,
      platform,
      now,
      pairingId,
      context.account.id,
      secretHash,
      now,
    ),
    env.CONTROL_DB.prepare(
      `UPDATE pairing_challenges
          SET claimed_at = ?, claimed_device_id = ?
        WHERE id = ? AND account_id = ? AND secret_hash = ?
          AND claimed_at IS NULL AND expires_at > ?
          AND EXISTS (SELECT 1 FROM devices WHERE id = ?)`,
    ).bind(now, deviceId, pairingId, context.account.id, secretHash, now, deviceId),
    env.CONTROL_DB.prepare(
      `INSERT INTO desktop_devices (desktop_id, device_id, scopes_json, paired_at)
       SELECT desktop_id, ?, ?, ? FROM pairing_challenges
        WHERE id = ? AND claimed_device_id = ? AND claimed_at = ?`,
    ).bind(deviceId, scopesJSON, now, pairingId, deviceId, now),
    credentialInsertFromPairing(env.CONTROL_DB, credentials.access, pairingId, deviceId, now, scopesJSON),
    credentialInsertFromPairing(env.CONTROL_DB, credentials.refresh, pairingId, deviceId, now, scopesJSON),
  ]);
  if (changes(results[0]) === 0) {
    return apiError(409, "pairing_unavailable", "Pairing code is invalid, expired, used, or belongs to another account.");
  }
  await auditInsert(
    env.CONTROL_DB,
    context.account.id,
    "user",
    context.identity.subject,
    "pairing.claim",
    "device",
    deviceId,
    now,
  ).run();
  const pairing = await env.CONTROL_DB.prepare(
    `SELECT p.desktop_id, d.name AS desktop_name
       FROM pairing_challenges p JOIN desktops d ON d.id = p.desktop_id
      WHERE p.id = ? AND p.claimed_device_id = ?`,
  ).bind(pairingId, deviceId).first<{ desktop_id: string; desktop_name: string }>();
  if (pairing === null) return apiError(500, "internal_error", "Pairing could not be loaded.");

  return apiResponse({
    device: { id: deviceId, name: deviceName, platform },
    desktop: { id: pairing.desktop_id, name: pairing.desktop_name },
    scopes: MOBILE_SCOPES,
    credentials: credentialResponse(credentials),
    relayUrl: publicRelayURL(request),
  }, 201);
}

async function handleRefreshToken(request: Request, env: ControlEnv): Promise<Response> {
  const authenticated = await authenticateDeviceCredential(request, env, "refresh");
  if (!authenticated.ok) return authenticationError(authenticated);
  const pepper = requiredPepper(env);
  if (pepper instanceof Response) return pepper;
  const now = Date.now();
  const credentials = await createCredentialPair(pepper, now);
  const results = await env.CONTROL_DB.batch([
    replacementRefreshInsert(
      env.CONTROL_DB,
      credentials.refresh,
      authenticated.value.credentialId,
      now,
    ),
    env.CONTROL_DB.prepare(
      `UPDATE credentials SET revoked_at = ?, replaced_by = ?
        WHERE id = ? AND kind = 'refresh' AND revoked_at IS NULL AND expires_at > ?`,
    ).bind(now, credentials.refresh.id, authenticated.value.credentialId, now),
    rotatedCredentialInsert(env.CONTROL_DB, credentials.access, authenticated.value.credentialId, credentials.refresh.id, now),
    env.CONTROL_DB.prepare(
      `UPDATE credentials SET revoked_at = ?
        WHERE subject_type = ? AND subject_id = ? AND kind = 'access'
          AND revoked_at IS NULL AND id <> ?`,
    ).bind(now, authenticated.value.subjectType, authenticated.value.subjectId, credentials.access.id),
  ]);
  if (changes(results[1]) === 0) return apiError(401, "unauthorized", "Refresh credential was already used.");
  return apiResponse({ credentials: credentialResponse(credentials) });
}

async function handleListDevices(request: Request, env: ControlEnv): Promise<Response> {
  const context = await accountContext(request, env);
  if (context instanceof Response) return context;
  const rows = await env.CONTROL_DB.prepare(
    `SELECT d.id, d.name, d.platform, d.created_at, d.last_seen_at,
            dd.desktop_id, desktops.name AS desktop_name, dd.scopes_json
       FROM devices d
       JOIN desktop_devices dd ON dd.device_id = d.id AND dd.revoked_at IS NULL
       JOIN desktops ON desktops.id = dd.desktop_id AND desktops.revoked_at IS NULL
      WHERE d.account_id = ? AND d.revoked_at IS NULL
      ORDER BY d.created_at DESC`,
  ).bind(context.account.id).all<{
    id: string;
    name: string;
    platform: string;
    created_at: number;
    last_seen_at: number | null;
    desktop_id: string;
    desktop_name: string;
    scopes_json: string;
  }>();
  return apiResponse({
    devices: rows.results.map((row) => ({
      id: row.id,
      name: row.name,
      platform: row.platform,
      createdAt: isoDate(row.created_at),
      ...(row.last_seen_at === null ? {} : { lastSeenAt: isoDate(row.last_seen_at) }),
      desktop: { id: row.desktop_id, name: row.desktop_name },
      scopes: JSON.parse(row.scopes_json) as unknown,
    })),
  });
}

async function handleRevokeDevice(
  request: Request,
  env: ControlEnv,
  deviceId: string,
): Promise<Response> {
  const context = await accountContext(request, env);
  if (context instanceof Response) return context;
  const now = Date.now();
  const pairings = await env.CONTROL_DB.prepare(
    `SELECT desktop_id FROM desktop_devices
      WHERE device_id = ? AND revoked_at IS NULL`,
  ).bind(deviceId).all<{ desktop_id: string }>();
  const results = await env.CONTROL_DB.batch([
    env.CONTROL_DB.prepare(
      "UPDATE devices SET revoked_at = ? WHERE id = ? AND account_id = ? AND revoked_at IS NULL",
    ).bind(now, deviceId, context.account.id),
    env.CONTROL_DB.prepare(
      "UPDATE desktop_devices SET revoked_at = ? WHERE device_id = ? AND revoked_at IS NULL",
    ).bind(now, deviceId),
    env.CONTROL_DB.prepare(
      `UPDATE credentials SET revoked_at = ?
        WHERE subject_type = 'device' AND subject_id = ? AND account_id = ? AND revoked_at IS NULL`,
    ).bind(now, deviceId, context.account.id),
    auditInsert(env.CONTROL_DB, context.account.id, "user", context.identity.subject, "device.revoke", "device", deviceId, now),
  ]);
  if (changes(results[0]) === 0) return apiError(404, "not_found", "Device not found.");
  await Promise.all(
    pairings.results.map((pairing) => disconnectRoom(env, pairing.desktop_id, deviceId)),
  );
  return apiResponse({ revoked: true, deviceId });
}

async function accountContext(
  request: Request,
  env: ControlEnv,
): Promise<{ identity: UserIdentity; account: Account } | Response> {
  const authenticated = await authenticateOIDCUser(request, env);
  if (!authenticated.ok) return authenticationError(authenticated);
  return {
    identity: authenticated.value,
    account: await ensureAccount(env.CONTROL_DB, authenticated.value),
  };
}

async function ensureAccount(db: D1Database, identity: UserIdentity): Promise<Account> {
  const accountId = await accountID(identity.issuer, identity.subject);
  const now = Date.now();
  await db.prepare(
    `INSERT INTO accounts
      (id, oidc_issuer, oidc_subject, email, display_name, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       email = excluded.email,
       display_name = excluded.display_name,
       updated_at = excluded.updated_at`,
  ).bind(
    accountId,
    identity.issuer,
    identity.subject,
    identity.email ?? null,
    identity.displayName ?? null,
    now,
    now,
  ).run();
  return {
    id: accountId,
    ...(identity.email ? { email: identity.email } : {}),
    ...(identity.displayName ? { displayName: identity.displayName } : {}),
  };
}

async function accountID(issuer: string, subject: string): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${issuer}\u0000${subject}`)),
  );
  return `acct_${Array.from(digest.slice(0, 20), (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

async function createCredentialPair(pepper: string, now: number): Promise<CredentialPair> {
  const [access, refresh] = await Promise.all([
    createCredentialMaterial("access", pepper, now),
    createCredentialMaterial("refresh", pepper, now),
  ]);
  return { access, refresh };
}

function credentialInsert(
  db: D1Database,
  material: CredentialMaterial,
  identity: {
    accountId: string;
    subjectType: "desktop" | "device";
    subjectId: string;
    desktopId: string;
    role: "desktop" | "mobile";
    scopesJSON: string;
  },
): D1PreparedStatement {
  return db.prepare(
    `INSERT INTO credentials
      (id, account_id, subject_type, subject_id, desktop_id, role, kind,
       secret_hash, scopes_json, issued_at, expires_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(
    material.id,
    identity.accountId,
    identity.subjectType,
    identity.subjectId,
    identity.desktopId,
    identity.role,
    material.kind,
    material.secretHash,
    identity.scopesJSON,
    material.issuedAt,
    material.expiresAt,
  );
}

function credentialInsertFromPairing(
  db: D1Database,
  material: CredentialMaterial,
  pairingId: string,
  deviceId: string,
  claimedAt: number,
  scopesJSON: string,
): D1PreparedStatement {
  return db.prepare(
    `INSERT INTO credentials
      (id, account_id, subject_type, subject_id, desktop_id, role, kind,
       secret_hash, scopes_json, issued_at, expires_at)
     SELECT ?, account_id, 'device', ?, desktop_id, 'mobile', ?, ?, ?, ?, ?
       FROM pairing_challenges
      WHERE id = ? AND claimed_device_id = ? AND claimed_at = ?`,
  ).bind(
    material.id,
    deviceId,
    material.kind,
    material.secretHash,
    scopesJSON,
    material.issuedAt,
    material.expiresAt,
    pairingId,
    deviceId,
    claimedAt,
  );
}

function rotatedCredentialInsert(
  db: D1Database,
  material: CredentialMaterial,
  previousId: string,
  replacementId: string,
  replacedAt: number,
): D1PreparedStatement {
  return db.prepare(
    `INSERT INTO credentials
      (id, account_id, subject_type, subject_id, desktop_id, role, kind,
       secret_hash, scopes_json, issued_at, expires_at)
     SELECT ?, account_id, subject_type, subject_id, desktop_id, role, ?, ?, scopes_json, ?, ?
       FROM credentials
      WHERE id = ? AND replaced_by = ? AND revoked_at = ?`,
  ).bind(
    material.id,
    material.kind,
    material.secretHash,
    material.issuedAt,
    material.expiresAt,
    previousId,
    replacementId,
    replacedAt,
  );
}

function replacementRefreshInsert(
  db: D1Database,
  material: CredentialMaterial,
  previousId: string,
  now: number,
): D1PreparedStatement {
  return db.prepare(
    `INSERT INTO credentials
      (id, account_id, subject_type, subject_id, desktop_id, role, kind,
       secret_hash, scopes_json, issued_at, expires_at)
     SELECT ?, account_id, subject_type, subject_id, desktop_id, role, 'refresh', ?, scopes_json, ?, ?
       FROM credentials
      WHERE id = ? AND kind = 'refresh' AND revoked_at IS NULL AND expires_at > ?`,
  ).bind(
    material.id,
    material.secretHash,
    material.issuedAt,
    material.expiresAt,
    previousId,
    now,
  );
}

function auditInsert(
  db: D1Database,
  accountId: string,
  actorType: string,
  actorId: string,
  action: string,
  targetType: string,
  targetId: string,
  occurredAt: number,
): D1PreparedStatement {
  return db.prepare(
    `INSERT INTO audit_events
      (account_id, actor_type, actor_id, action, target_type, target_id, occurred_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
  ).bind(accountId, actorType, actorId, action, targetType, targetId, occurredAt);
}

function credentialResponse(credentials: CredentialPair): Record<string, unknown> {
  return {
    accessToken: credentials.access.token,
    accessExpiresAt: isoDate(credentials.access.expiresAt),
    refreshToken: credentials.refresh.token,
    refreshExpiresAt: isoDate(credentials.refresh.expiresAt),
  };
}

async function parseJSONBody(request: Request): Promise<JSONBody | Response> {
  const length = Number(request.headers.get("Content-Length") ?? "0");
  if (Number.isFinite(length) && length > MAX_JSON_BODY_BYTES) {
    return apiError(413, "request_too_large", "Request body is too large.");
  }
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > MAX_JSON_BODY_BYTES) {
    return apiError(413, "request_too_large", "Request body is too large.");
  }
  try {
    const value: unknown = JSON.parse(text);
    if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error();
    return value as JSONBody;
  } catch {
    return apiError(400, "invalid_json", "Request body must be a JSON object.");
  }
}

function requiredPepper(env: ControlEnv): string | Response {
  return env.DEVICE_CREDENTIAL_PEPPER?.length
    ? env.DEVICE_CREDENTIAL_PEPPER
    : apiError(503, "auth_unavailable", "Device authentication is not configured.");
}

function authenticationError<T>(failure: Exclude<AuthenticationResult<T>, { ok: true }>): Response {
  return apiError(failure.status, failure.code, failure.message);
}

function apiResponse(body: Record<string, unknown>, status = 200): Response {
  return Response.json(body, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

function apiError(status: number, code: string, message: string): Response {
  return apiResponse({ error: { code, message } }, status);
}

function publicRelayURL(request: Request): string {
  const url = new URL(request.url);
  return url.origin;
}

function boundedString(value: unknown, maximumLength: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 && trimmed.length <= maximumLength ? trimmed : null;
}

function parsePlatform(value: unknown): "ios" | "android" | "macos" | "unknown" | null {
  return value === "ios" || value === "android" || value === "macos" || value === "unknown"
    ? value
    : null;
}

function parseDeckPublicKey(value: unknown): JsonWebKey | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const key = value as Record<string, unknown>;
  if (
    key.kty !== "RSA" ||
    typeof key.n !== "string" || key.n.length < 128 || key.n.length > 2_048 ||
    typeof key.e !== "string" || key.e.length > 16
  ) return null;
  return { kty: "RSA", n: key.n, e: key.e, alg: "RSA-OAEP-256", ext: true, key_ops: ["encrypt"] };
}

async function encryptDeckCredentials(
  publicKeyJSON: string,
  payload: Record<string, unknown>,
): Promise<{ wrappedKey: string; iv: string; ciphertext: string } | Response> {
  try {
    const publicKey = await crypto.subtle.importKey(
      "jwk",
      JSON.parse(publicKeyJSON) as JsonWebKey,
      { name: "RSA-OAEP", hash: "SHA-256" },
      false,
      ["encrypt"],
    );
    const aesKey = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, true, ["encrypt"]);
    const rawKey = await crypto.subtle.exportKey("raw", aesKey);
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const [wrappedKey, ciphertext] = await Promise.all([
      crypto.subtle.encrypt({ name: "RSA-OAEP" }, publicKey, rawKey),
      crypto.subtle.encrypt({ name: "AES-GCM", iv }, aesKey, new TextEncoder().encode(JSON.stringify(payload))),
    ]);
    return {
      wrappedKey: base64URL(new Uint8Array(wrappedKey)),
      iv: base64URL(iv),
      ciphertext: base64URL(new Uint8Array(ciphertext)),
    };
  } catch {
    return apiError(400, "invalid_public_key", "Deck public key could not encrypt the credential handoff.");
  }
}

function base64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function isoDate(milliseconds: number): string {
  return new Date(milliseconds).toISOString();
}

function changes(result: D1Result<unknown> | undefined): number {
  return result?.meta.changes ?? 0;
}

async function disconnectRoom(
  env: ControlEnv,
  desktopId: string,
  deviceId?: string,
): Promise<void> {
  const headers = new Headers({ [INTERNAL_DESKTOP_ID_HEADER]: desktopId });
  if (deviceId) headers.set(INTERNAL_DEVICE_ID_HEADER, deviceId);
  const room = env.DESKTOP_ROOMS.getByName(desktopId);
  await room.fetch(new Request("https://relay.internal/disconnect", {
    method: "POST",
    headers,
  }));
}
