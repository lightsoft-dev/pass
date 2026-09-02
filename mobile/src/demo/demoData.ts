export type DemoSection = "inbox" | "chat" | "decision" | "terminal" | "security";

export type DemoSession = {
  id: string;
  title: string;
  project: string;
  branch: string;
  agent: "Codex" | "Claude";
  status: "Needs decision" | "Working" | "Finished";
  preview: string;
  section: Extract<DemoSection, "chat" | "decision">;
};

export const DEMO_SECTIONS: readonly { id: DemoSection; label: string; glyph: string }[] = [
  { id: "inbox", label: "Inbox", glyph: "▤" },
  { id: "chat", label: "Chat", glyph: "✦" },
  { id: "decision", label: "Decision", glyph: "!" },
  { id: "terminal", label: "Terminal", glyph: ">_" },
  { id: "security", label: "Security", glyph: "◇" },
] as const;

export const DEMO_SESSIONS: readonly DemoSession[] = [
  {
    id: "review-api",
    title: "Review API migration",
    project: "Pass Relay",
    branch: "codex/safer-pairing",
    agent: "Codex",
    status: "Needs decision",
    preview: "Allow the migration check to run against the local test database?",
    section: "decision",
  },
  {
    id: "mobile-release",
    title: "Prepare mobile release",
    project: "Pass Remote",
    branch: "dev",
    agent: "Claude",
    status: "Working",
    preview: "The store checklist is ready. I am validating the final build configuration.",
    section: "chat",
  },
  {
    id: "docs-refresh",
    title: "Refresh onboarding docs",
    project: "Pass Docs",
    branch: "docs/quickstart",
    agent: "Codex",
    status: "Finished",
    preview: "Updated the pairing guide and verified every link.",
    section: "chat",
  },
] as const;

export const DEMO_TERMINAL_LINES: readonly string[] = [
  "$ npm run check",
  "",
  "> pass-relay@0.1.1 check",
  "> npm run typecheck && npm test",
  "",
  "✓ protocol validation (18 tests)",
  "✓ relay lifecycle (12 tests)",
  "✓ mobile state reducer (15 tests)",
  "",
  "Test Suites: 3 passed, 3 total",
  "Time: 4.21s",
  "$ _",
] as const;

export function isDemoSection(value: string): value is DemoSection {
  return DEMO_SECTIONS.some((section) => section.id === value);
}
