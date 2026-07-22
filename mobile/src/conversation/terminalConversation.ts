export type ConversationAgent = "claude" | "codex" | "pi" | "shell" | "generic";

export type ConversationBlockKind = "user" | "assistant" | "tool" | "output";

export interface ConversationBlock {
  id: string;
  kind: ConversationBlockKind;
  text: string;
  title?: string;
  streaming?: boolean;
}

type ConversationOptions = {
  pane?: string | null;
  agent: ConversationAgent;
  latestAssistant?: string | null;
  latestAssistantStreaming?: boolean;
  fallbackUser?: string | null;
};

const TOOL_LEAD = /^(?:Bash|Read|Write|Edit|Update|Search|Glob|Grep|Task|WebFetch|WebSearch|NotebookEdit|Skill|Tool|Ran|Explored|Edited|Searched|Called|Wrote|Updated|Added|Deleted|Viewed|Listed|Checked|Waiting)\b/i;
const DECORATION_ONLY = /^[\s─━│┃┌┐└┘╭╮╰╯═╪┬┴├┤┼…·╌╍]+$/u;

export function stripTerminalControl(value: string): string {
  return value
    .replace(/\u001B\][^\u0007\u001B]*(?:\u0007|\u001B\\)/g, "")
    .replace(/\u001B\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/\u001B[@-_]/g, "")
    .replace(/\r/g, "")
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001A\u001C-\u001F\u007F]/g, "");
}

function cleanLine(raw: string): string {
  return raw
    .replace(/[ \t]+$/g, "")
    .replace(/^\s*[│┃]\s?/, "")
    .replace(/\s?[│┃]\s*$/, "");
}

function isChrome(line: string): boolean {
  const value = line.trim();
  if (!value || DECORATION_ONLY.test(value) || /^[❯›>]\s*$/u.test(value)) return true;
  const lower = value.toLowerCase();
  if (
    lower.includes("shift+tab to cycle") ||
    lower.includes("bypass permissions") ||
    lower.includes("esc to interrupt") ||
    lower.includes("for shortcuts") ||
    lower.includes("to edit in") ||
    lower.includes("context left")
  ) return true;
  if (value.includes(" | ") && (lower.includes("context") || lower.includes("used"))) return true;
  return false;
}

function isToolTitle(value: string): boolean {
  return /^[A-Z][A-Za-z0-9_]*(?:\(|$)/.test(value) || TOOL_LEAD.test(value);
}

function joinContinuation(current: string, next: string, preserveLine: boolean): string {
  if (!current) return next;
  if (
    preserveLine ||
    /^(```|\| |[-*] |\d+[.)] |#{1,4} )/.test(next) ||
    /\|\s*$/.test(current) ||
    /```\s*$/.test(current)
  ) return `${current}\n${next}`;
  return `${current} ${next}`;
}

function blockID(block: Omit<ConversationBlock, "id">, index: number): string {
  const stableText = block.kind === "tool" ? "" : block.text.slice(0, 96);
  const input = `${block.kind}\u0000${block.title ?? ""}\u0000${stableText}`;
  let hash = 2_166_136_261;
  for (let i = 0; i < input.length; i += 1) {
    hash ^= input.charCodeAt(i);
    hash = Math.imul(hash, 16_777_619);
  }
  return `${block.kind}_${index}_${(hash >>> 0).toString(16)}`;
}

function withStableIDs(blocks: Array<Omit<ConversationBlock, "id">>): ConversationBlock[] {
  return blocks.map((block, index) => ({ ...block, id: blockID(block, index) }));
}

export function parseTerminalConversation(
  pane: string,
  agent: ConversationAgent,
): ConversationBlock[] {
  const lines = stripTerminalControl(pane.slice(-512 * 1024))
    .split("\n")
    .map(cleanLine);
  const blocks: Array<Omit<ConversationBlock, "id">> = [];

  const append = (kind: ConversationBlockKind, text: string, title?: string) => {
    const value = text.trim();
    if (!value && !title) return;
    blocks.push({ kind, text: value, ...(title ? { title } : {}) });
  };

  for (const raw of lines) {
    const value = raw.trim();
    if (isChrome(raw)) continue;

    const userMatch = value.match(/^(?:❯|›|>)\s+(.+)$/u);
    if (userMatch?.[1]) {
      append("user", userMatch[1]);
      continue;
    }

    const claudeMatch = value.match(/^(?:⏺|●)\s*(.*)$/u);
    if (claudeMatch && agent !== "codex") {
      const content = claudeMatch[1]?.trim() ?? "";
      if (isToolTitle(content)) append("tool", "", content);
      else append("assistant", content);
      continue;
    }

    const codexMatch = value.match(/^[•●]\s*(.*)$/u);
    if (codexMatch) {
      const content = codexMatch[1]?.trim() ?? "";
      if (isToolTitle(content)) append("tool", "", content);
      else append("assistant", content);
      continue;
    }

    const resultMatch = value.match(/^(?:⎿|└(?:─)?|↳)\s*(.*)$/u);
    if (resultMatch) {
      const result = resultMatch[1]?.trim() ?? "";
      const previous = blocks.at(-1);
      if (previous?.kind === "tool") previous.text = joinContinuation(previous.text, result, true);
      else append("output", result);
      continue;
    }

    const previous = blocks.at(-1);
    const indented = /^\s{2,}/.test(raw);
    if (previous && indented) {
      previous.text = joinContinuation(
        previous.text,
        value,
        previous.kind === "tool" || previous.kind === "output",
      );
      continue;
    }

    if (previous?.kind === "tool") {
      previous.text = joinContinuation(previous.text, value, true);
    } else if (agent === "shell" || agent === "generic") {
      append("output", value);
    }
  }

  return withStableIDs(blocks.slice(-80));
}

function comparable(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

export function buildConversation(options: ConversationOptions): ConversationBlock[] {
  const blocks = options.pane
    ? parseTerminalConversation(options.pane, options.agent)
    : [];
  const fallbackUser = options.fallbackUser?.trim();
  if (fallbackUser && !blocks.some((block) => block.kind === "user")) {
    blocks.unshift({ id: "fallback_user", kind: "user", text: fallbackUser });
  }

  const latest = options.latestAssistant?.trim();
  if (latest) {
    const latestComparable = comparable(latest);
    let assistantIndex = -1;
    for (let i = blocks.length - 1; i >= 0; i -= 1) {
      if (blocks[i]?.kind === "assistant") {
        assistantIndex = i;
        break;
      }
    }
    const parsed = assistantIndex >= 0 ? comparable(blocks[assistantIndex]?.text ?? "") : "";
    const sameTurn = parsed.length > 0 && (
      latestComparable.includes(parsed) || parsed.includes(latestComparable)
    );
    if (sameTurn && assistantIndex >= 0) {
      blocks[assistantIndex] = {
        ...blocks[assistantIndex]!,
        text: latest,
        streaming: options.latestAssistantStreaming === true,
      };
    } else {
      blocks.push({
        id: "latest_assistant",
        kind: "assistant",
        text: latest,
        streaming: options.latestAssistantStreaming === true,
      });
    }
  }
  return blocks;
}
