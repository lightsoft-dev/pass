import { createRemoteJWKSet, jwtVerify } from "jose";

import { isValidIdentifier, type Role } from "./protocol";

export const ACCESS_TOKEN_LIFETIME_MS = 15 * 60 * 1_000;
export const REFRESH_TOKEN_LIFETIME_MS = 30 * 24 * 60 * 60 * 1_000;

export type CredentialKind = "access" | "refresh";

export type UserIdentity = {
  issuer: string;
  subject: string;
  email?: string;
  displayName?: string;
};

export type CredentialIdentity = {
  credentialId: string;
  accountId: string;
  subjectType: "desktop" | "device";
  subjectId: string;
  desktopId: string;
  role: Role;
  scopes: string[];
  expiresAt: number;
};

export type CredentialMaterial = {
  id: string;
  kind: CredentialKind;
  token: string;
  secretHash: string;
  issuedAt: number;
  expiresAt: number;
};

export type AuthenticationResult<T> =
  | { ok: true; value: T }
  | {
      ok: false;
      status: 401 | 503;
      code: "unauthorized" | "auth_unavailable";
      message: string;
    };

type PublicAuthEnv = {
  CONTROL_DB: D1Database;
  DEVICE_CREDENTIAL_PEPPER?: string;
  OIDC_ISSUER?: string;
  OIDC_AUDIENCE?: string;
  OIDC_JWKS_URL?: string;
};

type CredentialRow = {
  id: string;
  account_id: string;
  subject_type: string;
  subject_id: string;
  desktop_id: string;
  role: string;
  kind: string;
  secret_hash: string;
  scopes_json: string;
  expires_at: number;
};

const remoteJWKSets = new Map<string, ReturnType<typeof createRemoteJWKSet>>();

export function extractBearerToken(request: Request): string | null {
  const authorization = request.headers.get("Authorization");
  if (authorization === null || authorization.length > 4_096) return null;
  const match = /^Bearer ([^\s]+)$/.exec(authorization);
  return match?.[1] ?? null;
}

export async function tokensMatch(
  provided: string,
  expected: string,
): Promise<boolean> {
  const encoder = new TextEncoder();
  const [providedHash, expectedHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(provided)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  return fixedLengthBytesMatch(
    new Uint8Array(providedHash),
    new Uint8Array(expectedHash),
  );
}

export async function authenticateOIDCUser(
  request: Request,
  env: PublicAuthEnv,
): Promise<AuthenticationResult<UserIdentity>> {
  const issuer = env.OIDC_ISSUER?.trim();
  const audience = env.OIDC_AUDIENCE?.trim();
  const issuerBase = issuer?.replace(/\/+$/, "");
  const jwksURL = env.OIDC_JWKS_URL?.trim()
    || (issuerBase ? `${issuerBase}/.well-known/jwks.json` : "");
  if (!issuer || !audience || !jwksURL) {
    return {
      ok: false,
      status: 503,
      code: "auth_unavailable",
      message: "Public account authentication is not configured.",
    };
  }

  const token = extractBearerToken(request);
  if (token === null) return unauthorized();

  try {
    let jwks = remoteJWKSets.get(jwksURL);
    if (jwks === undefined) {
      jwks = createRemoteJWKSet(new URL(jwksURL));
      remoteJWKSets.set(jwksURL, jwks);
    }
    const { payload } = await jwtVerify(token, jwks, {
      issuer,
      audience,
      algorithms: ["RS256", "ES256", "EdDSA"],
    });
    if (typeof payload.sub !== "string" || payload.sub.length === 0 || payload.sub.length > 512) {
      return unauthorized();
    }
    const email = boundedClaim(payload.email, 320);
    const displayName = boundedClaim(payload.name, 200);
    return {
      ok: true,
      value: {
        issuer,
        subject: payload.sub,
        ...(email ? { email } : {}),
        ...(displayName ? { displayName } : {}),
      },
    };
  } catch {
    return unauthorized();
  }
}

export async function authenticateDeviceCredential(
  request: Request,
  env: PublicAuthEnv,
  expectedKind: CredentialKind,
  now = Date.now(),
): Promise<AuthenticationResult<CredentialIdentity>> {
  const pepper = env.DEVICE_CREDENTIAL_PEPPER;
  if (!pepper) {
    return {
      ok: false,
      status: 503,
      code: "auth_unavailable",
      message: "Device authentication is not configured.",
    };
  }
  const parsed = parseCredentialToken(extractBearerToken(request));
  if (parsed === null || parsed.kind !== expectedKind) return unauthorized();

  const row = await env.CONTROL_DB.prepare(
    `SELECT id, account_id, subject_type, subject_id, desktop_id, role, kind,
            secret_hash, scopes_json, expires_at
       FROM credentials
      WHERE id = ? AND kind = ? AND revoked_at IS NULL AND expires_at > ?`,
  ).bind(parsed.id, expectedKind, now).first<CredentialRow>();
  if (row === null || row.kind !== expectedKind) return unauthorized();

  const actualHash = await hashSecret(parsed.secret, pepper);
  if (!(await tokensMatch(actualHash, row.secret_hash))) return unauthorized();
  if (
    (row.subject_type !== "desktop" && row.subject_type !== "device") ||
    (row.role !== "desktop" && row.role !== "mobile") ||
    !isValidIdentifier(row.subject_id) ||
    !isValidIdentifier(row.desktop_id)
  ) {
    return unauthorized();
  }

  const active = row.role === "desktop"
    ? await env.CONTROL_DB.prepare(
        "SELECT id FROM desktops WHERE id = ? AND account_id = ? AND revoked_at IS NULL",
      ).bind(row.desktop_id, row.account_id).first()
    : await env.CONTROL_DB.prepare(
        `SELECT dd.device_id
           FROM desktop_devices dd
           JOIN devices d ON d.id = dd.device_id
          WHERE dd.desktop_id = ? AND dd.device_id = ? AND d.account_id = ?
            AND dd.revoked_at IS NULL AND d.revoked_at IS NULL`,
      ).bind(row.desktop_id, row.subject_id, row.account_id).first();
  if (active === null) return unauthorized();

  const scopes = parseScopes(row.scopes_json);
  if (scopes === null) return unauthorized();
  return {
    ok: true,
    value: {
      credentialId: row.id,
      accountId: row.account_id,
      subjectType: row.subject_type,
      subjectId: row.subject_id,
      desktopId: row.desktop_id,
      role: row.role,
      scopes,
      expiresAt: row.expires_at,
    },
  };
}

export async function createCredentialMaterial(
  kind: CredentialKind,
  pepper: string,
  now = Date.now(),
): Promise<CredentialMaterial> {
  const id = `cred_${compactUUID()}`;
  const secret = randomBase64URL(32);
  const tokenPrefix = kind === "access" ? "pass_at" : "pass_rt";
  return {
    id,
    kind,
    token: `${tokenPrefix}_${id}.${secret}`,
    secretHash: await hashSecret(secret, pepper),
    issuedAt: now,
    expiresAt: now + (kind === "access" ? ACCESS_TOKEN_LIFETIME_MS : REFRESH_TOKEN_LIFETIME_MS),
  };
}

export function compactUUID(): string {
  return crypto.randomUUID().replaceAll("-", "").toLowerCase();
}

export function randomBase64URL(byteCount: number): string {
  const bytes = crypto.getRandomValues(new Uint8Array(byteCount));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export async function hashSecret(secret: string, pepper: string): Promise<string> {
  const bytes = new TextEncoder().encode(`${secret}\u0000${pepper}`);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function parseCredentialToken(
  token: string | null,
): { kind: CredentialKind; id: string; secret: string } | null {
  if (token === null || token.length > 512) return null;
  const match = /^pass_(at|rt)_(cred_[a-f0-9]{32})\.([A-Za-z0-9_-]{43})$/.exec(token);
  if (match === null) return null;
  const kind = match[1] === "at" ? "access" : "refresh";
  const id = match[2];
  const secret = match[3];
  return id && secret ? { kind, id, secret } : null;
}

function parseScopes(raw: string): string[] | null {
  try {
    const value: unknown = JSON.parse(raw);
    if (
      !Array.isArray(value) ||
      value.length > 32 ||
      value.some((scope) => typeof scope !== "string" || scope.length === 0 || scope.length > 128)
    ) {
      return null;
    }
    return [...new Set(value)];
  } catch {
    return null;
  }
}

function boundedClaim(value: unknown, maximumLength: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 && trimmed.length <= maximumLength ? trimmed : undefined;
}

function unauthorized<T>(): AuthenticationResult<T> {
  return {
    ok: false,
    status: 401,
    code: "unauthorized",
    message: "Authentication failed.",
  };
}

function fixedLengthBytesMatch(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= (left.at(index) ?? 0) ^ (right.at(index) ?? 0);
  }
  return difference === 0;
}
