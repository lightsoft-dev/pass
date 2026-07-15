/**
 * Pulls meaning out of an agent's captured pane: the last prose message, a "what's it doing now"
 * one-liner, and any numbered decision menu (permission prompt / AskUserQuestion).
 *
 * Direct port of Sources/Pass/Core/PaneSummary.swift and DecisionParser.swift.
 */

// ── PaneSummary ────────────────────────────────────────────────────────────

/** A `⏺` line that's a tool call, e.g. "Bash(ls)", "Read(x.txt)" (glyph already stripped). */
function isToolCall(s: string): boolean {
  const paren = s.indexOf("(");
  if (paren <= 0) return false;
  const name = s.slice(0, paren);
  if (!/^[A-Z]/.test(name)) return false;
  return /^[A-Za-z0-9_]+$/.test(name);
}

/** TUI decoration that isn't the agent's actual output. */
function isChrome(t: string): boolean {
  if (t.length > 0 && Array.from(t).every((c) => c === "─" || c === "╌" || c === "-" || c === "═")) return true;
  if (t.startsWith("❯")) return true;
  if (t.includes(" | ") && (t.includes("Context") || t.includes("used"))) return true;
  if (t.startsWith("←") || t.startsWith("↑")) return true;
  if (t.startsWith("/") && t.length <= 8) return true;
  if (t.includes("for agents") || t.includes("to edit in")) return true;
  return false;
}

/** Strip leading assistant/spinner glyphs so text reads cleanly in a small row. */
function collapse(t: string): string {
  let s = t;
  for (const glyph of ["⏺ ", "✻ ", "✶ ", "✽ ", "· ", "⎿ ", "  ⎿ "]) {
    if (s.startsWith(glyph)) {
      s = s.slice(glyph.length);
      break;
    }
  }
  return s.replace(/\t/g, " ").trim();
}

const lines = (pane: string): string[] => pane.split("\n");

/** The last meaningful content line, skipping the input box, rules, and status chrome. */
export function lastContentLine(pane: string): string | undefined {
  for (const raw of lines(pane).reverse()) {
    const t = raw.trim();
    if (t === "") continue;
    if (isChrome(t)) continue;
    return collapse(t);
  }
  return undefined;
}

/** The last up-to-`max` meaningful lines, in on-screen (top→bottom) order. */
export function lastContentLines(pane: string, max = 2): string | undefined {
  const picked: string[] = [];
  for (const raw of lines(pane).reverse()) {
    const t = raw.trim();
    if (t === "") continue;
    if (isChrome(t)) continue;
    picked.push(collapse(t));
    if (picked.length >= max) break;
  }
  return picked.length === 0 ? undefined : picked.reverse().join("\n");
}

/**
 * The agent's last prose message on screen — the text of the last `⏺` block that isn't a tool
 * call. Falls back to undefined so the caller can drop to lastContentLines.
 */
export function lastAgentMessage(pane: string): string | undefined {
  const ls = lines(pane);
  let start: number | undefined;
  for (let i = ls.length - 1; i >= 0; i--) {
    const t = ls[i].trim();
    if (!t.startsWith("⏺")) continue;
    const content = collapse(t);
    if (content === "" || isToolCall(content)) continue;
    start = i;
    break;
  }
  if (start === undefined) return undefined;

  const out = [collapse(ls[start].trim())];
  let j = start + 1;
  while (j < ls.length && out.length < 12) {
    const raw = ls[j];
    const t = raw.trim();
    if (t === "" || t.startsWith("⏺") || t.startsWith("⎿") || isChrome(t)) break;
    if (!raw.startsWith("  ")) break; // continuation lines are indented
    out.push(collapse(t));
    j += 1;
  }
  return out.join(" ").trim();
}

/** Best available one-liner/paragraph describing a session's latest output. */
export function bestSummary(pane: string): string | undefined {
  return lastAgentMessage(pane) ?? lastContentLines(pane, 2) ?? lastContentLine(pane);
}

// ── DecisionParser ─────────────────────────────────────────────────────────

export interface DecisionOption {
  number: number;
  label: string;
  highlighted: boolean;
}

/** The option number if `rawLine` is a "N. label" choice (marker/whitespace tolerant), else undefined. */
function optionNumber(rawLine: string): number | undefined {
  const cleaned = rawLine.replace(/❯/g, " ").trim();
  const dot = cleaned.indexOf(".");
  if (dot <= 0) return undefined;
  const num = Number(cleaned.slice(0, dot));
  if (!Number.isInteger(num) || num < 1 || num > 20) return undefined;
  const label = cleaned.slice(dot + 1).trim();
  return label === "" ? undefined : num;
}

function optionLabel(rawLine: string): string {
  const cleaned = rawLine.replace(/❯/g, " ").trim();
  const dot = cleaned.indexOf(".");
  if (dot < 0) return "";
  return cleaned.slice(dot + 1).trim();
}

function isBoxBorder(t: string): boolean {
  return t.length > 0 && Array.from(t).every((c) => "─╌-═╭╮╰╯│┌┐└┘├┤┬┴┼ ".includes(c));
}

function cleanPrompt(t: string): string {
  let s = t;
  for (const glyph of ["⏺ ", "✻ ", "> "]) {
    if (s.startsWith(glyph)) {
      s = s.slice(glyph.length);
      break;
    }
  }
  return s.replace(/^[│ ]+|[│ ]+$/g, "");
}

/**
 * Pull a numbered choice list out of capture-pane text. Requires a consecutive 1..N run of ≥2 —
 * that's what distinguishes a real menu from a stray "1. foo" inside prose.
 */
export function parseDecision(pane: string): DecisionOption[] {
  const found: DecisionOption[] = [];
  for (const rawLine of pane.split("\n")) {
    const num = optionNumber(rawLine);
    if (num === undefined) continue;
    found.push({ number: num, label: optionLabel(rawLine), highlighted: rawLine.includes("❯") });
  }

  const seen = new Set<number>();
  const unique = found.filter((o) => (seen.has(o.number) ? false : (seen.add(o.number), true)));
  unique.sort((a, b) => a.number - b.number);
  if (unique.length < 2) return [];
  for (let i = 0; i < unique.length; i++) if (unique[i].number !== i + 1) return [];
  return unique;
}

/** The question/context shown above a numbered menu. undefined when there's no valid menu. */
export function decisionPrompt(pane: string): string | undefined {
  const ls = pane.split("\n");
  if (parseDecision(pane).length === 0) return undefined;
  let oneIdx = -1;
  for (let i = ls.length - 1; i >= 0; i--) {
    if (optionNumber(ls[i]) === 1) {
      oneIdx = i;
      break;
    }
  }
  if (oneIdx < 0) return undefined;

  const collected: string[] = [];
  let i = oneIdx - 1;
  while (i >= 0 && collected.length < 6) {
    const raw = ls[i];
    const t = raw.trim();
    if (optionNumber(raw) !== undefined) {
      i -= 1;
      continue;
    }
    if (t === "") break;
    if (isBoxBorder(t)) {
      i -= 1;
      continue;
    }
    const cleaned = cleanPrompt(t);
    if (cleaned !== "") collected.push(cleaned);
    i -= 1;
  }
  const text = collected.reverse().join("\n").trim();
  return text === "" ? undefined : text;
}

/** Claude prints "(esc to interrupt)" while a turn is streaming. */
export function isWorking(pane: string): boolean {
  return /esc to interrupt/i.test(pane);
}
