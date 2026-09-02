import assert from "node:assert/strict";
import test from "node:test";

import { DEMO_SECTIONS, DEMO_SESSIONS, isDemoSection } from "./demoData.ts";

test("store review demo exposes every documented section", () => {
  assert.deepEqual(
    DEMO_SECTIONS.map((section) => section.id),
    ["inbox", "chat", "decision", "terminal", "security"],
  );
});

test("demo sessions are unique and route only to local detail sections", () => {
  assert.equal(new Set(DEMO_SESSIONS.map((session) => session.id)).size, DEMO_SESSIONS.length);
  assert.ok(DEMO_SESSIONS.every((session) => isDemoSection(session.section)));
});

test("unknown route values cannot enter the demo", () => {
  assert.equal(isDemoSection("settings"), false);
  assert.equal(isDemoSection(""), false);
});
