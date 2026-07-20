import assert from "node:assert/strict";
import test from "node:test";

import {
  buildConversation,
  parseTerminalConversation,
  stripTerminalControl,
} from "./terminalConversation.ts";

test("strips ANSI cursor, color, and OSC control sequences", () => {
  const input = "\u001b[31mred\u001b[0m\u001b]0;title\u0007 text\r\n";
  assert.equal(stripTerminalControl(input), "red text\n");
});

test("parses Claude user, prose, tool, and result blocks while dropping chrome", () => {
  const pane = `
╭────────────────────────────────────────╮
│ > Check the configuration              │
╰────────────────────────────────────────╯
⏺ I'll inspect the project first.

⏺ Read(config.swift)
  ⎿ Read 42 lines

⏺ The port is configured correctly and
  the service is ready.

branch main | ~/pass | Context: 40% used
❯
`;
  const blocks = parseTerminalConversation(pane, "claude");
  assert.deepEqual(
    blocks.map(({ kind, title, text }) => ({ kind, title, text })),
    [
      { kind: "user", title: undefined, text: "Check the configuration" },
      { kind: "assistant", title: undefined, text: "I'll inspect the project first." },
      { kind: "tool", title: "Read(config.swift)", text: "Read 42 lines" },
      { kind: "assistant", title: undefined, text: "The port is configured correctly and the service is ready." },
    ],
  );
});

test("parses Codex bullets and preserves tool output lines", () => {
  const pane = `
› Fix the failing test

• I’ll inspect the relevant files first.

• Explored
  └ Read package.json
    Search failing test

• The test now passes.
`;
  const blocks = parseTerminalConversation(pane, "codex");
  assert.deepEqual(
    blocks.map(({ kind, title, text }) => ({ kind, title, text })),
    [
      { kind: "user", title: undefined, text: "Fix the failing test" },
      { kind: "assistant", title: undefined, text: "I’ll inspect the relevant files first." },
      { kind: "tool", title: "Explored", text: "Read package.json\nSearch failing test" },
      { kind: "assistant", title: undefined, text: "The test now passes." },
    ],
  );
});

test("merges an authoritative live response and supplies a missing user turn", () => {
  const blocks = buildConversation({
    pane: "⏺ I am checking the build",
    agent: "claude",
    latestAssistant: "I am checking the build now.",
    latestAssistantStreaming: true,
    fallbackUser: "Run the tests",
  });
  assert.deepEqual(
    blocks.map(({ kind, text, streaming }) => ({ kind, text, streaming })),
    [
      { kind: "user", text: "Run the tests", streaming: undefined },
      { kind: "assistant", text: "I am checking the build now.", streaming: true },
    ],
  );
});

test("preserves markdown table rows in an assistant response", () => {
  const blocks = parseTerminalConversation(`
• Build result:
  | Target | Status |
  | --- | ---: |
  | iOS | Passed |
`, "codex");

  assert.equal(
    blocks[0]?.text,
    "Build result:\n| Target | Status |\n| --- | ---: |\n| iOS | Passed |",
  );
});
