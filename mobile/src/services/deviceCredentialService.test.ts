import assert from "node:assert/strict";
import test from "node:test";

import type { PairedDesktop } from "../protocol/types.ts";
import {
  refreshDeviceCredential,
  revokeDevice,
  shouldRefreshDeviceCredential,
} from "./deviceCredentialService.ts";

const pairing: PairedDesktop = {
  protocolVersion: 1,
  relayUrl: "https://relay.example.com",
  desktopId: "desk_123",
  desktopName: "Studio Mac",
  deviceId: "device_123",
  credential: "old-access",
  authenticationMode: "device",
  credentialExpiresAt: "2026-07-18T12:15:00.000Z",
  refreshCredential: "old-refresh",
  refreshExpiresAt: "2026-08-17T12:00:00.000Z",
  scopes: ["sessions:read"],
  pairedAt: "2026-07-18T12:00:00.000Z",
};

test("refreshes a device credential and rotates both tokens", async () => {
  let requestedURL = "";
  let authorization = "";
  const fetchImpl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    requestedURL = String(input);
    authorization = new Headers(init?.headers).get("Authorization") ?? "";
    return Response.json({
      credentials: {
        accessToken: "new-access",
        accessExpiresAt: "2026-07-18T12:30:00.000Z",
        refreshToken: "new-refresh",
        refreshExpiresAt: "2026-08-17T12:15:00.000Z",
      },
    });
  }) as typeof fetch;

  const refreshed = await refreshDeviceCredential(pairing, fetchImpl);

  assert.equal(requestedURL, "https://relay.example.com/v2/token/refresh");
  assert.equal(authorization, "Bearer old-refresh");
  assert.equal(refreshed.credential, "new-access");
  assert.equal(refreshed.refreshCredential, "new-refresh");
});

test("refresh margin applies only to device credentials", () => {
  const now = new Date("2026-07-18T12:14:01.000Z").getTime();
  assert.equal(shouldRefreshDeviceCredential(pairing, now), true);
  assert.equal(
    shouldRefreshDeviceCredential({ ...pairing, authenticationMode: "development" }, now),
    false,
  );
});

test("revokes the server-side device using the user access token", async () => {
  let requestedURL = "";
  let authorization = "";
  const fetchImpl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    requestedURL = String(input);
    authorization = new Headers(init?.headers).get("Authorization") ?? "";
    assert.equal(init?.method, "DELETE");
    return Response.json({ revoked: true });
  }) as typeof fetch;

  await revokeDevice(pairing, "oidc-access", fetchImpl);

  assert.equal(requestedURL, "https://relay.example.com/v2/devices/device_123");
  assert.equal(authorization, "Bearer oidc-access");
});
