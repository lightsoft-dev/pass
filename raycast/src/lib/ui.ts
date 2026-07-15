import { Color, Icon, Image } from "@raycast/api";
import { SessionStatus } from "./session";

/** Colored icon that reads a session's state at a glance. */
export function statusIcon(status: SessionStatus): Image.ImageLike {
  switch (status) {
    case "decision":
      return { source: Icon.QuestionMarkCircle, tintColor: Color.Orange };
    case "working":
      return { source: Icon.CircleProgress, tintColor: Color.Blue };
    default:
      return { source: Icon.Circle, tintColor: Color.SecondaryText };
  }
}

export function statusLabel(status: SessionStatus): string {
  switch (status) {
    case "decision":
      return "Needs answer";
    case "working":
      return "Working";
    default:
      return "Idle";
  }
}

/** "3m", "2h", "1d" style compact age. */
export function shortAge(date: Date, now = new Date()): string {
  const secs = Math.max(0, Math.floor((now.getTime() - date.getTime()) / 1000));
  if (secs < 60) return `${secs}s`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h`;
  return `${Math.floor(hours / 24)}d`;
}
