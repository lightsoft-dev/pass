/**
 * Constants and small helpers mirrored from the pass macOS app (Sources/Pass/Core).
 * The Raycast extension talks to tmux directly, so it must agree with pass on session
 * naming and the custom tmux options pass writes.
 */

/** All pass-managed tmux sessions are `pass-<slug>`. */
export const SESSION_PREFIX = "pass-";

/** tmux user options pass sets on each session. */
export const OPT_PROJECT_ROOT = "@pass_project_root";
export const OPT_AGENT = "@pass_agent";

/** Env var pass injects at create so hooks can self-identify. */
export const SESSION_ENV_VAR = "PASS_SESSION";

/** Delay between a bracketed paste and Enter so the agent's TUI processes the paste. */
export const PASTE_TO_ENTER_DELAY_MS = 150;

export type AgentKind = "claude" | "codex" | "pi" | "shell" | "generic";

/** Glyph shown per agent, matching pass's AgentKind.glyph. */
export function agentGlyph(agent: AgentKind): string {
  switch (agent) {
    case "claude":
      return "✳";
    case "codex":
      return "⬢";
    case "pi":
      return "π";
    case "shell":
      return "$";
    default:
      return "•";
  }
}

/** Agents the user can start from New Session (shell/generic are adopted, never launched). */
export const LAUNCHABLE_AGENTS: AgentKind[] = ["claude", "codex", "pi"];

/** Built-in launch command per agent (before any preference override). */
export function defaultLaunchCommand(agent: AgentKind): string | undefined {
  switch (agent) {
    case "claude":
      return "claude";
    case "codex":
      return "codex";
    case "pi":
      return "pi";
    default:
      return undefined;
  }
}

/** Best-effort mapping from a pane's foreground command to an agent kind (pass's AgentKind.infer). */
export function inferAgent(paneCommand: string): AgentKind {
  const c = paneCommand.toLowerCase();
  if (c.startsWith("claude")) return "claude";
  if (c.startsWith("codex")) return "codex";
  if (c === "pi") return "pi";
  if (["zsh", "bash", "fish", "sh", "-zsh", "-bash"].includes(c)) return "shell";
  return "generic";
}

/**
 * tmux session names cannot contain '.' or ':' and shouldn't contain whitespace — map anything
 * awkward to '-'. Mirrors pass's Slug.make.
 */
export function slug(s: string): string {
  const mapped = Array.from(s.toLowerCase())
    .map((ch) => (/[a-z0-9]/.test(ch) ? ch : "-"))
    .join("");
  let out = mapped;
  while (out.includes("--")) out = out.replace(/--/g, "-");
  return out.replace(/^-+|-+$/g, "");
}

/**
 * Session name for a project dir + optional branch/label:
 *   pass-<repo>            (main checkout)
 *   pass-<repo>--<branch>  (specific branch / worktree)
 * Mirrors pass's Slug.sessionName.
 */
export function sessionName(repo: string, branch?: string): string {
  let name = SESSION_PREFIX + slug(repo);
  if (branch && branch.trim() !== "") name += "--" + slug(branch);
  return name;
}
