/**
 * Reads pass's registered-project MRU list (projects.json) so New Session can offer the same
 * projects the app knows about. Read-only — the app owns this file and writes it atomically.
 *
 * Location mirrors Sources/Pass/Stores/ProjectStore.swift:
 *   ~/Library/Application Support/pass/projects.json
 */
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";

export interface PassProject {
  rootPath: string;
  emoji?: string;
  name: string;
}

const PROJECTS_JSON = join(homedir(), "Library", "Application Support", "pass", "projects.json");

export function loadProjects(): PassProject[] {
  try {
    const raw = readFileSync(PROJECTS_JSON, "utf8");
    const list = JSON.parse(raw) as Array<{ rootPath: string; emoji?: string }>;
    return list
      .filter((p) => typeof p.rootPath === "string" && p.rootPath.length > 0)
      .map((p) => ({ rootPath: p.rootPath, emoji: p.emoji, name: basename(p.rootPath) }));
  } catch {
    return [];
  }
}

/** Emoji a project has been tagged with in pass, keyed by root path. */
export function emojiByRoot(projects: PassProject[]): Map<string, string> {
  const m = new Map<string, string>();
  for (const p of projects) if (p.emoji) m.set(p.rootPath, p.emoji);
  return m;
}
