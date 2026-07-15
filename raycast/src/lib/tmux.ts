/**
 * The only place that spawns tmux. Resolves the binary once (Raycast's Node runs with a
 * minimal PATH, so we probe common locations and fall back to a login shell), then every call
 * uses the absolute path against the default socket — so `tmux attach` from any terminal works.
 *
 * Mirrors Sources/Pass/Core/TmuxClient.swift.
 */
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { promisify } from "node:util";
import { OPT_AGENT, OPT_PROJECT_ROOT, SESSION_ENV_VAR, SESSION_PREFIX } from "./config";

const pexecFile = promisify(execFile);

/** tmux escapes non-printable control bytes in -F output, so a real tab separator is required. */
const SEP = "\t";

const COMMON_BIN_DIRS = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"];

const binCache = new Map<string, string | null>();

/** Resolve an executable's absolute path: common dirs first, then `zsh -lc 'command -v'`. */
export async function resolveBin(name: string): Promise<string | null> {
  if (binCache.has(name)) return binCache.get(name) ?? null;
  for (const dir of COMMON_BIN_DIRS) {
    const p = `${dir}/${name}`;
    if (existsSync(p)) {
      binCache.set(name, p);
      return p;
    }
  }
  try {
    const { stdout } = await pexecFile("/bin/zsh", ["-lc", `command -v ${name}`], { timeout: 4000 });
    const path = stdout.trim().split("\n").pop()?.trim();
    if (path && existsSync(path)) {
      binCache.set(name, path);
      return path;
    }
  } catch {
    // not found
  }
  binCache.set(name, null);
  return null;
}

export type ProcResult = { stdout: string; stderr: string; code: number };

/** Run tmux with the given args. Never throws — non-zero exit is returned in `code`. */
export async function tmux(args: string[]): Promise<ProcResult> {
  const bin = await resolveBin("tmux");
  if (!bin) return { stdout: "", stderr: "tmux not found", code: 127 };
  try {
    const { stdout, stderr } = await pexecFile(bin, args, { timeout: 8000, maxBuffer: 8 * 1024 * 1024 });
    return { stdout, stderr, code: 0 };
  } catch (e) {
    const err = e as { stdout?: string; stderr?: string; code?: number };
    return { stdout: err.stdout ?? "", stderr: err.stderr ?? String(e), code: err.code ?? 1 };
  }
}

const ok = (r: ProcResult) => r.code === 0;

/** Raw session facts read from tmux, before git identity is resolved. */
export interface RawSession {
  name: string;
  created: Date;
  attached: boolean;
  activity: Date;
  projectRoot?: string;
  agentOption?: string;
  cwd: string;
  paneCommand: string;
  paneInMode: boolean;
}

const epoch = (s: string): Date => new Date((Number(s) || 0) * 1000);

/**
 * List all pass-* sessions with their active-pane details. Empty when no tmux server is running.
 * One list-sessions call + one list-panes call, exactly like pass's reconcile.
 */
export async function listPassSessions(): Promise<RawSession[]> {
  const sess = await tmux([
    "list-sessions",
    "-F",
    [
      "#{session_name}",
      "#{session_created}",
      "#{session_attached}",
      "#{session_activity}",
      `#{${OPT_PROJECT_ROOT}}`,
      `#{${OPT_AGENT}}`,
    ].join(SEP),
  ]);
  // No server / no sessions → treat as empty, not an error.
  if (!ok(sess)) return [];

  const panes = await tmux([
    "list-panes",
    "-a",
    "-F",
    ["#{session_name}", "#{pane_active}", "#{pane_current_path}", "#{pane_current_command}", "#{pane_in_mode}"].join(
      SEP,
    ),
  ]);
  const paneBySession = new Map<string, { cwd: string; cmd: string; inMode: boolean }>();
  for (const line of panes.stdout.split("\n")) {
    const f = line.split(SEP);
    if (f.length < 5 || f[1] !== "1") continue; // active pane only
    paneBySession.set(f[0], { cwd: f[2], cmd: f[3], inMode: f[4] === "1" });
  }

  const result: RawSession[] = [];
  for (const line of sess.stdout.split("\n")) {
    const f = line.split(SEP);
    if (f.length < 6) continue;
    if (!f[0].startsWith(SESSION_PREFIX)) continue;
    const pane = paneBySession.get(f[0]);
    result.push({
      name: f[0],
      created: epoch(f[1]),
      attached: f[2] === "1",
      activity: epoch(f[3]),
      projectRoot: f[4] || undefined,
      agentOption: f[5] || undefined,
      cwd: pane?.cwd ?? "",
      paneCommand: pane?.cmd ?? "",
      paneInMode: pane?.inMode ?? false,
    });
  }
  return result;
}

export async function hasSession(name: string): Promise<boolean> {
  return ok(await tmux(["has-session", "-t", name]));
}

/** Visible pane contents. `colors` includes SGR escapes (`-e`). */
export async function capturePane(name: string, colors = false): Promise<string> {
  const args = ["capture-pane", "-p", "-J", "-t", name];
  if (colors) args.splice(1, 0, "-e");
  return (await tmux(args)).stdout;
}

/** Query a pane fact via display-message. */
export async function display(name: string, format: string): Promise<string> {
  return (await tmux(["display-message", "-p", "-t", name, format])).stdout.trim();
}

/** (pane_in_mode, pane_current_command) in one query — the injector pre-check. */
export async function paneState(name: string): Promise<{ inMode: boolean; command: string }> {
  const out = await display(name, "#{pane_in_mode}\t#{pane_current_command}");
  const f = out.split(SEP);
  return { inMode: f[0] === "1", command: f[1] ?? "" };
}

/** Load arbitrary text into the tmux paste buffer (single arg → no escaping needed). */
export async function setBuffer(text: string): Promise<void> {
  await tmux(["set-buffer", "--", text]);
}

/** Paste the buffer into a pane using bracketed paste (`-p`), deleting the buffer (`-d`). */
export async function pasteBuffer(name: string): Promise<void> {
  await tmux(["paste-buffer", "-t", name, "-p", "-d"]);
}

/** Send literal key names (e.g. ["Enter"], ["1"], ["y"]) to a pane. */
export async function sendKeys(name: string, keys: string[]): Promise<void> {
  await tmux(["send-keys", "-t", name, ...keys]);
}

/** Exit copy-mode (or any pane mode) if the pane is in one. */
export async function cancelMode(name: string): Promise<void> {
  await tmux(["send-keys", "-t", name, "-X", "cancel"]);
}

/** Create a detached session running a shell in `cwd`, tag it, then launch the agent. */
export async function newSession(opts: {
  name: string;
  cwd: string;
  projectRoot: string;
  agent: string;
  launchCommand?: string;
}): Promise<void> {
  await tmux([
    "new-session",
    "-d",
    "-s",
    opts.name,
    "-c",
    opts.cwd,
    "-x",
    "220",
    "-y",
    "50",
    "-e",
    `${SESSION_ENV_VAR}=${opts.name}`,
  ]);
  await tmux(["set-option", "-t", opts.name, OPT_PROJECT_ROOT, opts.projectRoot]);
  await tmux(["set-option", "-t", opts.name, OPT_AGENT, opts.agent]);
  if (opts.launchCommand && opts.launchCommand.trim() !== "") {
    await tmux(["send-keys", "-t", opts.name, opts.launchCommand, "Enter"]);
  }
}

export async function killSession(name: string): Promise<void> {
  await tmux(["kill-session", "-t", name]);
}
