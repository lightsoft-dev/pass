import assert from "node:assert/strict";
import test from "node:test";

import type { RemoteSession } from "../protocol/types.ts";
import { initialRemoteState, type RemoteState } from "./reducer.ts";
import { selectProjectSessionGroups } from "./selectors.ts";

function session(
  name: string,
  projectRoot: string,
  status: RemoteSession["attention"]["status"] = "idle",
  lastActivity = "2026-10-23T01:00:00Z",
): RemoteSession {
  return {
    name,
    displayName: name,
    defaultDisplayName: name,
    projectRoot,
    cwd: projectRoot,
    agent: "codex",
    attention: { status },
    lastActivity,
    isAttached: false,
    unacknowledged: false,
    launching: false,
  };
}

test("groups interleaved workers by project and keeps attention first", () => {
  const waiting = session("a-waiting", "/repos/a", "decision");
  const aRecent = session("a-recent", "/repos/a", "working", "2026-10-23T03:00:00Z");
  const b = session("b-worker", "/repos/b", "idle", "2026-10-23T02:00:00Z");
  const state: RemoteState = {
    ...initialRemoteState,
    sessionsByName: { [b.name]: b, [aRecent.name]: aRecent, [waiting.name]: waiting },
    projectsByRoot: {
      "/repos/a": { rootPath: "/repos/a", name: "Alpha", emoji: "🚀" },
      "/repos/empty": { rootPath: "/repos/empty", name: "Empty" },
    },
  };

  const groups = selectProjectSessionGroups(state);
  assert.deepEqual(groups.map((group) => group.rootPath), ["/repos/a", "/repos/b", "/repos/empty"]);
  assert.deepEqual(groups[0]!.sessions.map((worker) => worker.name), ["a-waiting", "a-recent"]);
  assert.equal(groups[0]!.name, "Alpha");
  assert.equal(groups[0]!.emoji, "🚀");
  assert.equal(groups[0]!.attentionCount, 1);
  assert.equal(groups[1]!.name, "b");
  assert.equal(groups[1]!.registered, false);
  assert.deepEqual(groups[2]!.sessions, []);
  assert.equal(groups[2]!.registered, true);
});

test("excludes Pa manager sessions and counts unacknowledged worker output", () => {
  const manager = session("pass-manager-1234", "/repos/a");
  const namedLikeManager = { ...session("pass-manager-custom", "/repos/a"), isProjectAgent: false };
  const worker = { ...session("worker", "/repos/a"), unacknowledged: true };
  const state: RemoteState = {
    ...initialRemoteState,
    sessionsByName: { [manager.name]: manager, [namedLikeManager.name]: namedLikeManager, [worker.name]: worker },
    projectsByRoot: { "/repos/a": { rootPath: "/repos/a", name: "Alpha" } },
  };

  const groups = selectProjectSessionGroups(state);
  assert.deepEqual(groups[0]!.sessions.map((item) => item.name), ["worker", "pass-manager-custom"]);
  assert.equal(groups[0]!.attentionCount, 1);
});
