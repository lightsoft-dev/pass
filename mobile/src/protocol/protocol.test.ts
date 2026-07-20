import assert from "node:assert/strict";
import test from "node:test";

import {
  COMMAND_LIMITS,
  CommandValidationError,
  createCommand,
  encodeCommand,
  splitUTF8ByBytes,
  utf8ByteLength,
  validateCommand,
  type CommandValidationCode,
} from "./commands.ts";
import { parseServerEvent } from "./guards.ts";
import { parsePairingPayload } from "./pairing.ts";

const session = {
  name: "pass-my-app",
  displayName: "my-app · main",
  defaultDisplayName: "my-app · main",
  agent: "codex",
  projectRoot: "/work/my-app",
  cwd: "/work/my-app",
  gitBranch: "main",
  attention: { status: "decision", receivedAt: "2026-07-16T10:00:00Z", preview: "Allow write?" },
  lastMessage: "Tests pass.",
  lastActivity: "2026-07-16T10:00:00Z",
  isAttached: false,
  unacknowledged: true,
  launching: false,
} as const;

function expectValidationCode(code: CommandValidationCode) {
  return (error: unknown): boolean => {
    assert.ok(error instanceof CommandValidationError);
    assert.equal(error.code, code);
    return true;
  };
}

test("creates the exact Swift v1 command envelope", () => {
  const command = createCommand(
    "session.answerDecision",
    { session: "pass-my-app", decision: "allowOnce" },
    { id: "cmd_test", now: () => new Date("2026-07-16T10:01:00Z") },
  );

  assert.deepEqual(command, {
    version: 1,
    id: "cmd_test",
    type: "session.answerDecision",
    sentAt: "2026-07-16T10:01:00.000Z",
    payload: { session: "pass-my-app", decision: "allowOnce" },
  });
});

test("uses an injected secure UUID factory for command ids", () => {
  const command = createCommand("session.list", {}, {
    uuidFactory: () => "018f6879-dde6-7682-9983-f0cd5d26591d",
  });
  assert.equal(command.id, "cmd_018f6879-dde6-7682-9983-f0cd5d26591d");
});

test("enforces the desktop command character limits at their boundaries", () => {
  assert.doesNotThrow(() =>
    validateCommand(
      createCommand(
        "session.create",
        {
          projectRoot: "p".repeat(COMMAND_LIMITS.projectPathCharacters),
          agent: "codex",
          initialPrompt: "i".repeat(COMMAND_LIMITS.initialPromptCharacters),
        },
        { id: "cmd_create_limit" },
      ),
    ),
  );
  assert.doesNotThrow(() =>
    validateCommand(
      createCommand(
        "session.sendMessage",
        {
          session: "s".repeat(COMMAND_LIMITS.sessionCharacters),
          text: "m".repeat(COMMAND_LIMITS.messageCharacters),
        },
        { id: "cmd_message_limit" },
      ),
    ),
  );

  assert.throws(
    () =>
      validateCommand(
        createCommand(
          "session.create",
          {
            projectRoot: "p".repeat(COMMAND_LIMITS.projectPathCharacters + 1),
            agent: "codex",
          },
          { id: "cmd_project_too_large" },
        ),
      ),
    expectValidationCode("invalid_project"),
  );
  assert.throws(
    () =>
      validateCommand(
        createCommand(
          "session.create",
          {
            projectRoot: "/work/app",
            agent: "codex",
            initialPrompt: "i".repeat(
              COMMAND_LIMITS.initialPromptCharacters + 1,
            ),
          },
          { id: "cmd_prompt_too_large" },
        ),
      ),
    expectValidationCode("initial_prompt_too_large"),
  );
  assert.throws(
    () =>
      validateCommand(
        createCommand(
          "session.sendMessage",
          {
            session: "s".repeat(COMMAND_LIMITS.sessionCharacters + 1),
            text: "hello",
          },
          { id: "cmd_session_too_large" },
        ),
      ),
    expectValidationCode("invalid_session"),
  );
  assert.throws(
    () =>
      validateCommand(
        createCommand(
          "session.sendMessage",
          {
            session: "pass-app",
            text: "m".repeat(COMMAND_LIMITS.messageCharacters + 1),
          },
          { id: "cmd_message_too_large" },
        ),
      ),
    expectValidationCode("message_too_large"),
  );
});

test("preflights the serialized frame by UTF-8 bytes", () => {
  const command = createCommand(
    "session.sendMessage",
    { session: "pass-app", text: "🙂" },
    { id: "cmd_utf8", now: () => new Date("2026-07-16T10:01:00Z") },
  );
  const serialized = JSON.stringify(command);
  const byteLength = utf8ByteLength(serialized);

  assert.ok(byteLength > serialized.length, "emoji must count as four UTF-8 bytes");
  assert.equal(encodeCommand(command, byteLength), serialized);
  assert.throws(
    () => encodeCommand(command, serialized.length),
    expectValidationCode("outbound_frame_too_large"),
  );
});

test("bounds terminal input by UTF-8 bytes and chunks large pastes", () => {
  const boundary = "🙂".repeat(COMMAND_LIMITS.terminalInputBytes / 4);
  assert.doesNotThrow(() =>
    validateCommand(
      createCommand(
        "session.terminal.input",
        { session: "pass-app", subscriptionId: "term_123", input: boundary },
        { id: "cmd_terminal_boundary" },
      ),
    ),
  );
  assert.throws(
    () =>
      validateCommand(
        createCommand(
          "session.terminal.input",
          {
            session: "pass-app",
            subscriptionId: "term_123",
            input: `${boundary}🙂`,
          },
          { id: "cmd_terminal_large" },
        ),
      ),
    expectValidationCode("terminal_input_too_large"),
  );

  const chunks = splitUTF8ByBytes(`abc${"🙂".repeat(3_000)}한글`, 4_096);
  assert.equal(chunks.join(""), `abc${"🙂".repeat(3_000)}한글`);
  assert.ok(chunks.length > 1);
  assert.ok(chunks.every((chunk) => utf8ByteLength(chunk) <= 4_096));
});

test("parses terminal snapshots with optional unchanged content", () => {
  const base = {
    version: 1,
    id: "evt_terminal",
    type: "session.terminal.snapshot",
    sentAt: "2026-07-16T10:01:01Z",
    payload: {
      session: "pass-app",
      subscriptionId: "term_123",
      revision: "abcd1234",
      columns: 160,
      rows: 42,
      cursorX: 4,
      cursorY: 12,
      truncated: false,
    },
  };
  assert.equal(parseServerEvent(base).ok, true);
  assert.equal(
    parseServerEvent({
      ...base,
      payload: { ...base.payload, content: "🙂".repeat(131_073) },
    }).ok,
    false,
  );
});

test("parses a correlated Swift v1 snapshot", () => {
  const parsed = parseServerEvent(
    JSON.stringify({
      version: 1,
      id: "evt_1",
      replyTo: "cmd_list",
      type: "session.snapshot",
      sentAt: "2026-07-16T10:01:00Z",
      payload: {
        generatedAt: "2026-07-16T10:01:00Z",
        sessions: [session],
        projects: [{ rootPath: "/work/my-app", name: "my-app", emoji: "🚀" }],
        capabilities: ["sessions:read", "sessions:write", "projects:read", "decisions:answer"],
        truncated: true,
        totalSessionCount: 42,
        totalProjectCount: 8,
      },
    }),
  );

  assert.equal(parsed.ok, true);
  if (parsed.ok) {
    assert.equal(parsed.event.replyTo, "cmd_list");
    assert.equal(parsed.event.type, "session.snapshot");
    if (parsed.event.type === "session.snapshot") {
      assert.equal(parsed.event.payload.totalSessionCount, 42);
    }
  }
});

test("parses bounded session message stream events", () => {
  const parsed = parseServerEvent({
    version: 1,
    id: "evt_stream",
    type: "session.message.updated",
    sentAt: "2026-07-16T10:01:01Z",
    payload: {
      session: "pass-my-app",
      messageID: "msg_1",
      sequence: 4,
      text: "Running tests",
      truncated: false,
    },
  });

  assert.equal(parsed.ok, true);
  if (parsed.ok && parsed.event.type === "session.message.updated") {
    assert.equal(parsed.event.payload.sequence, 4);
    assert.equal(parsed.event.payload.text, "Running tests");
  }

  const oversized = parseServerEvent({
    version: 1,
    id: "evt_stream_large",
    type: "session.message.updated",
    sentAt: "2026-07-16T10:01:02Z",
    payload: {
      session: "pass-my-app",
      messageID: "msg_1",
      sequence: 5,
      text: "🙂".repeat(16_385),
      truncated: true,
    },
  });
  assert.equal(oversized.ok, false);
  if (!oversized.ok) assert.equal(oversized.code, "invalid_payload");
});

test("rejects an oversized live message in a recovery snapshot", () => {
  const parsed = parseServerEvent({
    version: 1,
    id: "evt_snapshot_large_stream",
    type: "session.snapshot",
    sentAt: "2026-07-16T10:01:02Z",
    payload: {
      generatedAt: "2026-07-16T10:01:02Z",
      sessions: [{ ...session, liveMessage: "🙂".repeat(16_385) }],
      projects: [],
      capabilities: ["sessions:read", "sessions:stream"],
    },
  });

  assert.equal(parsed.ok, false);
  if (!parsed.ok) assert.equal(parsed.code, "invalid_payload");
});

test("rejects the pre-alignment v field", () => {
  const parsed = parseServerEvent({
    v: 1,
    id: "evt_1",
    type: "ack",
    sentAt: "2026-07-16T10:01:00Z",
    payload: { commandType: "session.list" },
  });

  assert.deepEqual(parsed.ok, false);
  if (!parsed.ok) assert.equal(parsed.code, "unsupported_version");
});

test("accepts authorizationToken and legacy pairingToken JSON fields", () => {
  for (const tokenField of ["authorizationToken", "pairingToken"] as const) {
    const parsed = parsePairingPayload(
      JSON.stringify({
        v: 1,
        relayUrl: "https://relay.example.com/",
        desktopId: "desk_123",
        [tokenField]: "shared-dev-token",
      }),
    );
    assert.equal(parsed.ok, true);
    if (parsed.ok && parsed.value.v === 1) {
      assert.equal(parsed.value.authorizationToken, "shared-dev-token");
      assert.equal(parsed.value.relayUrl, "https://relay.example.com");
    }
  }
});

test("accepts an unexpired one-time v2 pairing payload without a bearer token", () => {
  const parsed = parsePairingPayload(
    JSON.stringify({
      v: 2,
      relayUrl: "https://relay.example.com/",
      desktopId: "desk_123",
      pairingId: "pair_456",
      pairingSecret: "one-time-secret",
      expiresAt: "2026-07-18T12:05:00Z",
    }),
    { now: () => new Date("2026-07-18T12:00:00Z") },
  );

  assert.equal(parsed.ok, true);
  if (parsed.ok && parsed.value.v === 2) {
    assert.equal(parsed.value.pairingId, "pair_456");
    assert.equal(parsed.value.relayUrl, "https://relay.example.com");
    assert.equal(parsed.value.expiresAt, "2026-07-18T12:05:00.000Z");
    assert.equal("authorizationToken" in parsed.value, false);
  }
});

test("rejects an expired one-time v2 pairing payload", () => {
  const parsed = parsePairingPayload(
    JSON.stringify({
      v: 2,
      relayUrl: "https://relay.example.com",
      desktopId: "desk_123",
      pairingId: "pair_456",
      pairingSecret: "one-time-secret",
      expiresAt: "2026-07-18T11:59:59Z",
    }),
    { now: () => new Date("2026-07-18T12:00:00Z") },
  );

  assert.equal(parsed.ok, false);
  if (!parsed.ok) assert.match(parsed.error, /expired/i);
});

test("rejects insecure relay URLs outside explicit development mode", () => {
  const payload = JSON.stringify({
    v: 1,
    relayUrl: "http://127.0.0.1:8787",
    desktopId: "desk_local",
    authorizationToken: "token",
  });
  assert.equal(parsePairingPayload(payload).ok, false);
  assert.equal(
    parsePairingPayload(payload, { allowInsecureDevelopment: true }).ok,
    true,
  );
});
