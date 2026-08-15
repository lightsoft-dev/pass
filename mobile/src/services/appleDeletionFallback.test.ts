import assert from "node:assert/strict";
import test from "node:test";

import { AccountDeletionError } from "./accountService.ts";
import {
  fallbackForAppleDeletionResponse,
  fallbackForApplePreparationFailure,
  isAppleRevocationFallbackRequiredError,
  manualDeletionSessionStrategy,
  persistFreshAppleSessionAfterRegistrationAttempt,
} from "./appleDeletionFallback.ts";

test("never offers manual deletion when the user cancels Apple reauthentication", () => {
  const fallback = fallbackForApplePreparationFailure({
    code: "ERR_REQUEST_CANCELED",
  });
  assert.equal(fallback, null);
});

test("offers typed fallback for Apple preparation failures", () => {
  const fallback = fallbackForApplePreparationFailure(
    new Error("Apple authorization registration failed."),
  );
  assert.ok(isAppleRevocationFallbackRequiredError(fallback));
  assert.match(fallback.originalMessage, /registration failed/);
});

test("offers typed fallback only when the Relay explicitly allows manual revocation", () => {
  const allowed = new AccountDeletionError("Manual revocation is available.", {
    code: "apple_reauthorization_required",
    status: 409,
    manualRevocationAvailable: true,
  });
  const denied = new AccountDeletionError("Deletion failed.", {
    code: "account_deletion_failed",
    status: 503,
    manualRevocationAvailable: false,
  });

  assert.ok(isAppleRevocationFallbackRequiredError(
    fallbackForAppleDeletionResponse(allowed),
  ));
  assert.equal(fallbackForAppleDeletionResponse(denied), null);
  assert.equal(fallbackForAppleDeletionResponse(new Error("network")), null);
});

test("manual deletion refreshes expired Google but never opens a new Apple modal", () => {
  const base = {
    clientId: "client-id",
    accessToken: "identity-token",
  };
  const now = Date.parse("2026-08-12T00:00:00.000Z");

  assert.equal(manualDeletionSessionStrategy({
    ...base,
    issuer: "https://accounts.google.com",
    accessExpiresAt: "2026-08-11T23:59:00.000Z",
  }, now), "refresh_google");
  assert.equal(manualDeletionSessionStrategy({
    ...base,
    issuer: "https://appleid.apple.com",
    identityProvider: "apple",
    providerUserId: "apple-user",
    accessExpiresAt: "2026-08-11T23:59:00.000Z",
  }, now), "reject_expired_apple");
  assert.equal(manualDeletionSessionStrategy({
    ...base,
    issuer: "https://appleid.apple.com",
    identityProvider: "apple",
    providerUserId: "apple-user",
    accessExpiresAt: "2026-08-12T00:05:00.000Z",
  }, now), "use_saved");
});

test("preserves only the fresh Apple session when registration fails", async () => {
  const session = {
    issuer: "https://appleid.apple.com",
    clientId: "dev.lightsoft.passmobile",
    accessToken: "fresh-identity-token",
    accessExpiresAt: "2026-08-12T00:05:00.000Z",
    identityProvider: "apple" as const,
    providerUserId: "apple-user",
  };
  let persisted: typeof session | null = null;

  const registrationError = await persistFreshAppleSessionAfterRegistrationAttempt(
    { session, authorizationCode: "one-time-code", nonce: "request-nonce" },
    async () => { throw new Error("Relay registration failed."); },
    async (value) => { persisted = value as typeof session; },
  );
  assert.match(
    registrationError instanceof Error ? registrationError.message : "",
    /registration failed/,
  );
  assert.deepEqual(persisted, session);
  assert.doesNotMatch(JSON.stringify(persisted), /one-time-code|request-nonce/);
});
