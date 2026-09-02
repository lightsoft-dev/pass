import { SignJWT, importPKCS8 } from "jose";

import { APPLE_OIDC_ISSUER } from "./auth";

export const APPLE_TEAM_ID = "H66C2M66DC";
export const APPLE_CLIENT_ID = "dev.lightsoft.passmobile";

const APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token";
const APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke";
const CLIENT_SECRET_LIFETIME_SECONDS = 5 * 60;
const APPLE_REQUEST_TIMEOUT_MS = 10 * 1_000;
const REFRESH_TOKEN_ENCRYPTION_VERSION = 1;
const MAX_APPLE_RESPONSE_BYTES = 32 * 1_024;

export type AppleServiceEnv = {
  APPLE_TEAM_ID?: string;
  APPLE_CLIENT_ID?: string;
  APPLE_KEY_ID?: string;
  APPLE_PRIVATE_KEY?: string;
  APPLE_TOKEN_ENCRYPTION_KEY?: string;
};

export type EncryptedAppleRefreshToken = {
  ciphertext: string;
  iv: string;
  version: typeof REFRESH_TOKEN_ENCRYPTION_VERSION;
};

export class AppleServiceError extends Error {
  constructor(
    readonly status: 409 | 503,
    readonly code: string,
    message: string,
    readonly action: "retry" | "reauthorize_with_apple",
  ) {
    super(message);
    this.name = "AppleServiceError";
  }
}

export async function exchangeAppleAuthorizationCode(
  env: AppleServiceEnv,
  authorizationCode: string,
  now = Date.now(),
): Promise<{ refreshToken: string; identityToken: string }> {
  const signing = await appleSigningConfiguration(env);
  const clientSecret = await createClientSecret(signing, now);
  const body = new URLSearchParams({
    client_id: APPLE_CLIENT_ID,
    client_secret: clientSecret,
    code: authorizationCode,
    grant_type: "authorization_code",
  });

  let response: Response;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), APPLE_REQUEST_TIMEOUT_MS);
  try {
    response = await fetch(APPLE_TOKEN_URL, {
      method: "POST",
      redirect: "error",
      signal: controller.signal,
      headers: {
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body,
    });
  } catch {
    throw authorizationUncertain();
  } finally {
    clearTimeout(timeout);
  }

  const payload = await readAppleJSON(response);
  if (!response.ok) throw appleEndpointFailure("authorization", response.status, payload);
  const refreshToken = boundedProperty(payload, "refresh_token", 16_384);
  const identityToken = boundedProperty(payload, "id_token", 32_768);
  if (refreshToken === null || identityToken === null) {
    // A successful token response may already have consumed the single-use code. Treat malformed
    // or truncated success payloads as ambiguous and require a fresh native authorization.
    throw authorizationUncertain();
  }
  return { refreshToken, identityToken };
}

export async function encryptAppleRefreshToken(
  env: AppleServiceEnv,
  issuer: string,
  subject: string,
  refreshToken: string,
): Promise<EncryptedAppleRefreshToken> {
  const key = await appleEncryptionKey(env);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  try {
    const ciphertext = await crypto.subtle.encrypt(
      {
        name: "AES-GCM",
        iv,
        additionalData: refreshTokenAAD(issuer, subject),
        tagLength: 128,
      },
      key,
      new TextEncoder().encode(refreshToken),
    );
    return {
      ciphertext: base64URL(new Uint8Array(ciphertext)),
      iv: base64URL(iv),
      version: REFRESH_TOKEN_ENCRYPTION_VERSION,
    };
  } catch {
    throw unavailable("Apple token encryption is unavailable.");
  }
}

export async function revokeEncryptedAppleRefreshToken(
  env: AppleServiceEnv,
  issuer: string,
  subject: string,
  encrypted: EncryptedAppleRefreshToken,
  now = Date.now(),
): Promise<void> {
  if (encrypted.version !== REFRESH_TOKEN_ENCRYPTION_VERSION) {
    throw reauthorizationRequired("The stored Apple authorization must be renewed before deletion.");
  }
  const [signing, encryptionKey] = await Promise.all([
    appleSigningConfiguration(env),
    appleEncryptionKey(env),
  ]);
  const refreshToken = await decryptAppleRefreshToken(
    encryptionKey,
    issuer,
    subject,
    encrypted,
  );
  await revokeWithConfiguration(signing, refreshToken, now);
}

export async function revokeAppleRefreshToken(
  env: AppleServiceEnv,
  refreshToken: string,
  now = Date.now(),
): Promise<void> {
  const signing = await appleSigningConfiguration(env);
  await revokeWithConfiguration(signing, refreshToken, now);
}

async function revokeWithConfiguration(
  signing: AppleSigningConfiguration,
  refreshToken: string,
  now: number,
): Promise<void> {
  const clientSecret = await createClientSecret(signing, now);
  const body = new URLSearchParams({
    client_id: APPLE_CLIENT_ID,
    client_secret: clientSecret,
    token: refreshToken,
    token_type_hint: "refresh_token",
  });

  let response: Response;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), APPLE_REQUEST_TIMEOUT_MS);
  try {
    response = await fetch(APPLE_REVOKE_URL, {
      method: "POST",
      redirect: "error",
      signal: controller.signal,
      headers: {
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body,
    });
  } catch {
    throw unavailable("Apple token revocation is temporarily unavailable.");
  } finally {
    clearTimeout(timeout);
  }
  if (response.ok) return;
  const payload = await readAppleJSON(response);
  throw appleEndpointFailure("revocation", response.status, payload);
}

type AppleSigningConfiguration = {
  keyId: string;
  privateKey: CryptoKey;
};

async function appleSigningConfiguration(
  env: AppleServiceEnv,
): Promise<AppleSigningConfiguration> {
  if (
    env.APPLE_TEAM_ID?.trim() !== APPLE_TEAM_ID
    || env.APPLE_CLIENT_ID?.trim() !== APPLE_CLIENT_ID
  ) {
    throw unavailable("Apple server authorization is not configured.");
  }
  const keyId = env.APPLE_KEY_ID?.trim();
  const privateKeyPEM = normalizePrivateKey(env.APPLE_PRIVATE_KEY);
  if (!keyId || !/^[A-Z0-9]{10}$/.test(keyId) || privateKeyPEM === null) {
    throw unavailable("Apple server authorization is not configured.");
  }
  try {
    return {
      keyId,
      privateKey: await importPKCS8(privateKeyPEM, "ES256"),
    };
  } catch {
    throw unavailable("Apple server authorization is not configured.");
  }
}

async function appleEncryptionKey(env: AppleServiceEnv): Promise<CryptoKey> {
  const encoded = env.APPLE_TOKEN_ENCRYPTION_KEY?.trim();
  if (!encoded || encoded.length > 128) {
    throw unavailable("Apple token encryption is not configured.");
  }
  try {
    const raw = decodeBase64URL(encoded);
    if (raw.byteLength !== 32) throw new Error();
    return await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
  } catch {
    throw unavailable("Apple token encryption is not configured.");
  }
}

async function createClientSecret(
  configuration: AppleSigningConfiguration,
  now: number,
): Promise<string> {
  const issuedAt = Math.floor(now / 1_000);
  try {
    return await new SignJWT({})
      .setProtectedHeader({ alg: "ES256", kid: configuration.keyId })
      .setIssuer(APPLE_TEAM_ID)
      .setSubject(APPLE_CLIENT_ID)
      .setAudience(APPLE_OIDC_ISSUER)
      .setIssuedAt(issuedAt)
      .setExpirationTime(issuedAt + CLIENT_SECRET_LIFETIME_SECONDS)
      .sign(configuration.privateKey);
  } catch {
    throw unavailable("Apple client authorization could not be generated.");
  }
}

async function decryptAppleRefreshToken(
  key: CryptoKey,
  issuer: string,
  subject: string,
  encrypted: EncryptedAppleRefreshToken,
): Promise<string> {
  try {
    const iv = decodeBase64URL(encrypted.iv);
    const ciphertext = decodeBase64URL(encrypted.ciphertext);
    if (iv.byteLength !== 12 || ciphertext.byteLength < 17 || ciphertext.byteLength > 32_768) {
      throw new Error();
    }
    const plaintext = await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv,
        additionalData: refreshTokenAAD(issuer, subject),
        tagLength: 128,
      },
      key,
      ciphertext,
    );
    const refreshToken = new TextDecoder("utf-8", { fatal: true }).decode(plaintext);
    if (!refreshToken || refreshToken.length > 16_384) throw new Error();
    return refreshToken;
  } catch {
    throw reauthorizationRequired("The stored Apple authorization must be renewed before deletion.");
  }
}

function refreshTokenAAD(issuer: string, subject: string): Uint8Array<ArrayBuffer> {
  return new TextEncoder().encode(
    `pass.apple.refresh-token.v${REFRESH_TOKEN_ENCRYPTION_VERSION}\u0000${issuer}\u0000${subject}`,
  );
}

async function readAppleJSON(response: Response): Promise<Record<string, unknown>> {
  try {
    const text = await readBoundedResponseText(response, MAX_APPLE_RESPONSE_BYTES);
    if (text === null) return {};
    const value: unknown = text ? JSON.parse(text) : {};
    return typeof value === "object" && value !== null && !Array.isArray(value)
      ? value as Record<string, unknown>
      : {};
  } catch {
    return {};
  }
}

async function readBoundedResponseText(
  response: Response,
  maximumBytes: number,
): Promise<string | null> {
  const declaredLength = Number(response.headers.get("Content-Length") ?? "0");
  if (Number.isFinite(declaredLength) && declaredLength > maximumBytes) return null;
  if (response.body === null) return "";
  const reader = response.body.getReader();
  const chunks: Uint8Array<ArrayBuffer>[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maximumBytes) {
      await reader.cancel();
      return null;
    }
    chunks.push(new Uint8Array(value));
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

function appleEndpointFailure(
  operation: "authorization" | "revocation",
  status: number,
  payload: Record<string, unknown>,
): AppleServiceError {
  const appleCode = typeof payload.error === "string" ? payload.error : "";
  if (status >= 500 || status === 429) {
    return operation === "authorization"
      ? authorizationUncertain()
      : unavailable("Apple revocation is temporarily unavailable.");
  }
  if (appleCode === "invalid_client" || appleCode === "unauthorized_client") {
    return unavailable("Apple server authorization was rejected.");
  }
  return reauthorizationRequired(
    operation === "authorization"
      ? "Apple authorization expired or was already used. Sign in with Apple again."
      : "Apple authorization must be renewed before account deletion can be retried.",
  );
}

function boundedProperty(
  object: Record<string, unknown>,
  key: string,
  maximumLength: number,
): string | null {
  const value = object[key];
  return typeof value === "string" && value.length > 0 && value.length <= maximumLength
    ? value
    : null;
}

function normalizePrivateKey(value: string | undefined): string | null {
  if (!value || value.length > 16_384) return null;
  const normalized = value.includes("\\n") ? value.replaceAll("\\n", "\n") : value;
  return normalized.includes("-----BEGIN PRIVATE KEY-----")
    && normalized.includes("-----END PRIVATE KEY-----")
    ? normalized
    : null;
}

function unavailable(message: string): AppleServiceError {
  return new AppleServiceError(503, "apple_service_unavailable", message, "retry");
}

function authorizationUncertain(): AppleServiceError {
  return new AppleServiceError(
    503,
    "apple_authorization_uncertain",
    "Apple authorization could not be confirmed. Sign in with Apple again before retrying.",
    "reauthorize_with_apple",
  );
}

function reauthorizationRequired(message: string): AppleServiceError {
  return new AppleServiceError(
    409,
    "apple_reauthorization_required",
    message,
    "reauthorize_with_apple",
  );
}

function base64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function decodeBase64URL(value: string): Uint8Array<ArrayBuffer> {
  if (!/^[A-Za-z0-9_-]+={0,2}$/.test(value)) throw new Error();
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  const binary = atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "="));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}
