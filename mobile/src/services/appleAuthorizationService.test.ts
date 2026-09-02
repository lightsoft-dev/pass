import assert from "node:assert/strict";
import test from "node:test";

import {
  appleAuthorizationFromCredential,
  registerAppleAuthorization,
  requireSecureAppleRelayURL,
} from "./appleAuthorizationService.ts";
import { APPLE_ISSUER, APPLE_NATIVE_CLIENT_ID } from "./identitySession.ts";

function unsignedAppleToken(user: string, expiresAt: number): string {
  const payload = Buffer.from(JSON.stringify({
    iss: APPLE_ISSUER,
    aud: APPLE_NATIVE_CLIENT_ID,
    sub: user,
    exp: expiresAt,
  })).toString("base64url");
  return `eyJhbGciOiJub25lIn0.${payload}.signature`;
}

function authorization(now = Date.parse("2026-08-11T00:00:00.000Z")) {
  return appleAuthorizationFromCredential(
    {
      user: "apple-user-123",
      identityToken: unsignedAppleToken("apple-user-123", Math.floor(now / 1_000) + 300),
      authorizationCode: "one-time-code",
    },
    "request-nonce",
    { now },
  );
}

test("keeps the Apple authorization code and nonce outside the persistable session", () => {
  const value = authorization();

  assert.equal(value.authorizationCode, "one-time-code");
  assert.equal(value.nonce, "request-nonce");
  assert.equal(value.session.identityProvider, "apple");
  assert.equal(value.session.providerUserId, "apple-user-123");
  assert.equal("authorizationCode" in value.session, false);
  assert.equal("nonce" in value.session, false);
  assert.doesNotMatch(JSON.stringify(value.session), /one-time-code|request-nonce/);
});

test("requires a one-time code, request nonce, and the expected Apple user", () => {
  const now = Date.parse("2026-08-11T00:00:00.000Z");
  const credential = {
    user: "apple-user-123",
    identityToken: unsignedAppleToken("apple-user-123", Math.floor(now / 1_000) + 300),
    authorizationCode: "one-time-code",
  };

  assert.throws(
    () => appleAuthorizationFromCredential({ ...credential, authorizationCode: null }, "nonce", { now }),
    /one-time authorization code/,
  );
  assert.throws(
    () => appleAuthorizationFromCredential(credential, "", { now }),
    /secure Sign in with Apple/,
  );
  assert.throws(
    () => appleAuthorizationFromCredential(credential, "nonce", {
      expectedUserId: "another-apple-user",
      now,
    }),
    /different account/,
  );
});

test("registers the exact one-time code and nonce using the Apple identity token", async () => {
  let requestedURL = "";
  let requestedInit: RequestInit | undefined;
  const fetchImpl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    requestedURL = String(input);
    requestedInit = init;
    return Response.json({
      authorized: true,
      account: { id: "account-1", email: "user@example.com" },
    });
  }) as typeof fetch;
  const value = authorization();

  await registerAppleAuthorization("https://relay.example.com/", value, fetchImpl);

  assert.equal(requestedURL, "https://relay.example.com/v2/apple/authorization");
  assert.equal(requestedInit?.method, "POST");
  assert.equal(requestedInit?.redirect, "error");
  assert.equal(
    new Headers(requestedInit?.headers).get("Authorization"),
    `Bearer ${value.session.accessToken}`,
  );
  assert.equal(
    new Headers(requestedInit?.headers).get("Content-Type"),
    "application/json",
  );
  assert.deepEqual(JSON.parse(String(requestedInit?.body)), {
    authorizationCode: "one-time-code",
    nonce: "request-nonce",
  });
});

test("accepts any successful 2xx response without retaining the authorization code", async () => {
  const fetchImpl = (async () => new Response(null, { status: 204 })) as typeof fetch;
  await assert.doesNotReject(
    registerAppleAuthorization("https://relay.example.com", authorization(), fetchImpl),
  );
});

test("surfaces a Relay error and never retries a consumed authorization code", async () => {
  let calls = 0;
  const fetchImpl = (async () => {
    calls += 1;
    return Response.json(
      { error: { code: "invalid_apple_code", message: "Sign in with Apple again." } },
      { status: 401 },
    );
  }) as typeof fetch;

  await assert.rejects(
    registerAppleAuthorization("https://relay.example.com", authorization(), fetchImpl),
    /Sign in with Apple again\./,
  );
  assert.equal(calls, 1);
});

test("requires a configured HTTPS Relay and gives a reauthentication-safe network error", async () => {
  assert.throws(() => requireSecureAppleRelayURL(undefined), /no production Pass Relay/);
  assert.throws(() => requireSecureAppleRelayURL("http://relay.example.com"), /secure HTTPS/);
  assert.equal(
    requireSecureAppleRelayURL(" https://relay.example.com/// "),
    "https://relay.example.com",
  );

  const fetchImpl = (async () => {
    throw new TypeError("network details");
  }) as typeof fetch;
  await assert.rejects(
    registerAppleAuthorization("https://relay.example.com", authorization(), fetchImpl),
    /try Sign in with Apple again/,
  );
});
