import {
  SELF,
  applyD1Migrations,
  env,
  type D1Migration,
} from "cloudflare:test";
import {
  SignJWT,
  decodeJwt,
  decodeProtectedHeader,
  exportJWK,
  generateKeyPair,
  type CryptoKey,
  type JWK,
} from "jose";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { authenticateOIDCUser } from "../src/auth";
import { exchangeAppleAuthorizationCode } from "../src/apple";

type WireObject = Record<string, unknown>;
type TestEnv = Env & { TEST_MIGRATIONS: D1Migration[] };

let signingKey: CryptoKey;
let publicJWK: JWK;
let appleSigningKey: CryptoKey;
let applePublicJWK: JWK;
const appleAuthorizationGrants = new Map<string, {
  subject: string;
  nonce?: string;
  refreshToken: string;
}>();
const appleTokenRequests: URLSearchParams[] = [];
const appleRevokeRequests: URLSearchParams[] = [];
let appleTokenFailure: { status: number; error: string } | null = null;
let appleTokenSuccessOverride: Record<string, unknown> | null = null;
let appleRevokeFailure: { status: number; error: string } | null = null;

function asObject(value: unknown): WireObject {
  expect(value).toBeTypeOf("object");
  expect(value).not.toBeNull();
  expect(Array.isArray(value)).toBe(false);
  return value as WireObject;
}

function nested(value: WireObject, key: string): WireObject {
  return asObject(value[key]);
}

function base64URLBytes(value: unknown): Uint8Array<ArrayBuffer> {
  expect(value).toBeTypeOf("string");
  const normalized = String(value).replaceAll("-", "+").replaceAll("_", "/");
  const binary = atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "="));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

async function userToken(subject: string): Promise<string> {
  return new SignJWT({ email: `${subject}@example.com`, name: subject })
    .setProtectedHeader({ alg: "RS256", kid: "pass-test-key" })
    .setIssuer("https://identity.pass.test/")
    .setAudience("pass-public-api")
    .setSubject(subject)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(signingKey);
}

async function appleUserToken(
  subject: string,
  options: {
    audience?: string;
    issuer?: string;
    key?: CryptoKey;
    kid?: string;
    nonce?: string;
  } = {},
): Promise<string> {
  return new SignJWT({
    email: `${subject}@privaterelay.appleid.com`,
    name: "Apple User",
    ...(options.nonce === undefined ? {} : { nonce: options.nonce }),
  })
    .setProtectedHeader({ alg: "RS256", kid: options.kid ?? "apple-test-key" })
    .setIssuer(options.issuer ?? "https://appleid.apple.com")
    .setAudience(options.audience ?? "dev.lightsoft.passmobile")
    .setSubject(subject)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(options.key ?? appleSigningKey);
}

function requestForm(init: RequestInit | undefined): URLSearchParams {
  if (init?.body instanceof URLSearchParams) return new URLSearchParams(init.body);
  if (typeof init?.body === "string") return new URLSearchParams(init.body);
  throw new Error("Expected an application/x-www-form-urlencoded request body.");
}

async function api(
  path: string,
  options: {
    token?: string;
    method?: string;
    body?: WireObject;
    ip?: string;
    headers?: HeadersInit;
  } = {},
): Promise<Response> {
  const headers = new Headers(options.headers);
  if (options.token) headers.set("Authorization", `Bearer ${options.token}`);
  if (options.ip) headers.set("CF-Connecting-IP", options.ip);
  if (options.body) headers.set("Content-Type", "application/json");
  return SELF.fetch(`https://relay.test${path}`, {
    method: options.method ?? (options.body ? "POST" : "GET"),
    headers,
    ...(options.body ? { body: JSON.stringify(options.body) } : {}),
  });
}

class TestSocket {
  private readonly inbox: WireObject[] = [];

  constructor(readonly socket: WebSocket) {
    socket.addEventListener("message", (event) => {
      if (typeof event.data === "string") this.inbox.push(asObject(JSON.parse(event.data)));
    });
    socket.accept();
  }

  send(message: WireObject): void {
    this.socket.send(JSON.stringify(message));
  }

  async next(type: string): Promise<WireObject> {
    const deadline = Date.now() + 2_000;
    while (Date.now() < deadline) {
      const index = this.inbox.findIndex((message) => message.type === type);
      if (index >= 0) {
        const message = this.inbox.splice(index, 1)[0];
        if (message) return message;
      }
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    throw new Error(`Timed out waiting for ${type}: ${JSON.stringify(this.inbox)}`);
  }

  close(): void {
    if (this.socket.readyState === 1) this.socket.close(1000, "test complete");
  }
}

async function connect(
  accessToken: string,
  spoofed: { desktopId: string; role: "desktop" | "mobile"; deviceId?: string },
): Promise<TestSocket> {
  const headers = new Headers({
    Authorization: `Bearer ${accessToken}`,
    Upgrade: "websocket",
    "X-Pass-Protocol-Version": "1",
    "X-Pass-Desktop-ID": spoofed.desktopId,
    "X-Pass-Role": spoofed.role,
  });
  if (spoofed.deviceId) headers.set("X-Pass-Device-ID", spoofed.deviceId);
  const response = await SELF.fetch("https://relay.test/connect", { headers });
  expect(response.status).toBe(101);
  expect(response.webSocket).not.toBeNull();
  return new TestSocket(response.webSocket!);
}

async function connectFromBrowser(accessToken: string): Promise<TestSocket> {
  const response = await SELF.fetch("https://relay.test/connect?version=1", {
    headers: {
      Upgrade: "websocket",
      "Sec-WebSocket-Protocol": `pass.v1, pass.auth.${accessToken}`,
    },
  });
  expect(response.status).toBe(101);
  expect(response.headers.get("Sec-WebSocket-Protocol")).toBe("pass.v1");
  expect(response.webSocket).not.toBeNull();
  return new TestSocket(response.webSocket!);
}

beforeAll(async () => {
  await applyD1Migrations(env.CONTROL_DB, (env as TestEnv).TEST_MIGRATIONS);
  const keys = await generateKeyPair("RS256", { extractable: true });
  signingKey = keys.privateKey;
  publicJWK = await exportJWK(keys.publicKey);
  publicJWK.kid = "pass-test-key";
  publicJWK.alg = "RS256";

  const appleKeys = await generateKeyPair("RS256", { extractable: true });
  appleSigningKey = appleKeys.privateKey;
  applePublicJWK = await exportJWK(appleKeys.publicKey);
  applePublicJWK.kid = "apple-test-key";
  applePublicJWK.alg = "RS256";

  vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (url === "https://identity.pass.test/.well-known/jwks.json") {
      return Response.json({ keys: [publicJWK] });
    }
    if (url === "https://appleid.apple.com/auth/keys") {
      return Response.json({ keys: [applePublicJWK] });
    }
    if (url === "https://appleid.apple.com/auth/token") {
      const form = requestForm(init);
      appleTokenRequests.push(form);
      if (appleTokenFailure !== null) {
        return Response.json(
          { error: appleTokenFailure.error },
          { status: appleTokenFailure.status },
        );
      }
      if (appleTokenSuccessOverride !== null) {
        return Response.json(appleTokenSuccessOverride);
      }
      const grant = appleAuthorizationGrants.get(form.get("code") ?? "");
      if (grant === undefined) {
        return Response.json({ error: "invalid_grant" }, { status: 400 });
      }
      return Response.json({
        access_token: "test-apple-access-token",
        expires_in: 3_600,
        token_type: "Bearer",
        refresh_token: grant.refreshToken,
        id_token: await appleUserToken(grant.subject, { nonce: grant.nonce }),
      });
    }
    if (url === "https://appleid.apple.com/auth/revoke") {
      appleRevokeRequests.push(requestForm(init));
      if (appleRevokeFailure !== null) {
        return Response.json(
          { error: appleRevokeFailure.error },
          { status: appleRevokeFailure.status },
        );
      }
      return new Response(null, { status: 200 });
    }
    throw new Error(`Unexpected external request: ${url}`);
  });
});

afterEach(() => {
  appleTokenFailure = null;
  appleTokenSuccessOverride = null;
  appleRevokeFailure = null;
});

describe("public account and device control plane", () => {
  it("requires a valid OIDC user token", async () => {
    const missing = await api("/v2/me");
    expect(missing.status).toBe(401);

    const malformed = await api("/v2/me", { token: "not-a-jwt" });
    expect(malformed.status).toBe(401);
  });

  it("accepts Apple identity tokens only with the exact trusted issuer, audience, and key", async () => {
    const validToken = await appleUserToken("apple-user");
    const valid = await api("/v2/me", { token: validToken });
    expect(valid.status).toBe(200);
    expect(nested(asObject(await valid.json()), "account")).toMatchObject({
      email: "apple-user@privaterelay.appleid.com",
      displayName: "Apple User",
    });

    const wrongAudience = await api("/v2/me", {
      token: await appleUserToken("wrong-audience", { audience: "app.lightsoft.pass" }),
    });
    expect(wrongAudience.status).toBe(401);

    const forgedSignature = await api("/v2/me", {
      token: await appleUserToken("forged-apple-user", {
        key: signingKey,
        kid: "pass-test-key",
      }),
    });
    expect(forgedSignature.status).toBe(401);

    const unknownIssuer = await api("/v2/me", {
      token: await appleUserToken("unknown-issuer", {
        issuer: "https://appleid.example.test",
      }),
    });
    expect(unknownIssuer.status).toBe(401);

    const misconfigured = await authenticateOIDCUser(
      new Request("https://relay.test/v2/me", {
        headers: { Authorization: `Bearer ${validToken}` },
      }),
      {
        CONTROL_DB: env.CONTROL_DB,
        APPLE_OIDC_ISSUER: "https://appleid.apple.com",
        APPLE_OIDC_AUDIENCE: "app.lightsoft.pass",
        APPLE_OIDC_JWKS_URL: "https://appleid.apple.com/auth/keys",
      },
    );
    expect(misconfigured).toMatchObject({
      ok: false,
      status: 503,
      code: "auth_unavailable",
    });
  });

  it("validates nonce, exchanges the Apple code, and stores only encrypted refresh metadata", async () => {
    const subject = "apple-server-authorization";
    const nonce = "nonce-for-apple-server-authorization";
    const authorizationCode = "authorization-code-for-apple-server";
    const refreshToken = "apple-refresh-token-that-must-never-be-stored-in-plaintext";
    const identityToken = await appleUserToken(subject, { nonce });
    appleAuthorizationGrants.set(authorizationCode, { subject, refreshToken });
    const initialRequestCount = appleTokenRequests.length;

    const missingNonce = await api("/v2/apple/authorization", {
      token: identityToken,
      body: { authorizationCode },
    });
    expect(missingNonce.status).toBe(400);
    const wrongNonce = await api("/v2/apple/authorization", {
      token: identityToken,
      body: { authorizationCode, nonce: `${nonce}-wrong` },
    });
    expect(wrongNonce.status).toBe(401);
    expect(appleTokenRequests).toHaveLength(initialRequestCount);

    const authorized = await api("/v2/apple/authorization", {
      token: identityToken,
      body: { authorizationCode, nonce },
    });
    expect(authorized.status).toBe(200);
    expect(asObject(await authorized.json())).toMatchObject({ authorized: true });
    expect(appleTokenRequests).toHaveLength(initialRequestCount + 1);
    const tokenForm = appleTokenRequests.at(-1)!;
    expect(tokenForm.get("client_id")).toBe("dev.lightsoft.passmobile");
    expect(tokenForm.get("code")).toBe(authorizationCode);
    expect(tokenForm.get("grant_type")).toBe("authorization_code");
    const clientSecret = tokenForm.get("client_secret")!;
    expect(decodeProtectedHeader(clientSecret)).toEqual({ alg: "ES256", kid: "TESTKEY123" });
    const clientClaims = decodeJwt(clientSecret);
    expect(clientClaims).toMatchObject({
      iss: "H66C2M66DC",
      sub: "dev.lightsoft.passmobile",
      aud: "https://appleid.apple.com",
    });
    expect(Number(clientClaims.exp) - Number(clientClaims.iat)).toBe(300);

    const metadata = await env.CONTROL_DB.prepare(
      `SELECT apple_refresh_token_ciphertext, apple_refresh_token_iv,
              apple_refresh_token_version
         FROM account_identities
        WHERE oidc_issuer = 'https://appleid.apple.com' AND oidc_subject = ?`,
    ).bind(subject).first<{
      apple_refresh_token_ciphertext: string;
      apple_refresh_token_iv: string;
      apple_refresh_token_version: number;
    }>();
    expect(metadata).not.toBeNull();
    expect(metadata?.apple_refresh_token_ciphertext).not.toContain(refreshToken);
    expect(JSON.stringify(metadata)).not.toContain(refreshToken);
    expect(base64URLBytes(metadata?.apple_refresh_token_iv)).toHaveLength(12);
    expect(metadata?.apple_refresh_token_version).toBe(1);

    const repeated = await api("/v2/apple/authorization", {
      token: identityToken,
      body: { authorizationCode: "unused-repeat-code", nonce },
    });
    expect(repeated.status).toBe(200);
    expect(appleTokenRequests).toHaveLength(initialRequestCount + 1);
  });

  it("fails closed before Apple network access when the public key id is not configured", async () => {
    const requestCount = appleTokenRequests.length;
    await expect(exchangeAppleAuthorizationCode({
      APPLE_TEAM_ID: "H66C2M66DC",
      APPLE_CLIENT_ID: "dev.lightsoft.passmobile",
    }, "unused-authorization-code")).rejects.toMatchObject({
      status: 503,
      code: "apple_service_unavailable",
      action: "retry",
    });
    expect(appleTokenRequests).toHaveLength(requestCount);
  });

  it("requires a new Apple authorization after an ambiguous token endpoint outage", async () => {
    const subject = "apple-token-endpoint-outage";
    const nonce = "apple-token-endpoint-outage-nonce";
    const token = await appleUserToken(subject, { nonce });
    appleTokenFailure = { status: 503, error: "server_error" };
    const failed = await api("/v2/apple/authorization", {
      token,
      body: { authorizationCode: "possibly-consumed-code", nonce },
    });
    expect(failed.status).toBe(503);
    expect(nested(asObject(await failed.json()), "error")).toMatchObject({
      code: "apple_authorization_uncertain",
      retryable: false,
      action: "reauthorize_with_apple",
    });
    const state = await env.CONTROL_DB.prepare(
      `SELECT apple_refresh_token_ciphertext, apple_token_operation
         FROM account_identities
        WHERE oidc_issuer = 'https://appleid.apple.com' AND oidc_subject = ?`,
    ).bind(subject).first<{
      apple_refresh_token_ciphertext: string | null;
      apple_token_operation: string | null;
    }>();
    expect(state).toEqual({
      apple_refresh_token_ciphertext: null,
      apple_token_operation: null,
    });
  });

  it("requires a new Apple authorization after an incomplete successful token response", async () => {
    const subject = "apple-incomplete-token-response";
    const nonce = "apple-incomplete-token-response-nonce";
    const token = await appleUserToken(subject, { nonce });
    appleTokenSuccessOverride = {
      access_token: "apple-access-token-without-refresh-or-identity-token",
      token_type: "Bearer",
    };
    const failed = await api("/v2/apple/authorization", {
      token,
      body: { authorizationCode: "consumed-code-with-incomplete-response", nonce },
    });
    expect(failed.status).toBe(503);
    expect(nested(asObject(await failed.json()), "error")).toMatchObject({
      code: "apple_authorization_uncertain",
      retryable: false,
      action: "reauthorize_with_apple",
    });
    const state = await env.CONTROL_DB.prepare(
      `SELECT apple_refresh_token_ciphertext, apple_token_operation
         FROM account_identities
        WHERE oidc_issuer = 'https://appleid.apple.com' AND oidc_subject = ?`,
    ).bind(subject).first<{
      apple_refresh_token_ciphertext: string | null;
      apple_token_operation: string | null;
    }>();
    expect(state).toEqual({
      apple_refresh_token_ciphertext: null,
      apple_token_operation: null,
    });
  });

  it("rejects a Google bearer before exchanging an Apple authorization code", async () => {
    const tokenRequestCount = appleTokenRequests.length;
    const response = await api("/v2/apple/authorization", {
      token: await userToken("google-cannot-exchange-apple-code"),
      body: {
        authorizationCode: "must-not-reach-apple",
        nonce: "google-bearer-nonce",
      },
    });
    expect(response.status).toBe(401);
    expect(appleTokenRequests).toHaveLength(tokenRequestCount);
  });

  it("rejects a token-exchange identity mismatch and revokes the unbound refresh token", async () => {
    const nonce = "nonce-for-mixed-apple-identities";
    const authorizationCode = "authorization-code-for-another-apple-user";
    const refreshToken = "unbound-refresh-token";
    const token = await appleUserToken("bearer-apple-user", { nonce });
    appleAuthorizationGrants.set(authorizationCode, {
      subject: "authorization-code-apple-user",
      nonce,
      refreshToken,
    });
    const revokeCount = appleRevokeRequests.length;

    const response = await api("/v2/apple/authorization", {
      token,
      body: { authorizationCode, nonce },
    });
    expect(response.status).toBe(409);
    expect(nested(asObject(await response.json()), "error")).toMatchObject({
      code: "apple_reauthorization_required",
      retryable: false,
      action: "reauthorize_with_apple",
    });
    expect(appleRevokeRequests).toHaveLength(revokeCount + 1);
    expect(appleRevokeRequests.at(-1)?.get("token")).toBe(refreshToken);
    const state = await env.CONTROL_DB.prepare(
      `SELECT apple_refresh_token_ciphertext, apple_token_operation
         FROM account_identities
        WHERE oidc_issuer = 'https://appleid.apple.com' AND oidc_subject = ?`,
    ).bind("bearer-apple-user").first<{
      apple_refresh_token_ciphertext: string | null;
      apple_token_operation: string | null;
    }>();
    expect(state).toEqual({
      apple_refresh_token_ciphertext: null,
      apple_token_operation: null,
    });
  });

  it("rejects a mismatched nonce when Apple includes one in the exchanged id token", async () => {
    const subject = "exchanged-token-wrong-nonce";
    const nonce = "expected-exchanged-token-nonce";
    const authorizationCode = "authorization-code-with-wrong-returned-nonce";
    const refreshToken = "wrong-nonce-refresh-token";
    appleAuthorizationGrants.set(authorizationCode, {
      subject,
      nonce: "different-returned-nonce",
      refreshToken,
    });
    const response = await api("/v2/apple/authorization", {
      token: await appleUserToken(subject, { nonce }),
      body: { authorizationCode, nonce },
    });
    expect(response.status).toBe(409);
    expect(appleRevokeRequests.at(-1)?.get("token")).toBe(refreshToken);
  });

  it("links an empty Apple identity to the Google desktop account while claiming its QR", async () => {
    const googleToken = await userToken("identity-link-google");
    const nonce = "nonce-for-linked-apple-identity";
    const authorizationCode = "authorization-code-for-linked-apple-identity";
    const refreshToken = "refresh-token-for-linked-apple-identity";
    const appleToken = await appleUserToken("identity-link-apple", { nonce });
    appleAuthorizationGrants.set(authorizationCode, {
      subject: "identity-link-apple",
      nonce,
      refreshToken,
    });
    const googleMe = await api("/v2/me", { token: googleToken });
    const googleAccount = nested(asObject(await googleMe.json()), "account");
    const appleAuthorization = await api("/v2/apple/authorization", {
      token: appleToken,
      body: { authorizationCode, nonce },
    });
    expect(appleAuthorization.status).toBe(200);
    const temporaryAppleAccount = nested(
      asObject(await appleAuthorization.json()),
      "account",
    );
    expect(temporaryAppleAccount.id).not.toBe(googleAccount.id);
    const tokenMetadataBeforeLink = await env.CONTROL_DB.prepare(
      `SELECT apple_refresh_token_ciphertext FROM account_identities
        WHERE oidc_issuer = 'https://appleid.apple.com' AND oidc_subject = ?`,
    ).bind("identity-link-apple").first<{ apple_refresh_token_ciphertext: string }>();
    expect(tokenMetadataBeforeLink?.apple_refresh_token_ciphertext).toBeTypeOf("string");

    const registered = await api("/v2/desktops", {
      token: googleToken,
      body: { name: "Linked Mac" },
    });
    const registration = asObject(await registered.json());
    const desktop = nested(registration, "desktop");
    const pairingResponse = await api("/v2/pairings", {
      token: String(nested(registration, "credentials").accessToken),
      body: {},
    });
    const pairing = nested(asObject(await pairingResponse.json()), "pairing");

    const claimed = await api(`/v2/pairings/${String(pairing.pairingId)}/claim`, {
      token: appleToken,
      body: {
        pairingSecret: pairing.pairingSecret,
        deviceName: "Linked iPhone",
        platform: "ios",
      },
    });
    expect(claimed.status).toBe(201);
    expect(nested(asObject(await claimed.json()), "desktop").id).toBe(desktop.id);

    const appleMeAfter = await api("/v2/me", { token: appleToken });
    expect(nested(asObject(await appleMeAfter.json()), "account").id).toBe(googleAccount.id);
    const appleDesktops = await api("/v2/desktops", { token: appleToken });
    expect(asObject(await appleDesktops.json()).desktops).toEqual([
      expect.objectContaining({ id: desktop.id }),
    ]);

    const linkedIdentities = await env.CONTROL_DB.prepare(
      `SELECT oidc_issuer FROM account_identities
        WHERE account_id = ? ORDER BY oidc_issuer`,
    ).bind(googleAccount.id).all<{ oidc_issuer: string }>();
    expect(linkedIdentities.results.map((identity) => identity.oidc_issuer)).toEqual([
      "https://appleid.apple.com",
      "https://identity.pass.test/",
    ]);
    const tokenMetadataAfterLink = await env.CONTROL_DB.prepare(
      `SELECT apple_refresh_token_ciphertext FROM account_identities
        WHERE oidc_issuer = 'https://appleid.apple.com' AND oidc_subject = ?
          AND account_id = ?`,
    ).bind("identity-link-apple", googleAccount.id).first<{
      apple_refresh_token_ciphertext: string;
    }>();
    expect(tokenMetadataAfterLink?.apple_refresh_token_ciphertext).toBe(
      tokenMetadataBeforeLink?.apple_refresh_token_ciphertext,
    );
    const removedTemporaryAccount = await env.CONTROL_DB.prepare(
      "SELECT id FROM accounts WHERE id = ?",
    ).bind(temporaryAppleAccount.id).first();
    expect(removedTemporaryAccount).toBeNull();

    const revokeCount = appleRevokeRequests.length;
    const deletedWithGoogle = await api("/v2/account", {
      token: googleToken,
      method: "DELETE",
    });
    expect(deletedWithGoogle.status).toBe(200);
    expect(appleRevokeRequests).toHaveLength(revokeCount + 1);
    expect(appleRevokeRequests.at(-1)?.get("token")).toBe(refreshToken);
  });

  it("does not link without the QR secret or merge an Apple account that owns resources", async () => {
    const googleToken = await userToken("identity-conflict-google");
    const appleToken = await appleUserToken("identity-conflict-apple");
    const registered = await api("/v2/desktops", {
      token: googleToken,
      body: { name: "Protected Mac" },
    });
    const registration = asObject(await registered.json());
    const pairingResponse = await api("/v2/pairings", {
      token: String(nested(registration, "credentials").accessToken),
      body: {},
    });
    const pairing = nested(asObject(await pairingResponse.json()), "pairing");
    const appleMe = await api("/v2/me", { token: appleToken });
    const appleAccount = nested(asObject(await appleMe.json()), "account");

    const wrongSecret = await api(`/v2/pairings/${String(pairing.pairingId)}/claim`, {
      token: appleToken,
      body: {
        pairingSecret: "not-the-qr-secret",
        deviceName: "Untrusted iPhone",
        platform: "ios",
      },
    });
    expect(wrongSecret.status).toBe(409);
    expect(nested(asObject(await wrongSecret.json()), "error").code).toBe("pairing_unavailable");
    const appleAfterWrongSecret = await api("/v2/me", { token: appleToken });
    expect(nested(asObject(await appleAfterWrongSecret.json()), "account").id).toBe(appleAccount.id);

    const appleDesktop = await api("/v2/desktops", {
      token: appleToken,
      body: { name: "Apple-owned Mac" },
    });
    expect(appleDesktop.status).toBe(201);
    const conflict = await api(`/v2/pairings/${String(pairing.pairingId)}/claim`, {
      token: appleToken,
      body: {
        pairingSecret: pairing.pairingSecret,
        deviceName: "Conflict iPhone",
        platform: "ios",
      },
    });
    expect(conflict.status).toBe(409);
    expect(nested(asObject(await conflict.json()), "error").code).toBe("account_link_conflict");

    const ownerClaim = await api(`/v2/pairings/${String(pairing.pairingId)}/claim`, {
      token: googleToken,
      body: {
        pairingSecret: pairing.pairingSecret,
        deviceName: "Owner iPhone",
        platform: "ios",
      },
    });
    expect(ownerClaim.status).toBe(201);
  });

  it("keeps account data on revoke outages and allows reauthorization after invalid_grant", async () => {
    const subject = "apple-delete-reauthorization";
    const firstNonce = "first-delete-authorization-nonce";
    const firstCode = "first-delete-authorization-code";
    const firstRefreshToken = "first-delete-refresh-token";
    const firstIdentityToken = await appleUserToken(subject, { nonce: firstNonce });
    appleAuthorizationGrants.set(firstCode, {
      subject,
      nonce: firstNonce,
      refreshToken: firstRefreshToken,
    });
    const authorized = await api("/v2/apple/authorization", {
      token: firstIdentityToken,
      body: { authorizationCode: firstCode, nonce: firstNonce },
    });
    expect(authorized.status).toBe(200);
    const account = nested(asObject(await authorized.json()), "account");
    const desktopResponse = await api("/v2/desktops", {
      token: firstIdentityToken,
      body: { name: "Deletion Retry Mac" },
    });
    expect(desktopResponse.status).toBe(201);

    appleRevokeFailure = { status: 503, error: "server_error" };
    const outage = await api("/v2/account", {
      token: firstIdentityToken,
      method: "DELETE",
    });
    expect(outage.status).toBe(503);
    expect(nested(asObject(await outage.json()), "error")).toMatchObject({
      code: "apple_service_unavailable",
      retryable: true,
      action: "retry",
      manualRevocationAvailable: true,
    });
    expect(await env.CONTROL_DB.prepare(
      "SELECT id FROM accounts WHERE id = ?",
    ).bind(account.id).first()).not.toBeNull();
    const tokenAfterOutage = await env.CONTROL_DB.prepare(
      `SELECT apple_refresh_token_ciphertext FROM account_identities
        WHERE oidc_issuer = 'https://appleid.apple.com' AND oidc_subject = ?`,
    ).bind(subject).first<{ apple_refresh_token_ciphertext: string | null }>();
    expect(tokenAfterOutage?.apple_refresh_token_ciphertext).toBeTypeOf("string");

    appleRevokeFailure = { status: 400, error: "invalid_grant" };
    const invalidGrant = await api("/v2/account", {
      token: firstIdentityToken,
      method: "DELETE",
    });
    expect(invalidGrant.status).toBe(409);
    expect(nested(asObject(await invalidGrant.json()), "error")).toMatchObject({
      code: "apple_reauthorization_required",
      retryable: false,
      action: "reauthorize_with_apple",
      manualRevocationAvailable: true,
    });
    const cleared = await env.CONTROL_DB.prepare(
      `SELECT apple_refresh_token_ciphertext, apple_token_operation
         FROM account_identities
        WHERE oidc_issuer = 'https://appleid.apple.com' AND oidc_subject = ?`,
    ).bind(subject).first<{
      apple_refresh_token_ciphertext: string | null;
      apple_token_operation: string | null;
    }>();
    expect(cleared).toEqual({
      apple_refresh_token_ciphertext: null,
      apple_token_operation: null,
    });
    expect(await env.CONTROL_DB.prepare(
      "SELECT id FROM accounts WHERE id = ?",
    ).bind(account.id).first()).not.toBeNull();

    appleRevokeFailure = null;
    const secondNonce = "second-delete-authorization-nonce";
    const secondCode = "second-delete-authorization-code";
    const secondRefreshToken = "second-delete-refresh-token";
    const secondIdentityToken = await appleUserToken(subject, { nonce: secondNonce });
    appleAuthorizationGrants.set(secondCode, {
      subject,
      nonce: secondNonce,
      refreshToken: secondRefreshToken,
    });
    const reauthorized = await api("/v2/apple/authorization", {
      token: secondIdentityToken,
      body: { authorizationCode: secondCode, nonce: secondNonce },
    });
    expect(reauthorized.status).toBe(200);

    const deleted = await api("/v2/account", {
      token: secondIdentityToken,
      method: "DELETE",
    });
    expect(deleted.status).toBe(200);
    expect(appleRevokeRequests.at(-1)?.get("token")).toBe(secondRefreshToken);
    expect(await env.CONTROL_DB.prepare(
      "SELECT id FROM accounts WHERE id = ?",
    ).bind(account.id).first()).toBeNull();
  });

  it("fails closed when an Apple identity has no stored refresh token", async () => {
    const token = await appleUserToken("apple-delete-without-token");
    const me = await api("/v2/me", { token });
    const account = nested(asObject(await me.json()), "account");
    const deleted = await api("/v2/account", { token, method: "DELETE" });
    expect(deleted.status).toBe(409);
    expect(nested(asObject(await deleted.json()), "error")).toMatchObject({
      code: "apple_reauthorization_required",
      retryable: false,
      action: "reauthorize_with_apple",
      manualRevocationAvailable: true,
    });
    expect(await env.CONTROL_DB.prepare(
      "SELECT id FROM accounts WHERE id = ?",
    ).bind(account.id).first()).not.toBeNull();

    const incorrectlyCasedFallback = await api("/v2/account", {
      token,
      method: "DELETE",
      headers: { "X-Pass-Apple-Revocation-Fallback": "Manual" },
    });
    expect(incorrectlyCasedFallback.status).toBe(409);
    expect(await env.CONTROL_DB.prepare(
      "SELECT id FROM accounts WHERE id = ?",
    ).bind(account.id).first()).not.toBeNull();

    const manual = await api("/v2/account", {
      token,
      method: "DELETE",
      headers: { "X-Pass-Apple-Revocation-Fallback": "manual" },
    });
    expect(manual.status).toBe(200);
    expect(asObject(await manual.json())).toEqual({
      deleted: true,
      appleRevocation: "manual_required",
    });
    expect(await env.CONTROL_DB.prepare(
      "SELECT id FROM accounts WHERE id = ?",
    ).bind(account.id).first()).toBeNull();
  });

  it("allows explicit manual deletion after an Apple revocation outage", async () => {
    const subject = "apple-manual-delete-after-outage";
    const nonce = "apple-manual-delete-after-outage-nonce";
    const code = "apple-manual-delete-after-outage-code";
    const refreshToken = "apple-manual-delete-after-outage-refresh";
    const token = await appleUserToken(subject, { nonce });
    appleAuthorizationGrants.set(code, { subject, nonce, refreshToken });
    const authorized = await api("/v2/apple/authorization", {
      token,
      body: { authorizationCode: code, nonce },
    });
    const account = nested(asObject(await authorized.json()), "account");

    appleRevokeFailure = { status: 503, error: "server_error" };
    const revokeCount = appleRevokeRequests.length;
    const automatic = await api("/v2/account", { token, method: "DELETE" });
    expect(automatic.status).toBe(503);
    expect(nested(asObject(await automatic.json()), "error")).toMatchObject({
      code: "apple_service_unavailable",
      retryable: true,
      action: "retry",
      manualRevocationAvailable: true,
    });
    expect(appleRevokeRequests).toHaveLength(revokeCount + 1);

    const manual = await api("/v2/account", {
      token,
      method: "DELETE",
      headers: { "X-Pass-Apple-Revocation-Fallback": "manual" },
    });
    expect(manual.status).toBe(200);
    expect(asObject(await manual.json())).toEqual({
      deleted: true,
      appleRevocation: "manual_required",
    });
    expect(appleRevokeRequests).toHaveLength(revokeCount + 1);
    expect(await env.CONTROL_DB.prepare(
      "SELECT id FROM accounts WHERE id = ?",
    ).bind(account.id).first()).toBeNull();
  });

  it("serializes Apple authorization and deletion operations per identity", async () => {
    const subject = "apple-operation-lock";
    const nonce = "apple-operation-lock-nonce";
    const code = "apple-operation-lock-code";
    const refreshToken = "apple-operation-lock-refresh-token";
    const token = await appleUserToken(subject, { nonce });
    appleAuthorizationGrants.set(code, { subject, nonce, refreshToken });
    expect((await api("/v2/apple/authorization", {
      token,
      body: { authorizationCode: code, nonce },
    })).status).toBe(200);

    await env.CONTROL_DB.prepare(
      `UPDATE account_identities
          SET apple_token_operation = 'authorizing',
              apple_token_operation_id = 'competing-authorization',
              apple_token_operation_started_at = ?
        WHERE oidc_issuer = 'https://appleid.apple.com' AND oidc_subject = ?`,
    ).bind(Date.now(), subject).run();
    const revokeCount = appleRevokeRequests.length;
    const blockedDelete = await api("/v2/account", { token, method: "DELETE" });
    expect(blockedDelete.status).toBe(503);
    expect(appleRevokeRequests).toHaveLength(revokeCount);
    const blockedManualDelete = await api("/v2/account", {
      token,
      method: "DELETE",
      headers: { "X-Pass-Apple-Revocation-Fallback": "manual" },
    });
    expect(blockedManualDelete.status).toBe(503);
    const blockedManualError = nested(asObject(await blockedManualDelete.json()), "error");
    expect(blockedManualError).toMatchObject({
      code: "apple_operation_in_progress",
      retryable: true,
      action: "retry",
    });
    expect(blockedManualError).not.toHaveProperty("manualRevocationAvailable");

    await env.CONTROL_DB.prepare(
      `UPDATE account_identities
          SET apple_token_operation = 'deleting',
              apple_token_operation_id = 'competing-deletion',
              apple_token_operation_started_at = ?
        WHERE oidc_issuer = 'https://appleid.apple.com' AND oidc_subject = ?`,
    ).bind(Date.now(), subject).run();
    const tokenRequestCount = appleTokenRequests.length;
    const concurrentRevokeCount = appleRevokeRequests.length;
    const blockedConcurrentDelete = await api("/v2/account", {
      token,
      method: "DELETE",
    });
    expect(blockedConcurrentDelete.status).toBe(503);
    expect(appleRevokeRequests).toHaveLength(concurrentRevokeCount);
    const blockedConcurrentManualDelete = await api("/v2/account", {
      token,
      method: "DELETE",
      headers: { "X-Pass-Apple-Revocation-Fallback": "manual" },
    });
    expect(blockedConcurrentManualDelete.status).toBe(503);
    expect(appleRevokeRequests).toHaveLength(concurrentRevokeCount);
    const blockedAuthorization = await api("/v2/apple/authorization", {
      token,
      body: { authorizationCode: "must-not-be-exchanged", nonce },
    });
    expect(blockedAuthorization.status).toBe(503);
    expect(appleTokenRequests).toHaveLength(tokenRequestCount);

    await env.CONTROL_DB.prepare(
      `UPDATE account_identities
          SET apple_token_operation = NULL, apple_token_operation_id = NULL,
              apple_token_operation_started_at = NULL
        WHERE oidc_issuer = 'https://appleid.apple.com' AND oidc_subject = ?`,
    ).bind(subject).run();
    expect((await api("/v2/account", { token, method: "DELETE" })).status).toBe(200);
  });

  it("retries only local cleanup after Apple revocation has already succeeded", async () => {
    const subject = "apple-direct-cleanup-retry";
    const nonce = "apple-direct-cleanup-retry-nonce";
    const code = "apple-direct-cleanup-retry-code";
    const refreshToken = "apple-direct-cleanup-retry-refresh";
    const token = await appleUserToken(subject, { nonce });
    appleAuthorizationGrants.set(code, { subject, nonce, refreshToken });
    const authorized = await api("/v2/apple/authorization", {
      token,
      body: { authorizationCode: code, nonce },
    });
    const account = nested(asObject(await authorized.json()), "account");

    await env.CONTROL_DB.prepare(
      `CREATE TRIGGER fail_apple_direct_cleanup_retry
         BEFORE DELETE ON accounts
         BEGIN SELECT RAISE(ABORT, 'test cleanup failure'); END`,
    ).run();
    const revokeCountBeforeFailure = appleRevokeRequests.length;
    let failedCleanup: Response;
    try {
      failedCleanup = await api("/v2/account", { token, method: "DELETE" });
    } finally {
      await env.CONTROL_DB.prepare("DROP TRIGGER fail_apple_direct_cleanup_retry").run();
    }
    expect(failedCleanup.status).toBe(503);
    expect(appleRevokeRequests).toHaveLength(revokeCountBeforeFailure + 1);
    expect(appleRevokeRequests.at(-1)?.get("token")).toBe(refreshToken);

    const revokeCountBeforeRetry = appleRevokeRequests.length;
    const retried = await api("/v2/account", { token, method: "DELETE" });
    expect(retried.status).toBe(200);
    expect(appleRevokeRequests).toHaveLength(revokeCountBeforeRetry);
    expect(await env.CONTROL_DB.prepare(
      "SELECT id FROM accounts WHERE id = ?",
    ).bind(account.id).first()).toBeNull();
  });

  it("reauthorizes and revokes a new token after post-revoke local cleanup fails", async () => {
    const subject = "apple-post-revoke-cleanup-retry";
    const firstNonce = "post-revoke-cleanup-first-nonce";
    const firstCode = "post-revoke-cleanup-first-code";
    const firstRefreshToken = "post-revoke-cleanup-first-refresh";
    const firstToken = await appleUserToken(subject, { nonce: firstNonce });
    appleAuthorizationGrants.set(firstCode, {
      subject,
      nonce: firstNonce,
      refreshToken: firstRefreshToken,
    });
    const authorized = await api("/v2/apple/authorization", {
      token: firstToken,
      body: { authorizationCode: firstCode, nonce: firstNonce },
    });
    const account = nested(asObject(await authorized.json()), "account");

    await env.CONTROL_DB.prepare(
      `CREATE TRIGGER fail_apple_account_cleanup
         BEFORE DELETE ON accounts
         BEGIN SELECT RAISE(ABORT, 'test cleanup failure'); END`,
    ).run();
    let failedCleanup: Response;
    try {
      failedCleanup = await api("/v2/account", { token: firstToken, method: "DELETE" });
    } finally {
      await env.CONTROL_DB.prepare("DROP TRIGGER fail_apple_account_cleanup").run();
    }
    expect(failedCleanup.status).toBe(503);
    expect(nested(asObject(await failedCleanup.json()), "error")).toMatchObject({
      code: "account_deletion_unavailable",
      retryable: true,
    });
    expect(appleRevokeRequests.at(-1)?.get("token")).toBe(firstRefreshToken);
    const pendingCleanup = await env.CONTROL_DB.prepare(
      `SELECT apple_refresh_token_ciphertext, apple_refresh_token_revoked_at,
              apple_token_operation
         FROM account_identities
        WHERE oidc_issuer = 'https://appleid.apple.com' AND oidc_subject = ?`,
    ).bind(subject).first<{
      apple_refresh_token_ciphertext: string | null;
      apple_refresh_token_revoked_at: number | null;
      apple_token_operation: string | null;
    }>();
    expect(pendingCleanup).toMatchObject({
      apple_refresh_token_ciphertext: null,
      apple_token_operation: null,
    });
    expect(pendingCleanup?.apple_refresh_token_revoked_at).toBeTypeOf("number");
    expect(await env.CONTROL_DB.prepare(
      "SELECT id FROM accounts WHERE id = ?",
    ).bind(account.id).first()).not.toBeNull();

    const secondNonce = "post-revoke-cleanup-second-nonce";
    const secondCode = "post-revoke-cleanup-second-code";
    const secondRefreshToken = "post-revoke-cleanup-second-refresh";
    const secondToken = await appleUserToken(subject, { nonce: secondNonce });
    appleAuthorizationGrants.set(secondCode, {
      subject,
      nonce: secondNonce,
      refreshToken: secondRefreshToken,
    });
    const requestCount = appleTokenRequests.length;
    const reauthorized = await api("/v2/apple/authorization", {
      token: secondToken,
      body: { authorizationCode: secondCode, nonce: secondNonce },
    });
    expect(reauthorized.status).toBe(200);
    expect(appleTokenRequests).toHaveLength(requestCount + 1);

    const deleted = await api("/v2/account", { token: secondToken, method: "DELETE" });
    expect(deleted.status).toBe(200);
    expect(appleRevokeRequests.at(-1)?.get("token")).toBe(secondRefreshToken);
  });

  it("publishes only the configured Google browser client id", async () => {
    const response = await api("/v2/web/config");
    expect(response.status).toBe(200);
    expect(asObject(await response.json())).toEqual({ googleClientId: "pass-public-api" });
  });

  it("pairs a Steam Deck through phone approval without exposing credentials in the QR", async () => {
    const ownerToken = await userToken("deck-owner");
    const otherToken = await userToken("deck-other");
    const registered = await api("/v2/desktops", {
      token: ownerToken,
      body: { name: "Deck Host" },
    });
    const desktop = nested(asObject(await registered.json()), "desktop");
    const keyPair = await crypto.subtle.generateKey(
      { name: "RSA-OAEP", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
      true,
      ["encrypt", "decrypt"],
    );
    const publicKey = await crypto.subtle.exportKey("jwk", keyPair.publicKey);
    const created = await api("/v2/deck-pairings", {
      body: { deviceName: "Steam Deck OLED", publicKey },
    });
    expect(created.status).toBe(201);
    const pairing = nested(asObject(await created.json()), "pairing");
    expect(pairing.v).toBe(3);
    expect(pairing).not.toHaveProperty("credentials");

    const pending = await api(`/v2/deck-pairings/${String(pairing.pairingId)}/poll`, {
      body: { pollSecret: pairing.pollSecret },
    });
    expect(pending.status).toBe(202);

    const wrongAccount = await api(`/v2/deck-pairings/${String(pairing.pairingId)}/approve`, {
      token: otherToken,
      body: { approvalSecret: pairing.approvalSecret, desktopId: desktop.id },
    });
    expect(wrongAccount.status).toBe(404);

    const approved = await api(`/v2/deck-pairings/${String(pairing.pairingId)}/approve`, {
      token: ownerToken,
      body: { approvalSecret: pairing.approvalSecret, desktopId: desktop.id },
    });
    expect(approved.status).toBe(200);

    const delivered = await api(`/v2/deck-pairings/${String(pairing.pairingId)}/poll`, {
      body: { pollSecret: pairing.pollSecret },
    });
    expect(delivered.status).toBe(200);
    const envelope = nested(asObject(await delivered.json()), "envelope");
    expect(envelope.wrappedKey).toBeTypeOf("string");
    expect(envelope.ciphertext).toBeTypeOf("string");
    const rawAESKey = await crypto.subtle.decrypt(
      { name: "RSA-OAEP" },
      keyPair.privateKey,
      base64URLBytes(envelope.wrappedKey),
    );
    const aesKey = await crypto.subtle.importKey("raw", rawAESKey, "AES-GCM", false, ["decrypt"]);
    const plaintext = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: base64URLBytes(envelope.iv) },
      aesKey,
      base64URLBytes(envelope.ciphertext),
    );
    const handoff = asObject(JSON.parse(new TextDecoder().decode(plaintext)));
    expect(handoff.desktopId).toBe(desktop.id);
    expect(nested(handoff, "credentials").refreshToken).toMatch(/^pass_rt_cred_/);

    const replay = await api(`/v2/deck-pairings/${String(pairing.pairingId)}/poll`, {
      body: { pollSecret: pairing.pollSecret },
    });
    expect(replay.status).toBe(200);
  });

  it("registers, pairs, routes, rotates, and revokes device credentials", async () => {
    const ownerToken = await userToken("owner-user");
    const otherToken = await userToken("other-user");

    const me = await api("/v2/me", { token: ownerToken });
    expect(me.status).toBe(200);
    const account = nested(asObject(await me.json()), "account");
    expect(account.id).toMatch(/^acct_[a-f0-9]{40}$/);

    const registered = await api("/v2/desktops", {
      token: ownerToken,
      body: { name: "Studio Mac" },
    });
    expect(registered.status).toBe(201);
    const registration = asObject(await registered.json());
    const desktop = nested(registration, "desktop");
    const desktopCredentials = nested(registration, "credentials");
    expect(desktop.id).toMatch(/^desk_[a-f0-9]{32}$/);
    expect(desktopCredentials.accessToken).toMatch(/^pass_at_cred_/);
    expect(desktopCredentials.refreshToken).toMatch(/^pass_rt_cred_/);

    const accountController = await api(`/v2/desktops/${String(desktop.id)}/controllers`, {
      token: ownerToken,
      body: { deviceName: "Owner MacBook", platform: "macos" },
    });
    expect(accountController.status).toBe(201);
    const accountControllerPayload = asObject(await accountController.json());
    expect(nested(accountControllerPayload, "desktop").id).toBe(desktop.id);
    expect(nested(accountControllerPayload, "device").platform).toBe("macos");
    expect(nested(accountControllerPayload, "credentials").accessToken).toMatch(/^pass_at_cred_/);
    expect(accountControllerPayload.scopes).toContain("sessions:terminal");

    // The browser cannot add Authorization to a WebSocket upgrade. Its issued credential may
    // travel in a WebSocket subprotocol, but development credentials cannot use this route.
    const browserSocket = await connectFromBrowser(
      String(nested(accountControllerPayload, "credentials").accessToken),
    );
    expect((await browserSocket.next("relay.ready")).payload).toMatchObject({
      desktopId: desktop.id,
      role: "mobile",
    });
    browserSocket.close();

    const crossAccountController = await api(`/v2/desktops/${String(desktop.id)}/controllers`, {
      token: otherToken,
      body: { deviceName: "Other Mac", platform: "macos" },
    });
    expect(crossAccountController.status).toBe(404);

    const desktopSocket = await connect(String(desktopCredentials.accessToken), {
      desktopId: "desk_spoofed",
      role: "mobile",
      deviceId: "device_spoofed",
    });

    const createdPairing = await api("/v2/pairings", {
      token: String(desktopCredentials.accessToken),
      body: {},
    });
    expect(createdPairing.status).toBe(201);
    const pairing = nested(asObject(await createdPairing.json()), "pairing");
    expect(pairing.v).toBe(2);
    expect(pairing.desktopId).toBe(desktop.id);
    expect(pairing).not.toHaveProperty("authorizationToken");

    const crossAccountClaim = await api(`/v2/pairings/${String(pairing.pairingId)}/claim`, {
      token: otherToken,
      body: {
        pairingSecret: pairing.pairingSecret,
        deviceName: "Other phone",
        platform: "ios",
      },
    });
    expect(crossAccountClaim.status).toBe(409);

    const claimed = await api(`/v2/pairings/${String(pairing.pairingId)}/claim`, {
      token: ownerToken,
      body: {
        pairingSecret: pairing.pairingSecret,
        deviceName: "Owner iPhone",
        platform: "ios",
      },
    });
    expect(claimed.status).toBe(201);
    const claim = asObject(await claimed.json());
    const device = nested(claim, "device");
    const mobileCredentials = nested(claim, "credentials");
    expect(claim.scopes).toContain("sessions:write");
    expect(claim.scopes).toContain("sessions:terminal");

    const crossAccountDesktopRevoke = await api(`/v2/desktops/${String(desktop.id)}`, {
      token: otherToken,
      method: "DELETE",
    });
    expect(crossAccountDesktopRevoke.status).toBe(404);
    const crossAccountDeviceRevoke = await api(`/v2/devices/${String(device.id)}`, {
      token: otherToken,
      method: "DELETE",
    });
    expect(crossAccountDeviceRevoke.status).toBe(404);
    const pairingStillActive = await env.CONTROL_DB.prepare(
      "SELECT revoked_at FROM desktop_devices WHERE desktop_id = ? AND device_id = ?",
    ).bind(desktop.id, device.id).first<{ revoked_at: number | null }>();
    expect(pairingStillActive?.revoked_at).toBeNull();

    const reused = await api(`/v2/pairings/${String(pairing.pairingId)}/claim`, {
      token: ownerToken,
      body: {
        pairingSecret: pairing.pairingSecret,
        deviceName: "Second phone",
        platform: "ios",
      },
    });
    expect(reused.status).toBe(409);

    const mobileSocket = await connect(String(mobileCredentials.accessToken), {
      desktopId: "desk_spoofed",
      role: "desktop",
    });
    const ready = await mobileSocket.next("relay.ready");
    const readyPayload = nested(ready, "payload");
    expect(readyPayload.desktopId).toBe(desktop.id);
    expect(readyPayload.deviceId).toBe(device.id);
    expect(readyPayload.role).toBe("mobile");

    const commandId = "cmd_public_route";
    mobileSocket.send({
      version: 1,
      id: commandId,
      type: "session.list",
      sentAt: "2026-07-18T00:00:00Z",
      payload: {},
    });
    const forwarded = await desktopSocket.next("session.list");
    expect(forwarded.id).toBe(commandId);

    const refreshed = await api("/v2/token/refresh", {
      token: String(mobileCredentials.refreshToken),
      method: "POST",
    });
    expect(refreshed.status).toBe(200);
    const refreshedCredentials = nested(asObject(await refreshed.json()), "credentials");
    expect(refreshedCredentials.refreshToken).not.toBe(mobileCredentials.refreshToken);

    const replayedRefresh = await api("/v2/token/refresh", {
      token: String(mobileCredentials.refreshToken),
      method: "POST",
    });
    expect(replayedRefresh.status).toBe(401);

    const revoked = await api(`/v2/devices/${String(device.id)}`, {
      token: ownerToken,
      method: "DELETE",
    });
    expect(revoked.status).toBe(200);

    const rejected = await SELF.fetch("https://relay.test/connect", {
      headers: {
        Authorization: `Bearer ${String(refreshedCredentials.accessToken)}`,
        Upgrade: "websocket",
        "X-Pass-Protocol-Version": "1",
      },
    });
    expect(rejected.status).toBe(401);

    mobileSocket.close();
    desktopSocket.close();
  });

  it("invalidates pending pairings and mobile credentials when a desktop is revoked", async () => {
    const token = await userToken("revoke-desktop-user");
    const registered = await api("/v2/desktops", {
      token,
      body: { name: "Revoked Mac" },
    });
    expect(registered.status).toBe(201);
    const registration = asObject(await registered.json());
    const desktop = nested(registration, "desktop");
    const desktopCredentials = nested(registration, "credentials");

    const claimedPairingResponse = await api("/v2/pairings", {
      token: String(desktopCredentials.accessToken),
      body: {},
    });
    const pendingPairingResponse = await api("/v2/pairings", {
      token: String(desktopCredentials.accessToken),
      body: {},
    });
    expect(claimedPairingResponse.status).toBe(201);
    expect(pendingPairingResponse.status).toBe(201);
    const claimedPairing = nested(asObject(await claimedPairingResponse.json()), "pairing");
    const pendingPairing = nested(asObject(await pendingPairingResponse.json()), "pairing");

    const claimed = await api(`/v2/pairings/${String(claimedPairing.pairingId)}/claim`, {
      token,
      body: {
        pairingSecret: claimedPairing.pairingSecret,
        deviceName: "Soon Revoked Phone",
        platform: "ios",
      },
    });
    expect(claimed.status).toBe(201);
    const mobileCredentials = nested(asObject(await claimed.json()), "credentials");

    const revoked = await api(`/v2/desktops/${String(desktop.id)}`, {
      token,
      method: "DELETE",
    });
    expect(revoked.status).toBe(200);

    const staleClaim = await api(`/v2/pairings/${String(pendingPairing.pairingId)}/claim`, {
      token,
      body: {
        pairingSecret: pendingPairing.pairingSecret,
        deviceName: "Late Phone",
        platform: "android",
      },
    });
    expect(staleClaim.status).toBe(409);

    const rejected = await SELF.fetch("https://relay.test/connect", {
      headers: {
        Authorization: `Bearer ${String(mobileCredentials.accessToken)}`,
        Upgrade: "websocket",
        "X-Pass-Protocol-Version": "1",
      },
    });
    expect(rejected.status).toBe(401);
  });

  it("rate limits repeated pairing attempts by credential fingerprint", async () => {
    for (let attempt = 0; attempt < 20; attempt += 1) {
      const response = await api("/v2/pairings", {
        token: "rate-limit-test-credential",
        ip: "198.51.100.10",
        body: {},
      });
      expect(response.status).toBe(401);
    }

    const limited = await api("/v2/pairings", {
      token: "rate-limit-test-credential",
      ip: "198.51.100.10",
      body: {},
    });
    expect(limited.status).toBe(429);
    expect(limited.headers.get("Retry-After")).toBe("60");
  });

  it("rate limits rotating invalid credentials by connecting IP", async () => {
    for (let attempt = 0; attempt < 20; attempt += 1) {
      const response = await api("/v2/pairings", {
        token: `rotating-invalid-credential-${attempt}`,
        ip: "198.51.100.20",
        body: {},
      });
      expect(response.status).toBe(401);
    }

    const limited = await api("/v2/pairings", {
      token: "rotating-invalid-credential-final",
      ip: "198.51.100.20",
      body: {},
    });
    expect(limited.status).toBe(429);
  });

  it("deletes an account and immediately rejects its desktop credential", async () => {
    const token = await userToken("delete-user");
    const registered = await api("/v2/desktops", {
      token,
      body: { name: "Disposable Mac" },
    });
    expect(registered.status).toBe(201);
    const credentials = nested(asObject(await registered.json()), "credentials");

    const deleted = await api("/v2/account", {
      token,
      method: "DELETE",
      headers: { "X-Pass-Apple-Revocation-Fallback": "manual" },
    });
    expect(deleted.status).toBe(200);
    await expect(deleted.json()).resolves.toEqual({ deleted: true });

    const rejected = await SELF.fetch("https://relay.test/connect", {
      headers: {
        Authorization: `Bearer ${String(credentials.accessToken)}`,
        Upgrade: "websocket",
        "X-Pass-Protocol-Version": "1",
      },
    });
    expect(rejected.status).toBe(401);
  });

  it("purges relay rooms for previously revoked desktops during account deletion", async () => {
    const token = await userToken("delete-revoked-user");
    const registered = await api("/v2/desktops", {
      token,
      body: { name: "Previously Revoked Mac" },
    });
    expect(registered.status).toBe(201);
    const payload = asObject(await registered.json());
    const desktop = nested(payload, "desktop");
    const credentials = nested(payload, "credentials");
    const desktopSocket = await connect(String(credentials.accessToken), {
      desktopId: String(desktop.id),
      role: "desktop",
    });

    // Simulate a historical/interrupted revoke that updated D1 but did not purge the room.
    await env.CONTROL_DB.prepare(
      "UPDATE desktops SET revoked_at = ? WHERE id = ?",
    ).bind(Date.now(), desktop.id).run();

    const deleted = await api("/v2/account", { token, method: "DELETE" });
    expect(deleted.status).toBe(200);
    await vi.waitFor(() => expect(desktopSocket.socket.readyState).toBe(3));
  });
});
