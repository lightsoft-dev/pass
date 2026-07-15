/**
 * The single choke point for sending anything into a session's pane. Every injection runs
 * classify → deliver. Refuses to type into a bare shell (that would run arbitrary commands).
 *
 * Port of Sources/Pass/Core/ReplyInjector.swift (Claude interaction profile).
 */
import { inferAgent, PASTE_TO_ENTER_DELAY_MS } from "./config";
import { cancelMode, capturePane, paneState, pasteBuffer, sendKeys, setBuffer } from "./tmux";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export type PaneKind = "agentReady" | "permissionDialog" | "shell" | "copyMode";

export type InjectResult = { ok: true } | { ok: false; reason: "refusedShell" | "error"; message?: string };

/** Claude: "Do you want to create X?  ❯ 1. Yes  2. …  3. No  Esc to cancel". */
function isPermissionDialog(tail: string): boolean {
  return tail.includes("❯ 1.") && (tail.includes("Do you want") || tail.includes("Esc to cancel"));
}

async function captureTail(session: string, lineCount = 12): Promise<string> {
  const full = await capturePane(session, false);
  return full.split("\n").slice(-lineCount).join("\n");
}

/** Classify the pane before acting. */
export async function classify(session: string): Promise<PaneKind> {
  const state = await paneState(session);
  if (state.inMode) return "copyMode";
  if (inferAgent(state.command) === "shell") return "shell";
  const tail = await captureTail(session);
  if (isPermissionDialog(tail)) return "permissionDialog";
  return "agentReady";
}

/**
 * Send free-text into the agent's input box: bracketed paste + delay + Enter.
 * Returns refusedShell when the agent isn't running (safety).
 */
export async function sendText(session: string, text: string, allowShell = false): Promise<InjectResult> {
  const kind = await classify(session);
  if (kind === "copyMode") {
    await cancelMode(session); // then fall through, re-injecting as agentReady
  } else if (kind === "shell" && !allowShell) {
    return { ok: false, reason: "refusedShell" };
  }
  await setBuffer(text);
  await pasteBuffer(session);
  await sleep(PASTE_TO_ENTER_DELAY_MS);
  await sendKeys(session, ["Enter"]);
  return { ok: true };
}

export type Decision = "allowOnce" | "allowAll" | "deny";

/** Answer a permission prompt via single keypress (Claude: 1 / 2 / 3). */
export async function sendDecision(session: string, decision: Decision): Promise<InjectResult> {
  const keys = decision === "allowOnce" ? ["1"] : decision === "allowAll" ? ["2"] : ["3"];
  await sendKeys(session, keys);
  return { ok: true };
}

/**
 * Pick a numbered option from a menu. A bare digit selects+confirms the choice. Refuses a bare shell.
 */
export async function pick(session: string, option: number): Promise<InjectResult> {
  if ((await classify(session)) === "shell") return { ok: false, reason: "refusedShell" };
  await sendKeys(session, [String(option)]);
  return { ok: true };
}
