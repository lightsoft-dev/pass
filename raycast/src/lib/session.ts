/**
 * Builds the rich per-session view the commands render, deriving from tmux + git the same way
 * pass does. In tmux-direct mode there is no hook feed, so "needs attention" is derived from the
 * visible pane: a numbered decision menu (permission prompt / AskUserQuestion) is the precise,
 * actionable signal; a streaming turn is "working"; everything else is "idle".
 */
import { execFile } from "node:child_process";
import { basename } from "node:path";
import { promisify } from "node:util";
import { AgentKind, agentGlyph, inferAgent } from "./config";
import { bestSummary, DecisionOption, decisionPrompt, isWorking, parseDecision } from "./pane";
import { emojiByRoot, loadProjects } from "./projects";
import { capturePane, listPassSessions, RawSession, resolveBin } from "./tmux";

const pexecFile = promisify(execFile);

export type SessionStatus = "decision" | "working" | "idle";

export interface Session {
  name: string;
  projectRoot: string;
  projectName: string;
  cwd: string;
  agent: AgentKind;
  glyph: string;
  emoji?: string;
  branch?: string;
  isWorktree: boolean;
  attached: boolean;
  activity: Date;
  status: SessionStatus;
  /** The agent's latest prose / on-screen summary. */
  summary?: string;
  /** Present only when status === "decision". */
  decisionOptions: DecisionOption[];
  decisionPrompt?: string;
  /** Full display label: "repo · branch" with a worktree badge. */
  displayName: string;
}

/** Best-effort, cheap git identity: branch + whether cwd is a linked worktree. */
async function gitIdentity(cwd: string, gitPath: string | null): Promise<{ branch?: string; isWorktree: boolean }> {
  if (!gitPath || !cwd) return { isWorktree: false };
  try {
    const { stdout } = await pexecFile(
      gitPath,
      ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD", "--is-inside-work-tree", "--git-dir"],
      { timeout: 3000 },
    );
    const parts = stdout.trim().split("\n");
    const branch = parts[0] && parts[0] !== "HEAD" ? parts[0] : undefined;
    // A linked worktree's git-dir lives under <main>/.git/worktrees/<name>.
    const gitDir = parts[2] ?? "";
    const isWorktree = gitDir.includes("/.git/worktrees/");
    return { branch, isWorktree };
  } catch {
    return { isWorktree: false };
  }
}

function deriveStatus(pane: string, decision: DecisionOption[], agent: AgentKind): SessionStatus {
  if (decision.length >= 2) return "decision";
  if (agent !== "shell" && isWorking(pane)) return "working";
  return "idle";
}

function buildDisplayName(projectName: string, branch: string | undefined, isWorktree: boolean): string {
  let s = projectName;
  if (isWorktree) s += " ⧉";
  if (branch) s += ` · ${branch}`;
  return s;
}

async function buildOne(raw: RawSession, gitPath: string | null, emoji: Map<string, string>): Promise<Session> {
  const pane = await capturePane(raw.name, false);
  const agent: AgentKind = (raw.agentOption as AgentKind) || inferAgent(raw.paneCommand);
  const decisionOptions = parseDecision(pane);
  const status = deriveStatus(pane, decisionOptions, agent);
  const projectRoot = raw.projectRoot || raw.cwd;
  const projectName = projectRoot ? basename(projectRoot) : raw.name;
  const { branch, isWorktree } = await gitIdentity(raw.cwd, gitPath);

  return {
    name: raw.name,
    projectRoot,
    projectName,
    cwd: raw.cwd,
    agent,
    glyph: agentGlyph(agent),
    emoji: emoji.get(projectRoot),
    branch,
    isWorktree,
    attached: raw.attached,
    activity: raw.activity,
    status,
    summary: bestSummary(pane),
    decisionOptions,
    decisionPrompt: status === "decision" ? decisionPrompt(pane) : undefined,
    displayName: buildDisplayName(projectName, branch, isWorktree),
  };
}

const statusRank: Record<SessionStatus, number> = { decision: 0, working: 1, idle: 2 };

/** Load every pass session, enriched and sorted (needs-you first, then most recently active). */
export async function loadSessions(): Promise<Session[]> {
  const [raws, gitPath] = await Promise.all([listPassSessions(), resolveBin("git")]);
  const emoji = emojiByRoot(loadProjects());
  const sessions = await Promise.all(raws.map((r) => buildOne(r, gitPath, emoji)));
  sessions.sort((a, b) => {
    if (statusRank[a.status] !== statusRank[b.status]) return statusRank[a.status] - statusRank[b.status];
    return b.activity.getTime() - a.activity.getTime();
  });
  return sessions;
}
