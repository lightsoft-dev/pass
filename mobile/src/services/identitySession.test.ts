import assert from "node:assert/strict";
import test from "node:test";

import {
  APPLE_ISSUER,
  APPLE_NATIVE_CLIENT_ID,
  GOOGLE_ISSUER,
  assertMatchingAppleState,
  identityProviderForSession,
  identityTokenExpiry,
  isAppleRequestCanceled,
  shouldShowAppleSignIn,
  userSessionFromAppleCredential,
} from "./identitySession.ts";

function unsignedToken(payload: Record<string, unknown>): string {
  const encoded = Buffer.from(JSON.stringify(payload)).toString("base64url");
  return `eyJhbGciOiJub25lIn0.${encoded}.signature`;
}

test("uses the unified native bundle identifier for Apple tokens", () => {
  assert.equal(APPLE_NATIVE_CLIENT_ID, "dev.lightsoft.passmobile");
});

test("creates an Apple user session only for the native app audience", () => {
  const now = Date.parse("2026-08-11T00:00:00.000Z");
  const expiresAt = Math.floor(now / 1_000) + 300;
  const identityToken = unsignedToken({
    iss: APPLE_ISSUER,
    aud: APPLE_NATIVE_CLIENT_ID,
    sub: "apple-user-123",
    exp: expiresAt,
  });

  const session = userSessionFromAppleCredential({
    user: "apple-user-123",
    identityToken,
  }, APPLE_NATIVE_CLIENT_ID, now);

  assert.deepEqual(session, {
    issuer: APPLE_ISSUER,
    clientId: APPLE_NATIVE_CLIENT_ID,
    accessToken: identityToken,
    accessExpiresAt: new Date(expiresAt * 1_000).toISOString(),
    identityProvider: "apple",
    providerUserId: "apple-user-123",
  });
});

test("rejects an Apple credential for a different app or user", () => {
  const now = Date.parse("2026-08-11T00:00:00.000Z");
  const common = {
    iss: APPLE_ISSUER,
    sub: "apple-user-123",
    exp: Math.floor(now / 1_000) + 300,
  };
  assert.throws(
    () => userSessionFromAppleCredential({
      user: "apple-user-123",
      identityToken: unsignedToken({ ...common, aud: "another.bundle" }),
    }, APPLE_NATIVE_CLIENT_ID, now),
    /different app/,
  );
  assert.throws(
    () => userSessionFromAppleCredential({
      user: "different-user",
      identityToken: unsignedToken({ ...common, aud: APPLE_NATIVE_CLIENT_ID }),
    }, APPLE_NATIVE_CLIENT_ID, now),
    /different user/,
  );
});

test("rejects an expired Apple identity token", () => {
  const now = Date.parse("2026-08-11T00:00:00.000Z");
  assert.throws(
    () => userSessionFromAppleCredential({
      user: "apple-user-123",
      identityToken: unsignedToken({
        iss: APPLE_ISSUER,
        aud: APPLE_NATIVE_CLIENT_ID,
        sub: "apple-user-123",
        exp: Math.floor(now / 1_000) - 1,
      }),
    }, APPLE_NATIVE_CLIENT_ID, now),
    /expired/,
  );
});

test("resolves legacy Google and Apple sessions from their issuer", () => {
  const base = {
    clientId: "client",
    accessToken: "token",
    accessExpiresAt: "2026-08-11T01:00:00.000Z",
  };
  assert.equal(identityProviderForSession({ ...base, issuer: GOOGLE_ISSUER }), "google");
  assert.equal(identityProviderForSession({ ...base, issuer: `${APPLE_ISSUER}/` }), "apple");
  assert.throws(
    () => identityProviderForSession({ ...base, issuer: "https://issuer.example" }),
    /no longer supported/,
  );
});

test("shows the Apple button only when available on iOS", () => {
  assert.equal(shouldShowAppleSignIn("ios", true), true);
  assert.equal(shouldShowAppleSignIn("ios", false), false);
  assert.equal(shouldShowAppleSignIn("android", true), false);
  assert.equal(shouldShowAppleSignIn("web", true), false);
});

test("validates Apple response state and cancellation errors", () => {
  assert.doesNotThrow(() => assertMatchingAppleState("state-1", "state-1"));
  assert.throws(() => assertMatchingAppleState("state-1", "state-2"), /did not match/);
  assert.equal(isAppleRequestCanceled({ code: "ERR_REQUEST_CANCELED" }), true);
  assert.equal(isAppleRequestCanceled(new Error("failed")), false);
});

test("uses a short fallback lifetime for an unparseable Google token", () => {
  const now = Date.parse("2026-08-11T00:00:00.000Z");
  assert.equal(
    identityTokenExpiry("not-a-jwt", now).toISOString(),
    "2026-08-11T00:05:00.000Z",
  );
});
