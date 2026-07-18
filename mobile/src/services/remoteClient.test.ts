import assert from "node:assert/strict";
import test from "node:test";

import {
  COMMAND_LIMITS,
  CommandValidationError,
} from "../protocol/commands.ts";
import type { PairedDesktop } from "../protocol/types.ts";
import {
  RemoteClient,
  RemoteClientError,
  controlSocketUrl,
  type SocketFactory,
} from "./remoteClient.ts";

const pairing: PairedDesktop = {
  protocolVersion: 1,
  relayUrl: "https://relay.example.com",
  desktopId: "desk_123",
  desktopName: "Studio Mac",
  deviceId: "mobile_123",
  credential: "secret-token",
  scopes: ["sessions:read", "sessions:write"],
  pairedAt: "2026-07-16T10:00:00Z",
};

function event(type: string, payload: Record<string, unknown>) {
  return JSON.stringify({
    version: 1,
    id: `evt_${type}`,
    type,
    sentAt: "2026-07-16T10:00:00Z",
    payload,
  });
}

test("normalizes both relay base and existing connect URLs", () => {
  assert.equal(controlSocketUrl(pairing), "wss://relay.example.com/connect");
  assert.equal(
    controlSocketUrl({ ...pairing, relayUrl: "https://relay.example.com/connect/" }),
    "wss://relay.example.com/connect",
  );
});

test("uses header auth and keeps an offline desktop socket open", async () => {
  const sent: string[] = [];
  const statuses: string[] = [];
  const captures: { url?: string; headers?: Record<string, string> } = {};
  let closeCount = 0;
  const socket = {
    readyState: 1,
    onopen: null as (() => void) | null,
    onmessage: null as ((event: { data: unknown }) => void) | null,
    onerror: null as (() => void) | null,
    onclose: null as ((event: { code: number; reason?: string }) => void) | null,
    send: (raw: string) => sent.push(raw),
    close: () => {
      closeCount += 1;
    },
  };
  const socketFactory: SocketFactory = (url, _protocols, options) => {
    captures.url = url;
    captures.headers = options.headers;
    return socket;
  };
  let uuidSequence = 0;
  const client = new RemoteClient({
    pairing,
    socketFactory,
    uuidFactory: () => `00000000-0000-4000-8000-${String(++uuidSequence).padStart(12, "0")}`,
    openTimeoutMs: 15,
    onEvent: () => undefined,
    onStatus: ({ phase }) => statuses.push(phase),
  });

  client.connect();
  socket.onopen?.();
  socket.onmessage?.({
    data: event("relay.ready", {
      desktopId: "desk_123",
      role: "mobile",
      deviceId: "mobile_123",
      connectionId: "connection_1",
      latestSequence: 0,
      connectedAt: "2026-07-16T10:00:00Z",
    }),
  });
  socket.onmessage?.({
    data: event("desktop.presence", { desktopOnline: false, mobileCount: 1 }),
  });
  await new Promise((resolve) => setTimeout(resolve, 30));

  assert.equal(closeCount, 0, "presence(false) must cancel the open timeout");
  assert.equal(statuses.at(-1), "desktop-offline");
  assert.equal(captures.url, "wss://relay.example.com/connect");
  assert.deepEqual(captures.headers, {
    Authorization: "Bearer secret-token",
    "X-Pass-Protocol-Version": "1",
    "X-Pass-Desktop-ID": "desk_123",
    "X-Pass-Role": "mobile",
    "X-Pass-Device-ID": "mobile_123",
  });

  socket.onmessage?.({
    data: event("desktop.presence", { desktopOnline: true, mobileCount: 1 }),
  });
  const sentTypes = sent.map((raw) => (JSON.parse(raw) as { type: string }).type);
  assert.ok(sentTypes.includes("relay.resume"));
  assert.ok(sentTypes.includes("session.list"));
  assert.ok(sentTypes.includes("project.list"));
  assert.equal(statuses.at(-1), "authenticating");

  socket.onmessage?.({
    data: event("session.snapshot", {
      generatedAt: "2026-07-16T10:00:01Z",
      sessions: [],
      projects: [],
      capabilities: ["sessions:read"],
    }),
  });
  assert.equal(statuses.at(-1), "online");
  socket.onmessage?.({
    data: event("desktop.presence", { desktopOnline: true, mobileCount: 2 }),
  });
  assert.equal(
    statuses.at(-1),
    "online",
    "a second mobile joining must not regress an online client to authenticating",
  );
  client.stop(false);
});

test("ignores queued callbacks from a socket replaced by reconnect", () => {
  type TestSocket = {
    readyState: number;
    onopen: (() => void) | null;
    onmessage: ((event: { data: unknown }) => void) | null;
    onerror: (() => void) | null;
    onclose: ((event: { code: number; reason?: string }) => void) | null;
    send: (raw: string) => void;
    close: () => void;
  };
  const sockets: TestSocket[] = [];
  const socketFactory: SocketFactory = () => {
    const socket: TestSocket = {
      readyState: 1,
      onopen: null,
      onmessage: null,
      onerror: null,
      onclose: null,
      send: () => undefined,
      close: () => undefined,
    };
    sockets.push(socket);
    return socket;
  };
  const statuses: string[] = [];
  let eventCount = 0;
  let uuidSequence = 0;
  const client = new RemoteClient({
    pairing,
    socketFactory,
    uuidFactory: () => `10000000-0000-4000-8000-${String(++uuidSequence).padStart(12, "0")}`,
    onEvent: () => {
      eventCount += 1;
    },
    onStatus: ({ phase }) => statuses.push(phase),
  });

  client.connect();
  const first = sockets[0];
  assert.ok(first);
  first.onopen?.();
  const staleOpen = first.onopen;
  const staleMessage = first.onmessage;
  const staleError = first.onerror;
  const staleClose = first.onclose;

  client.reconnect();
  assert.equal(first.onopen, null);
  assert.equal(first.onmessage, null);
  assert.equal(first.onerror, null);
  assert.equal(first.onclose, null);
  assert.equal(sockets.length, 2);
  const statusCount = statuses.length;

  staleOpen?.();
  staleMessage?.({
    data: event("desktop.presence", { desktopOnline: false, mobileCount: 1 }),
  });
  staleError?.();
  staleClose?.({ code: 1006, reason: "stale close" });

  assert.equal(eventCount, 0);
  assert.equal(statuses.length, statusCount);
  client.stop(false);
});

test("rejects oversized command input locally before connection checks", () => {
  const client = new RemoteClient({
    pairing,
    uuidFactory: () => "20000000-0000-4000-8000-000000000001",
    onEvent: () => undefined,
    onStatus: () => undefined,
  });

  assert.throws(
    () =>
      client.send("session.sendMessage", {
        session: "pass-app",
        text: "x".repeat(COMMAND_LIMITS.messageCharacters + 1),
      }),
    (error: unknown) => {
      assert.ok(error instanceof CommandValidationError);
      assert.equal(error.code, "message_too_large");
      return true;
    },
  );
});

test("does not write an outbound frame that fails the UTF-8 preflight", () => {
  let sendCount = 0;
  const socket = {
    readyState: 1,
    onopen: null as (() => void) | null,
    onmessage: null as ((event: { data: unknown }) => void) | null,
    onerror: null as (() => void) | null,
    onclose: null as ((event: { code: number; reason?: string }) => void) | null,
    send: () => {
      sendCount += 1;
    },
    close: () => undefined,
  };
  let uuidSequence = 0;
  const client = new RemoteClient({
    pairing,
    socketFactory: () => socket,
    uuidFactory: () =>
      `30000000-0000-4000-8000-${String(++uuidSequence).padStart(12, "0")}`,
    maximumOutboundFrameBytes: 1,
    onEvent: () => undefined,
    onStatus: () => undefined,
  });

  client.connect();
  socket.onopen?.();
  socket.onmessage?.({
    data: event("relay.ready", {
      desktopId: "desk_123",
      role: "mobile",
      deviceId: "mobile_123",
      connectionId: "connection_1",
      latestSequence: 0,
      connectedAt: "2026-07-16T10:00:00Z",
    }),
  });
  socket.onmessage?.({
    data: event("desktop.presence", { desktopOnline: true, mobileCount: 1 }),
  });

  assert.throws(
    () => client.send("session.list", {}),
    (error: unknown) => {
      assert.ok(error instanceof RemoteClientError);
      assert.equal(error.code, "send_failed");
      assert.match(error.message, /UTF-8 bytes/);
      return true;
    },
  );
  assert.equal(sendCount, 0);
  client.stop(false);
});

test("drains truncated resume pages only while the cursor advances", () => {
  const sent: Array<{ id: string; type: string; payload: { afterSequence?: number } }> = [];
  const socket = {
    readyState: 1,
    onopen: null as (() => void) | null,
    onmessage: null as ((event: { data: unknown }) => void) | null,
    onerror: null as (() => void) | null,
    onclose: null as ((event: { code: number; reason?: string }) => void) | null,
    send: (raw: string) => {
      sent.push(JSON.parse(raw) as (typeof sent)[number]);
    },
    close: () => undefined,
  };
  let uuidSequence = 0;
  const client = new RemoteClient({
    pairing,
    socketFactory: () => socket,
    uuidFactory: () =>
      `40000000-0000-4000-8000-${String(++uuidSequence).padStart(12, "0")}`,
    onEvent: () => undefined,
    onStatus: () => undefined,
  });

  client.connect();
  socket.onopen?.();
  socket.onmessage?.({
    data: event("relay.ready", {
      desktopId: "desk_123",
      role: "mobile",
      deviceId: "mobile_123",
      connectionId: "connection_1",
      latestSequence: 205,
      connectedAt: "2026-07-16T10:00:00Z",
    }),
  });

  const first = sent.find((command) => command.type === "relay.resume");
  assert.ok(first);
  assert.equal(first.payload.afterSequence, 0);
  socket.onmessage?.({
    data: event("relay.resume.result", {
      requestId: first.id,
      commands: [],
      truncated: true,
      latestSequence: 100,
    }),
  });

  const resumeCommands = sent.filter((command) => command.type === "relay.resume");
  assert.equal(resumeCommands.length, 2);
  assert.equal(resumeCommands[1]?.payload.afterSequence, 100);
  socket.onmessage?.({
    data: event("relay.resume.result", {
      requestId: resumeCommands[1]?.id,
      commands: [],
      truncated: true,
      latestSequence: 100,
    }),
  });
  assert.equal(
    sent.filter((command) => command.type === "relay.resume").length,
    2,
    "a non-advancing truncated page must not create a resume loop",
  );
  client.stop(false);
});
