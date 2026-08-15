import assert from "node:assert/strict";
import test from "node:test";

import {
  normalizeRelayBaseURL,
  pinStoredPairingForProduction,
  requireConfiguredRelayURL,
  requirePinnedRelayURL,
  resolveAccountRelayURL,
} from "./relayURL.ts";
import type { PairedDesktop } from "../protocol/types.ts";

test("rejects an arbitrary HTTPS origin when production pairing is pinned", () => {
  assert.throws(
    () => requirePinnedRelayURL(
      "https://attacker.example.com",
      "https://relay.example.com",
    ),
    /untrusted Pass Relay/,
  );
});

test("accepts only the exact normalized configured Relay base URL", () => {
  assert.equal(
    requirePinnedRelayURL(
      "https://RELAY.example.com/control///?ignored=1#fragment",
      "https://relay.example.com/control/",
    ),
    "https://relay.example.com/control",
  );
  assert.throws(
    () => requirePinnedRelayURL(
      "https://relay.example.com/another-base",
      "https://relay.example.com/control",
    ),
    /untrusted Pass Relay/,
  );
});

test("fails closed without a valid configured production Relay", () => {
  assert.throws(
    () => requireConfiguredRelayURL(undefined),
    /production build has no valid HTTPS Pass Relay/,
  );
  assert.throws(
    () => requireConfiguredRelayURL("http://relay.example.com"),
    /production build has no valid HTTPS Pass Relay/,
  );
});

test("preserves explicit local HTTP Relay normalization in development", () => {
  assert.equal(
    normalizeRelayBaseURL("http://127.0.0.1:8787///", {
      allowInsecureDevelopment: true,
    }),
    "http://127.0.0.1:8787",
  );
});

test("account operations resolve exclusively from the configured Relay", () => {
  const pairedDesktopRelay = "https://attacker.example.com";
  const resolved = resolveAccountRelayURL("https://relay.example.com/");

  assert.equal(resolved, "https://relay.example.com");
  assert.notEqual(resolved, pairedDesktopRelay);
});

test("rejects an untrusted legacy stored pairing before production reuse", () => {
  const stored: PairedDesktop = {
    protocolVersion: 1,
    relayUrl: "https://attacker.example.com",
    desktopId: "desk_legacy",
    desktopName: "Legacy Mac",
    deviceId: "device_legacy",
    credential: "device-access",
    authenticationMode: "device",
    credentialExpiresAt: "2026-08-12T12:00:00.000Z",
    refreshCredential: "device-refresh",
    refreshExpiresAt: "2026-09-12T12:00:00.000Z",
    scopes: ["sessions:read"],
    pairedAt: "2026-08-12T00:00:00.000Z",
  };

  assert.throws(
    () => pinStoredPairingForProduction(stored, "https://relay.example.com"),
    /untrusted Pass Relay/,
  );
  assert.equal(
    pinStoredPairingForProduction(
      { ...stored, relayUrl: "https://RELAY.example.com///" },
      "https://relay.example.com",
    ).relayUrl,
    "https://relay.example.com",
  );
});
