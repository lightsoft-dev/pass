import assert from "node:assert/strict";
import test from "node:test";

import { createCommand } from "../protocol/commands.ts";
import type { RemoteSession, ServerEvent } from "../protocol/types.ts";
import { initialRemoteState, remoteReducer } from "./reducer.ts";
import { selectSortedSessions } from "./selectors.ts";

function makeSession(
  name: string,
  status: RemoteSession["attention"]["status"],
): RemoteSession {
  return {
    name,
    displayName: name,
    defaultDisplayName: name,
    agent: "claude",
    projectRoot: `/work/${name}`,
    cwd: `/work/${name}`,
    gitBranch: "main",
    attention: { status, preview: status === "decision" ? "Allow?" : undefined },
    lastActivity: status === "decision" ? "2026-07-16T09:00:00Z" : "2026-07-16T10:00:00Z",
    isAttached: false,
    unacknowledged: status === "decision",
    launching: false,
  };
}

test("a snapshot hydrates state and sorts attention first", () => {
  const event: ServerEvent<"session.snapshot"> = {
    version: 1,
    id: "evt_snapshot",
    type: "session.snapshot",
    sentAt: "2026-07-16T10:00:01Z",
    payload: {
      generatedAt: "2026-07-16T10:00:00Z",
      sessions: [makeSession("working", "working"), makeSession("needs-you", "decision")],
      projects: [{ rootPath: "/work/one", name: "one" }],
      capabilities: ["sessions:read", "sessions:write"],
    },
  };
  const state = remoteReducer(initialRemoteState, { type: "EVENT_RECEIVED", event });

  assert.equal(state.connection.phase, "online");
  assert.equal(state.lastSyncedAt, "2026-07-16T10:00:00Z");
  assert.deepEqual(selectSortedSessions(state).map((item) => item.name), [
    "needs-you",
    "working",
  ]);

  const afterRepeatedPresence = remoteReducer(state, {
    type: "EVENT_RECEIVED",
    event: {
      version: 1,
      id: "evt_presence",
      type: "desktop.presence",
      sentAt: "2026-07-16T10:00:02Z",
      payload: { desktopOnline: true, mobileCount: 2 },
    },
  });
  assert.equal(afterRepeatedPresence.connection.phase, "online");
});

test("stores optional snapshot truncation totals", () => {
  const state = remoteReducer(initialRemoteState, {
    type: "EVENT_RECEIVED",
    event: {
      version: 1,
      id: "evt_truncated",
      type: "session.snapshot",
      sentAt: "2026-07-16T10:00:01Z",
      payload: {
        generatedAt: "2026-07-16T10:00:00Z",
        sessions: [makeSession("kept", "decision")],
        projects: [],
        capabilities: ["sessions:read"],
        truncated: true,
        totalSessionCount: 140,
        totalProjectCount: 12,
      },
    },
  });

  assert.deepEqual(state.snapshotTruncation, {
    shownSessionCount: 1,
    totalSessionCount: 140,
    shownProjectCount: 0,
    totalProjectCount: 12,
  });
});

test("hydrates an in-progress message stream from a snapshot", () => {
  const streamingSession: RemoteSession = {
    ...makeSession("streaming", "working"),
    liveMessage: "Compiling",
    liveMessageTruncated: true,
  };
  const state = remoteReducer(initialRemoteState, {
    type: "EVENT_RECEIVED",
    event: {
      version: 1,
      id: "evt_snapshot_stream",
      type: "session.snapshot",
      sentAt: "2026-07-16T10:00:01Z",
      payload: {
        generatedAt: "2026-07-16T10:00:00Z",
        sessions: [streamingSession],
        projects: [],
        capabilities: ["sessions:read", "sessions:stream"],
      },
    },
  });

  assert.deepEqual(state.messageStreamsBySession.streaming, {
    messageID: "snapshot:evt_snapshot_stream:streaming",
    sequence: 0,
    text: "Compiling",
    truncated: true,
    phase: "streaming",
    updatedAt: "2026-07-16T10:00:00Z",
  });
});

test("applies ordered message stream updates and ignores stale frames", () => {
  const snapshot: ServerEvent<"session.snapshot"> = {
    version: 1,
    id: "evt_snapshot",
    type: "session.snapshot",
    sentAt: "2026-07-16T10:00:00Z",
    payload: {
      generatedAt: "2026-07-16T10:00:00Z",
      sessions: [makeSession("pass-app", "working")],
      projects: [],
      capabilities: ["sessions:read", "sessions:stream"],
    },
  };
  let state = remoteReducer(initialRemoteState, {
    type: "EVENT_RECEIVED",
    event: snapshot,
  });

  const streamEvent = (
    type: "session.message.started" | "session.message.updated" | "session.message.completed",
    sequence: number,
    text: string,
  ): ServerEvent => ({
    version: 1,
    id: `evt_stream_${sequence}`,
    type,
    sentAt: `2026-07-16T10:00:0${sequence + 1}Z`,
    payload: {
      session: "pass-app",
      messageID: "msg_1",
      sequence,
      text,
      truncated: false,
    },
  } as ServerEvent);

  state = remoteReducer(state, {
    type: "EVENT_RECEIVED",
    event: streamEvent("session.message.started", 0, "Running"),
  });
  state = remoteReducer(state, {
    type: "EVENT_RECEIVED",
    event: streamEvent("session.message.updated", 2, "Running all tests"),
  });
  state = remoteReducer(state, {
    type: "EVENT_RECEIVED",
    event: streamEvent("session.message.updated", 1, "Running tests"),
  });

  assert.equal(state.messageStreamsBySession["pass-app"]?.sequence, 2);
  assert.equal(state.messageStreamsBySession["pass-app"]?.text, "Running all tests");
  assert.equal(state.sessionsByName["pass-app"]?.liveMessage, "Running all tests");

  state = remoteReducer(state, {
    type: "EVENT_RECEIVED",
    event: streamEvent("session.message.completed", 3, "All tests passed"),
  });
  assert.equal(state.messageStreamsBySession["pass-app"]?.phase, "completed");
  assert.equal(state.sessionsByName["pass-app"]?.liveMessage, null);
  assert.equal(state.sessionsByName["pass-app"]?.lastMessage, "All tests passed");
});

test("replyTo advances a sent message through ack and delivery", () => {
  const command = createCommand(
    "session.sendMessage",
    { session: "pass-app", text: "Run tests" },
    { id: "cmd_send", now: () => new Date("2026-07-16T10:00:00Z") },
  );
  let state = remoteReducer(initialRemoteState, { type: "COMMAND_SENT", command });
  state = remoteReducer(state, {
    type: "EVENT_RECEIVED",
    event: {
      version: 1,
      id: "evt_ack",
      replyTo: "cmd_send",
      type: "ack",
      sentAt: "2026-07-16T10:00:01Z",
      payload: { commandType: "session.sendMessage", resourceID: "pass-app" },
    },
  });
  assert.equal(state.pendingCommands.cmd_send?.status, "accepted");

  state = remoteReducer(state, {
    type: "EVENT_RECEIVED",
    event: {
      version: 1,
      id: "evt_delivered",
      replyTo: "cmd_send",
      type: "message.delivered",
      sentAt: "2026-07-16T10:00:02Z",
      payload: { session: "pass-app" },
    },
  });
  assert.equal(state.pendingCommands.cmd_send?.status, "delivered");
  assert.equal(state.activities[0]?.status, "delivered");
});

test("ack completes commands that have no later delivery event", () => {
  const command = createCommand(
    "session.create",
    { projectRoot: "/work/app", agent: "codex" },
    { id: "cmd_create", now: () => new Date("2026-07-16T10:00:00Z") },
  );
  let state = remoteReducer(initialRemoteState, { type: "COMMAND_SENT", command });
  state = remoteReducer(state, {
    type: "EVENT_RECEIVED",
    event: {
      version: 1,
      id: "evt_create_ack",
      replyTo: "cmd_create",
      type: "ack",
      sentAt: "2026-07-16T10:00:01Z",
      payload: { commandType: "session.create", resourceID: "pass-app" },
    },
  });

  assert.equal(state.pendingCommands.cmd_create?.status, "completed");
  assert.equal(state.activities.length, 0, "only user messages create timeline activities");
});
