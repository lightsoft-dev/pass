import assert from "node:assert/strict";
import test from "node:test";
import { parsePairingProfile, socketURL } from "./remoteClient.ts";

test("normalizes relay urls without placing credentials in the query", () => {
  assert.equal(socketURL("https://relay.example.com"), "wss://relay.example.com/connect");
  assert.equal(socketURL("wss://relay.example.com/connect/"), "wss://relay.example.com/connect");
});

test("accepts the development QR shape", () => {
  const profile = parsePairingProfile(JSON.stringify({ relayUrl: "https://relay.example.com", desktopId: "desk_1", desktopName: "Studio", authorizationToken: "secret" }));
  assert.equal(profile.desktopId, "desk_1");
  assert.equal(profile.credential, "secret");
  assert.match(profile.deviceId, /^deck_/);
});

test("rejects incomplete profiles", () => {
  assert.throws(() => parsePairingProfile('{"relayUrl":"https://relay.example.com"}'), /desktopId/);
});
