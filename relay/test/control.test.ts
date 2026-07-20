import {
  SELF,
  applyD1Migrations,
  env,
  type D1Migration,
} from "cloudflare:test";
import {
  SignJWT,
  exportJWK,
  generateKeyPair,
  type CryptoKey,
  type JWK,
} from "jose";
import { beforeAll, describe, expect, it, vi } from "vitest";

type WireObject = Record<string, unknown>;
type TestEnv = Env & { TEST_MIGRATIONS: D1Migration[] };

let signingKey: CryptoKey;
let publicJWK: JWK;

function asObject(value: unknown): WireObject {
  expect(value).toBeTypeOf("object");
  expect(value).not.toBeNull();
  expect(Array.isArray(value)).toBe(false);
  return value as WireObject;
}

function nested(value: WireObject, key: string): WireObject {
  return asObject(value[key]);
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

async function api(
  path: string,
  options: { token?: string; method?: string; body?: WireObject } = {},
): Promise<Response> {
  const headers = new Headers();
  if (options.token) headers.set("Authorization", `Bearer ${options.token}`);
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

beforeAll(async () => {
  await applyD1Migrations(env.CONTROL_DB, (env as TestEnv).TEST_MIGRATIONS);
  const keys = await generateKeyPair("RS256", { extractable: true });
  signingKey = keys.privateKey;
  publicJWK = await exportJWK(keys.publicKey);
  publicJWK.kid = "pass-test-key";
  publicJWK.alg = "RS256";

  vi.stubGlobal("fetch", async (input: RequestInfo | URL) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (url === "https://identity.pass.test/.well-known/jwks.json") {
      return Response.json({ keys: [publicJWK] });
    }
    throw new Error(`Unexpected external request: ${url}`);
  });
});

describe("public account and device control plane", () => {
  it("requires a valid OIDC user token", async () => {
    const missing = await api("/v2/me");
    expect(missing.status).toBe(401);

    const malformed = await api("/v2/me", { token: "not-a-jwt" });
    expect(malformed.status).toBe(401);
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

  it("rate limits repeated pairing attempts by credential fingerprint", async () => {
    for (let attempt = 0; attempt < 20; attempt += 1) {
      const response = await api("/v2/pairings", {
        token: "rate-limit-test-credential",
        body: {},
      });
      expect(response.status).toBe(401);
    }

    const limited = await api("/v2/pairings", {
      token: "rate-limit-test-credential",
      body: {},
    });
    expect(limited.status).toBe(429);
    expect(limited.headers.get("Retry-After")).toBe("60");
  });

  it("deletes an account and immediately rejects its desktop credential", async () => {
    const token = await userToken("delete-user");
    const registered = await api("/v2/desktops", {
      token,
      body: { name: "Disposable Mac" },
    });
    expect(registered.status).toBe(201);
    const credentials = nested(asObject(await registered.json()), "credentials");

    const deleted = await api("/v2/account", { token, method: "DELETE" });
    expect(deleted.status).toBe(200);

    const rejected = await SELF.fetch("https://relay.test/connect", {
      headers: {
        Authorization: `Bearer ${String(credentials.accessToken)}`,
        Upgrade: "websocket",
        "X-Pass-Protocol-Version": "1",
      },
    });
    expect(rejected.status).toBe(401);
  });
});
