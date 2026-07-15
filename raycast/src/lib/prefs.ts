import { getPreferenceValues } from "@raycast/api";
import { TerminalPreference } from "./attach";
import { AgentKind, defaultLaunchCommand } from "./config";

interface Prefs {
  terminalApp: TerminalPreference;
  claudeCommand: string;
  codexCommand: string;
  piCommand: string;
}

/** Extension preferences with defaults applied. */
export function prefs(): Prefs {
  const p = getPreferenceValues<Prefs>();
  return {
    terminalApp: p.terminalApp || "ghostty",
    claudeCommand: p.claudeCommand || "claude",
    codexCommand: p.codexCommand || "codex",
    piCommand: p.piCommand || "pi",
  };
}

/** Effective launch command for a fresh session with the given agent. */
export function launchCommandFor(agent: AgentKind): string | undefined {
  const p = prefs();
  switch (agent) {
    case "claude":
      return p.claudeCommand;
    case "codex":
      return p.codexCommand;
    case "pi":
      return p.piCommand;
    default:
      return defaultLaunchCommand(agent);
  }
}
