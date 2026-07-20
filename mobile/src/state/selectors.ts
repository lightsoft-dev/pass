import type { Capability, RemoteSession } from "../protocol/types.ts";
import type { RemoteState } from "./reducer.ts";

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
  return selectSortedSessions(state).filter(
    (session) =>
      session.unacknowledged ||
      session.attention.status === "decision" ||
      session.attention.status === "input",
  );
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

export function hasCapability(state: RemoteState, capability: Capability): boolean {
  return state.capabilities.includes(capability);
}
