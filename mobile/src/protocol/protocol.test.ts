import assert from "node:assert/strict";
import test from "node:test";

import {
  COMMAND_LIMITS,
  CommandValidationError,
  createCommand,
  encodeCommand,
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
    if (parsed.ok) {
      assert.equal(parsed.value.authorizationToken, "shared-dev-token");
      assert.equal(parsed.value.relayUrl, "https://relay.example.com");
    }
  }
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
