import { SELF, env, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";

import {
  COMMAND_RETENTION_MS,
  PROTOCOL_VERSION,
  TERMINAL_COMMAND_RETENTION_MS,
  commandRetentionMs,
  parseIsoTimestamp,
} from "../src/protocol";

const TEST_TOKEN = "test-only-pass-relay-token";

type WireObject = Record<string, unknown>;

function isWireObject(value: unknown): value is WireObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function payloadOf(message: WireObject): WireObject {
  if (!isWireObject(message.payload)) {
    throw new Error(`Expected object payload: ${JSON.stringify(message)}`);
  }
  return message.payload;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

class TestSocket {
  readonly socket: WebSocket;
  private readonly inbox: WireObject[] = [];

  constructor(socket: WebSocket) {
    this.socket = socket;
    socket.addEventListener("message", (event) => {
      if (typeof event.data !== "string") return;
      const decoded: unknown = JSON.parse(event.data);
      if (isWireObject(decoded)) this.inbox.push(decoded);
    });
    socket.accept();
  }

  send(message: WireObject): void {
    this.socket.send(JSON.stringify(message));
  }

  async next(type: string, timeoutMilliseconds = 2_000): Promise<WireObject> {
    const deadline = Date.now() + timeoutMilliseconds;
    while (Date.now() < deadline) {
      const index = this.inbox.findIndex((message) => message.type === type);
      if (index >= 0) {
        const message = this.inbox[index];
        this.inbox.splice(index, 1);
        if (message !== undefined) return message;
      }
      await delay(5);
    }
    throw new Error(
      `Timed out waiting for ${type}; inbox=${JSON.stringify(this.inbox)}`,
    );
  }

  async expectNo(type: string, waitMilliseconds = 75): Promise<void> {
    await delay(waitMilliseconds);
    expect(this.inbox.some((message) => message.type === type)).toBe(false);
  }

  close(): void {
    if (this.socket.readyState === 1) this.socket.close(1000, "Test complete.");
  }
}

const openSockets: TestSocket[] = [];

afterEach(async () => {
  for (const socket of openSockets.splice(0)) socket.close();
  await delay(25);
});

type ConnectOptions = {
  desktopId: string;
  role: "desktop" | "mobile";
  deviceId?: string;
  token?: string;
};

async function connect(options: ConnectOptions): Promise<TestSocket> {
  const headers = new Headers({
    Authorization: `Bearer ${options.token ?? TEST_TOKEN}`,
    Upgrade: "websocket",
    "X-Pass-Protocol-Version": String(PROTOCOL_VERSION),
    "X-Pass-Desktop-ID": options.desktopId,
    "X-Pass-Role": options.role,
  });
  if (options.deviceId !== undefined) {
    headers.set("X-Pass-Device-ID", options.deviceId);
  }
  const response = await SELF.fetch("https://relay.test/connect", { headers });
  expect(response.status).toBe(101);
  if (response.webSocket === null) {
    throw new Error("Expected WebSocket upgrade response.");
  }
  const client = new TestSocket(response.webSocket);
  openSockets.push(client);
  return client;
}

function command(
  id: string,
  type: string,
  payload: WireObject,
): WireObject {
  return {
    version: PROTOCOL_VERSION,
    id,
    type,
    sentAt: "2026-07-16T00:00:00Z",
    payload,
  };
}

function desktopEvent(
  id: string,
  type: string,
  payload: WireObject,
  replyTo?: string,
): WireObject {
  return {
    version: PROTOCOL_VERSION,
    id,
    type,
    sentAt: "2026-07-16T00:00:01Z",
    ...(replyTo === undefined ? {} : { replyTo }),
    payload,
  };
}

describe("Pass mobile relay", () => {
  it("keeps high-frequency terminal command metadata for a shorter window", () => {
    expect(commandRetentionMs("session.sendMessage")).toBe(COMMAND_RETENTION_MS);
    expect(commandRetentionMs("session.terminal.input")).toBe(
      TERMINAL_COMMAND_RETENTION_MS,
    );
  });

  it("accepts only calendar-valid RFC 3339 timestamps", () => {
    for (const timestamp of [
      "2026-07-16T00:00:00Z",
      "2026-07-16T00:00:00.123456Z",
      "2026-07-16T09:00:00+09:00",
      "2024-02-29T23:59:59.1-08:30",
    ]) {
      expect(parseIsoTimestamp(timestamp), timestamp).toBe(true);
    }

    for (const timestamp of [
      "2026-07-16",
      "2026-07-16 00:00:00Z",
      "2026-07-16t00:00:00z",
      "2026-07-16T09:00:00+0900",
      "2025-02-29T00:00:00Z",
      "2026-07-16T24:00:00Z",
      "2026-07-16T23:59:60Z",
    ]) {
      expect(parseIsoTimestamp(timestamp), timestamp).toBe(false);
    }
  });

  it("exposes health and requires a header bearer token", async () => {
    const health = await SELF.fetch("https://relay.test/health");
    expect(health.status).toBe(200);
    await expect(health.json()).resolves.toMatchObject({
      ok: true,
      protocolVersion: PROTOCOL_VERSION,
    });

    const unauthenticated = await SELF.fetch(
      "https://relay.test/connect?token=test-only-pass-relay-token",
      {
        headers: {
          Upgrade: "websocket",
          "X-Pass-Protocol-Version": "1",
          "X-Pass-Desktop-ID": "desk-auth",
          "X-Pass-Role": "desktop",
        },
      },
    );
    expect(unauthenticated.status).toBe(401);

    const wrongToken = await SELF.fetch("https://relay.test/connect", {
      headers: {
        Authorization: "Bearer wrong-token",
        Upgrade: "websocket",
        "X-Pass-Protocol-Version": "1",
        "X-Pass-Desktop-ID": "desk-auth",
        "X-Pass-Role": "desktop",
      },
    });
    expect(wrongToken.status).toBe(401);
  });

  it("validates the versioned header handshake", async () => {
    const badVersion = await SELF.fetch("https://relay.test/connect", {
      headers: {
        Authorization: `Bearer ${TEST_TOKEN}`,
        Upgrade: "websocket",
        "X-Pass-Protocol-Version": "2",
        "X-Pass-Desktop-ID": "desk-version",
        "X-Pass-Role": "desktop",
      },
    });
    expect(badVersion.status).toBe(400);

    const missingMobileDevice = await SELF.fetch("https://relay.test/connect", {
      headers: {
        Authorization: `Bearer ${TEST_TOKEN}`,
        Upgrade: "websocket",
        "X-Pass-Protocol-Version": "1",
        "X-Pass-Desktop-ID": "desk-version",
        "X-Pass-Role": "mobile",
      },
    });
    expect(missingMobileDevice.status).toBe(400);
  });

  it("rejects offline mutation without persisting or queueing it", async () => {
    const mobile = await connect({
      desktopId: "desk-offline",
      role: "mobile",
      deviceId: "phone-offline",
    });

    const ready = await mobile.next("relay.ready");
    expect(payloadOf(ready)).toMatchObject({
      desktopId: "desk-offline",
      deviceId: "phone-offline",
      latestSequence: 0,
    });
    const presence = await mobile.next("desktop.presence");
    expect(payloadOf(presence)).toMatchObject({ desktopOnline: false });

    mobile.send(
      command("cmd-offline", "session.sendMessage", {
        session: "pass-app",
        text: "Run tests",
      }),
    );
    const error = await mobile.next("error");
    expect(error.replyTo).toBe("cmd-offline");
    expect(payloadOf(error)).toEqual({
      code: "desktop.offline",
      message: "Desktop is offline; mutating commands are never queued.",
      retryable: true,
    });

    mobile.send(
      command("resume-offline", "relay.resume", { afterSequence: 0 }),
    );
    const resumed = await mobile.next("relay.resume.result");
    expect(payloadOf(resumed)).toMatchObject({
      requestId: "resume-offline",
      commands: [],
      latestSequence: 0,
    });
  });

  it("forwards the original command and routes exact Swift events by replyTo", async () => {
    const desktop = await connect({ desktopId: "desk-route", role: "desktop" });
    const mobile = await connect({
      desktopId: "desk-route",
      role: "mobile",
      deviceId: "phone-route",
    });
    const observer = await connect({
      desktopId: "desk-route",
      role: "mobile",
      deviceId: "phone-observer",
    });

    await mobile.next("relay.ready");
    const presence = await mobile.next("desktop.presence");
    expect(payloadOf(presence)).toMatchObject({ desktopOnline: true });
    await observer.next("relay.ready");

    const original = command("cmd-list", "session.list", {});
    mobile.send(original);

    await expect(desktop.next("session.list")).resolves.toEqual(original);
    const receipt = await mobile.next("relay.receipt");
    expect(payloadOf(receipt)).toMatchObject({
      commandId: "cmd-list",
      status: "forwarded",
      replay: false,
    });
    const sequence = payloadOf(receipt).sequence;
    expect(typeof sequence).toBe("number");

    const acknowledgement = desktopEvent(
      "evt-ack",
      "ack",
      { commandType: "session.list" },
      "cmd-list",
    );
    desktop.send(acknowledgement);
    await expect(mobile.next("ack")).resolves.toEqual(acknowledgement);
    await observer.expectNo("ack");

    const snapshot = desktopEvent(
      "evt-snapshot",
      "session.snapshot",
      { generatedAt: "2026-07-16T00:00:01Z", sessions: [], projects: [] },
      "cmd-list",
    );
    desktop.send(snapshot);
    await expect(mobile.next("session.snapshot")).resolves.toEqual(snapshot);
    await observer.expectNo("session.snapshot");

    mobile.send(
      command("resume-route", "relay.resume", { afterSequence: 0 }),
    );
    const resumeResult = await mobile.next("relay.resume.result");
    expect(payloadOf(resumeResult)).toMatchObject({
      requestId: "resume-route",
      commands: [
        {
          commandId: "cmd-list",
          commandType: "session.list",
          status: "completed",
        },
      ],
    });

    mobile.send(original);
    const replayReceipt = await mobile.next("relay.receipt");
    expect(payloadOf(replayReceipt)).toMatchObject({
      commandId: "cmd-list",
      sequence,
      status: "completed",
      replay: true,
    });
    await desktop.expectNo("session.list");
    await desktop.expectNo("desktop.presence");
  });

  it("broadcasts unsolicited snapshots and message streams within one desktop room", async () => {
    const desktopA = await connect({ desktopId: "desk-a", role: "desktop" });
    const mobileA = await connect({
      desktopId: "desk-a",
      role: "mobile",
      deviceId: "phone-a",
    });
    const mobileAObserver = await connect({
      desktopId: "desk-a",
      role: "mobile",
      deviceId: "phone-a-observer",
    });
    const mobileB = await connect({
      desktopId: "desk-b",
      role: "mobile",
      deviceId: "phone-b",
    });
    await mobileA.next("relay.ready");
    await mobileAObserver.next("relay.ready");
    await mobileB.next("relay.ready");

    const snapshot = desktopEvent("evt-push", "session.snapshot", {
      generatedAt: "2026-07-16T00:00:01Z",
      sessions: [],
      projects: [],
    });
    desktopA.send(snapshot);

    await expect(mobileA.next("session.snapshot")).resolves.toEqual(snapshot);
    await mobileB.expectNo("session.snapshot");

    const stream = desktopEvent("evt-stream", "session.message.updated", {
      session: "pass-app",
      messageID: "msg-turn",
      sequence: 3,
      text: "Running the relay tests",
      truncated: false,
    });
    desktopA.send(stream);

    await expect(mobileA.next("session.message.updated")).resolves.toEqual(stream);
    await mobileB.expectNo("session.message.updated");

    mobileA.send(command("cmd-terminal-open", "session.terminal.open", {
      session: "pass-app",
      subscriptionId: "term_123",
    }));
    await desktopA.next("session.terminal.open");
    await mobileA.next("relay.receipt");

    const terminal = desktopEvent("evt-terminal", "session.terminal.snapshot", {
      session: "pass-app",
      subscriptionId: "term_123",
      revision: "rev_1",
      content: "\u001b[32mready\u001b[0m",
      columns: 120,
      rows: 36,
      cursorX: 5,
      cursorY: 2,
      truncated: false,
    });
    desktopA.send(terminal);

    await expect(mobileA.next("session.terminal.snapshot")).resolves.toEqual(terminal);
    await mobileAObserver.expectNo("session.terminal.snapshot");
    await mobileB.expectNo("session.terminal.snapshot");
  });

  it("forwards terminal input and routes its acknowledgement to the origin device", async () => {
    const desktop = await connect({ desktopId: "desk-terminal", role: "desktop" });
    const mobile = await connect({
      desktopId: "desk-terminal",
      role: "mobile",
      deviceId: "phone-terminal",
    });
    await mobile.next("relay.ready");

    const input = command("cmd-terminal-input", "session.terminal.input", {
      session: "pass-app",
      subscriptionId: "term_123",
      input: "\u001b[A",
    });
    mobile.send(input);
    await expect(desktop.next("session.terminal.input")).resolves.toEqual(input);
    await mobile.next("relay.receipt");

    const acknowledgement = desktopEvent(
      "evt-terminal-ack",
      "ack",
      { commandType: "session.terminal.input", resourceID: "term_123" },
      "cmd-terminal-input",
    );
    desktop.send(acknowledgement);
    await expect(mobile.next("ack")).resolves.toEqual(acknowledgement);

    mobile.send(input);
    const replay = await mobile.next("relay.receipt");
    expect(payloadOf(replay)).toMatchObject({ replay: true, status: "accepted" });
    await desktop.expectNo("session.terminal.input");
  });

  it("routes future correlated desktop events without exposing unsolicited ones", async () => {
    const desktop = await connect({
      desktopId: "desk-future-event",
      role: "desktop",
    });
    const origin = await connect({
      desktopId: "desk-future-event",
      role: "mobile",
      deviceId: "phone-future-origin",
    });
    const observer = await connect({
      desktopId: "desk-future-event",
      role: "mobile",
      deviceId: "phone-future-observer",
    });
    await origin.next("relay.ready");
    await observer.next("relay.ready");

    origin.send(command("cmd-future", "session.list", {}));
    await desktop.next("session.list");
    await origin.next("relay.receipt");

    const correlated = desktopEvent(
      "evt-future-correlated",
      "voice.state",
      { phase: "listening" },
      "cmd-future",
    );
    desktop.send(correlated);
    await expect(origin.next("voice.state")).resolves.toEqual(correlated);
    await observer.expectNo("voice.state");

    desktop.send(
      desktopEvent("evt-future-private", "voice.secret", {
        secret: "do-not-broadcast",
      }),
    );
    await Promise.all([
      origin.expectNo("voice.secret"),
      observer.expectNo("voice.secret"),
    ]);

    const snapshot = desktopEvent("evt-after-future", "session.snapshot", {
      generatedAt: "2026-07-16T00:00:01Z",
      sessions: [],
      projects: [],
    });
    desktop.send(snapshot);
    await expect(origin.next("session.snapshot")).resolves.toEqual(snapshot);
    await expect(observer.next("session.snapshot")).resolves.toEqual(snapshot);
  });

  it("uses the last returned sequence as the cursor across resume pages", async () => {
    const mobile = await connect({
      desktopId: "desk-resume-pages",
      role: "mobile",
      deviceId: "phone-resume-pages",
    });
    await mobile.next("relay.ready");

    const room = env.DESKTOP_ROOMS.getByName("desk-resume-pages");
    await runInDurableObject(room, (_instance, state) => {
      const receivedAt = Date.now();
      for (let index = 1; index <= 205; index += 1) {
        state.storage.sql.exec(
          `INSERT INTO commands (
            command_id,
            origin_device_id,
            origin_connection_id,
            command_type,
            mutating,
            status,
            received_at,
            expires_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
          `cmd-page-${index}`,
          "phone-resume-pages",
          "seed-connection",
          "session.list",
          0,
          "forwarded",
          receivedAt,
          receivedAt + 600_000,
        );
      }
    });

    const requestPage = async (
      requestId: string,
      afterSequence: number,
    ): Promise<WireObject> => {
      mobile.send(command(requestId, "relay.resume", { afterSequence }));
      return payloadOf(await mobile.next("relay.resume.result"));
    };

    const first = await requestPage("resume-page-1", 0);
    expect(first).toMatchObject({
      requestId: "resume-page-1",
      truncated: true,
      latestSequence: 100,
    });
    expect(first.commands).toHaveLength(100);
    expect(first.commands).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ commandId: "cmd-page-1", sequence: 1 }),
        expect.objectContaining({ commandId: "cmd-page-100", sequence: 100 }),
      ]),
    );

    const second = await requestPage("resume-page-2", 100);
    expect(second).toMatchObject({
      requestId: "resume-page-2",
      truncated: true,
      latestSequence: 200,
    });
    expect(second.commands).toHaveLength(100);

    const third = await requestPage("resume-page-3", 200);
    expect(third).toMatchObject({
      requestId: "resume-page-3",
      truncated: false,
      latestSequence: 205,
    });
    expect(third.commands).toHaveLength(5);
    expect(third.commands).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ commandId: "cmd-page-201", sequence: 201 }),
        expect.objectContaining({ commandId: "cmd-page-205", sequence: 205 }),
      ]),
    );
  });

  it("allows the desktop's 64 Ki-character Unicode payload boundary", async () => {
    const desktop = await connect({
      desktopId: "desk-boundary",
      role: "desktop",
    });
    const mobile = await connect({
      desktopId: "desk-boundary",
      role: "mobile",
      deviceId: "phone-boundary",
    });
    await mobile.next("relay.ready");

    const boundary = command("cmd-boundary", "session.sendMessage", {
      session: "pass-app",
      text: "🙂".repeat(64 * 1_024),
    });
    mobile.send(boundary);

    await expect(desktop.next("session.sendMessage")).resolves.toEqual(boundary);
    const receipt = await mobile.next("relay.receipt");
    expect(payloadOf(receipt)).toMatchObject({
      commandId: "cmd-boundary",
      status: "forwarded",
    });
  });
});
