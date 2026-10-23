import type { Capability, RemoteSession } from "../protocol/types.ts";
import type { RemoteState } from "./reducer.ts";

export interface ProjectSessionGroup {
  rootPath: string;
  name: string;
  emoji: string | null;
  registered: boolean;
  sessions: RemoteSession[];
  attentionCount: number;
}

export function sessionNeedsAttention(session: RemoteSession): boolean {
  return session.unacknowledged ||
    session.attention.status === "decision" ||
    session.attention.status === "input";
}

function isProjectAgentSession(session: RemoteSession): boolean {
  // Older desktop snapshots do not include an explicit project-agent marker.
  return session.isProjectAgent ?? session.name.startsWith("pass-manager-");
}

function nameFromRoot(rootPath: string): string {
  const segments = rootPath.split(/[\\/]/).filter(Boolean);
  return segments.at(-1) || rootPath;
}

function attentionRank(session: RemoteSession): number {
  if (session.unacknowledged) return 0;
  switch (session.attention.status) {
    case "decision":
    case "input":
      return 0;
    case "working":
      return 1;
    case "finished":
      return 2;
    case "idle":
      return 3;
  }
}

export function selectSortedSessions(state: RemoteState): RemoteSession[] {
  return Object.values(state.sessionsByName).sort((a, b) => {
    const rank = attentionRank(a) - attentionRank(b);
    if (rank !== 0) return rank;
    return Date.parse(b.lastActivity) - Date.parse(a.lastActivity);
  });
}

export function selectNeedsAttention(state: RemoteState): RemoteSession[] {
  return selectSortedSessions(state).filter(sessionNeedsAttention);
}

export function selectOtherSessions(state: RemoteState): RemoteSession[] {
  const needsAttention = new Set(
    selectNeedsAttention(state).map((session) => session.name),
  );
  return selectSortedSessions(state).filter(
    (session) => !needsAttention.has(session.name),
  );
}

export function selectProjects(state: RemoteState) {
  return Object.values(state.projectsByRoot).sort((a, b) =>
    a.name.localeCompare(b.name),
  );
}

/** Follows the first worker in attention order, then appends registered projects without workers. */
export function selectProjectSessionGroups(state: RemoteState): ProjectSessionGroup[] {
  const groups: ProjectSessionGroup[] = [];
  const byRoot = new Map<string, ProjectSessionGroup>();

  for (const session of selectSortedSessions(state)) {
    if (isProjectAgentSession(session)) continue;
    const rootPath = session.projectRoot;
    let group = byRoot.get(rootPath);
    if (!group) {
      const project = state.projectsByRoot[rootPath];
      group = {
        rootPath,
        name: project?.name || nameFromRoot(rootPath),
        emoji: project?.emoji ?? null,
        registered: Boolean(project),
        sessions: [],
        attentionCount: 0,
      };
      groups.push(group);
      byRoot.set(rootPath, group);
    }
    group.sessions.push(session);
    if (sessionNeedsAttention(session)) group.attentionCount += 1;
  }

  for (const project of selectProjects(state)) {
    if (byRoot.has(project.rootPath)) continue;
    groups.push({
      rootPath: project.rootPath,
      name: project.name,
      emoji: project.emoji ?? null,
      registered: true,
      sessions: [],
      attentionCount: 0,
    });
  }
  return groups;
}

export function hasCapability(state: RemoteState, capability: Capability): boolean {
  return state.capabilities.includes(capability);
}
