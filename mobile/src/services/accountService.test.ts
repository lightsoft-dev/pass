import assert from "node:assert/strict";
import test from "node:test";

import {
  AccountDeletionError,
  deleteAccount,
} from "./accountService.ts";

test("deletes the authenticated account from the configured relay", async () => {
  let requestedURL = "";
  let authorization = "";
  let fallbackHeader: string | null = "unexpected";
  const fetchImpl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    requestedURL = String(input);
    authorization = new Headers(init?.headers).get("Authorization") ?? "";
    fallbackHeader = new Headers(init?.headers).get(
      "X-Pass-Apple-Revocation-Fallback",
    );
    assert.equal(init?.method, "DELETE");
    assert.equal(init?.redirect, "error");
    return Response.json({ deleted: true });
  }) as typeof fetch;

  const result = await deleteAccount(
    "https://relay.example.com/",
    "google-id-token",
    { fetchImpl },
  );

  assert.equal(requestedURL, "https://relay.example.com/v2/account");
  assert.equal(authorization, "Bearer google-id-token");
  assert.equal(fallbackHeader, null);
  assert.deepEqual(result, { deleted: true });
});

test("preserves the structured manual Apple revocation fallback flag", async () => {
  const fetchImpl = (async () =>
    Response.json(
      {
        error: {
          code: "apple_reauthorization_required",
          message: "Sign in with Apple again.",
          manualRevocationAvailable: true,
        },
      },
      { status: 409 },
    )) as typeof fetch;

  try {
    await deleteAccount("https://relay.example.com", "expired-token", { fetchImpl });
    assert.fail("Expected account deletion to fail.");
  } catch (error) {
    assert.ok(error instanceof AccountDeletionError);
    assert.equal(error.code, "apple_reauthorization_required");
    assert.equal(error.status, 409);
    assert.equal(error.manualRevocationAvailable, true);
    assert.match(error.message, /Sign in with Apple again/);
  }
});

test("rejects an invalid successful response", async () => {
  const fetchImpl = (async () => Response.json({ ok: true })) as typeof fetch;

  await assert.rejects(
    deleteAccount("https://relay.example.com", "google-id-token", { fetchImpl }),
    /invalid response/,
  );
});

test("sends the exact manual Apple fallback header and preserves the success result", async () => {
  let fallbackHeader: string | null = null;
  const fetchImpl = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    fallbackHeader = new Headers(init?.headers).get(
      "X-Pass-Apple-Revocation-Fallback",
    );
    return Response.json({ deleted: true, appleRevocation: "manual_required" });
  }) as typeof fetch;

  const result = await deleteAccount(
    "https://relay.example.com",
    "fresh-apple-id-token",
    { appleRevocationFallback: "manual", fetchImpl },
  );

  assert.equal(fallbackHeader, "manual");
  assert.deepEqual(result, {
    deleted: true,
    appleRevocation: "manual_required",
  });
});
