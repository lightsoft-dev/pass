/**
 * Opens a real terminal attached to a tmux session — the "I need real hands" escape hatch.
 * Prefers Ghostty, falls back to Terminal.app. Both drive AppleScript via osascript.
 *
 * Port of Sources/Pass/Services/AttachService.swift.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { resolveBin } from "./tmux";

const pexecFile = promisify(execFile);

async function runAppleScript(source: string): Promise<boolean> {
  try {
    await pexecFile("/usr/bin/osascript", ["-e", source], { timeout: 8000 });
    return true;
  } catch {
    return false;
  }
}

async function ghosttyInstalled(): Promise<boolean> {
  // `open -Ra` succeeds (exit 0) when an app with that name is registered.
  try {
    await pexecFile("/usr/bin/open", ["-Ra", "Ghostty"], { timeout: 4000 });
    return true;
  } catch {
    return false;
  }
}

function ghosttyScript(cmd: string): string {
  return [
    'tell application "Ghostty"',
    "  activate",
    "  set cfg to new surface configuration",
    `  set command of cfg to "${cmd}"`,
    "  new window with configuration cfg",
    "end tell",
  ].join("\n");
}

function terminalScript(cmd: string): string {
  return ['tell application "Terminal"', "  activate", `  do script "${cmd}"`, "end tell"].join("\n");
}

export type TerminalPreference = "ghostty" | "terminal";

/** Open a terminal attached to `session`. Returns false only if every attempt failed. */
export async function attach(session: string, preference: TerminalPreference = "ghostty"): Promise<boolean> {
  const tmuxPath = (await resolveBin("tmux")) ?? "/opt/homebrew/bin/tmux";
  const cmd = `${tmuxPath} attach-session -t ${session}`;

  if (preference === "ghostty" && (await ghosttyInstalled())) {
    if (await runAppleScript(ghosttyScript(cmd))) return true;
  }
  return runAppleScript(terminalScript(cmd));
}
