import {
  PROTOCOL_VERSION,
  type AgentKind,
  type Capability,
  type RemoteAttention,
  type RemoteProject,
  type RemoteSession,
  type ServerEvent,
  type ServerEventType,
} from "./types.ts";
import { utf8ByteLength } from "./commands.ts";

const STREAM_MESSAGE_BYTES = 64 * 1_024;
const TERMINAL_SNAPSHOT_BYTES = 512 * 1_024;

export type ProtocolParseErrorCode =
  | "invalid_json"
  | "invalid_envelope"
  | "unsupported_version"
  | "unknown_type"
  | "invalid_payload";

export type ProtocolParseResult =
  | { ok: true; event: ServerEvent }
  | { ok: false; code: ProtocolParseErrorCode; message: string };

const SERVER_EVENT_TYPES = new Set<ServerEventType>([
  "relay.ready",
  "desktop.presence",
  "relay.receipt",
  "relay.resume.result",
  "relay.pong",
  "ack",
  "error",
  "session.snapshot",
  "message.delivered",
  "session.message.started",
  "session.message.updated",
  "session.message.completed",
  "session.terminal.snapshot",
]);

const RECEIPT_STATUSES = new Set([
  "forwarded",
  "delivery_failed",
  "accepted",
  "completed",
  "rejected",
]);

const AGENTS = new Set<AgentKind>([
  "claude",
  "codex",
  "pi",
  "shell",
  "generic",
]);

const CAPABILITIES = new Set<Capability>([
  "sessions:read",
  "sessions:write",
  "sessions:stream",
  "sessions:terminal",
  "projects:read",
  "voice:use",
  "decisions:answer",
]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isString(value: unknown, max = 100_000): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= max;
}

function isOptionalString(value: unknown, max?: number): boolean {
  return value === undefined || value === null || isString(value, max);
}

function isOptionalUTF8String(value: unknown, maximumBytes: number): boolean {
  return (
    value === undefined ||
    value === null ||
    (typeof value === "string" &&
      value.length > 0 &&
      utf8ByteLength(value) <= maximumBytes)
  );
}

function isTimestamp(value: unknown): value is string {
  return isString(value, 100) && Number.isFinite(Date.parse(value));
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function isCommandMetadata(value: unknown): boolean {
  if (!isRecord(value)) return false;
  return (
    isString(value.commandId, 200) &&
    isNonNegativeInteger(value.sequence) &&
    isString(value.commandType, 100) &&
    typeof value.mutating === "boolean" &&
    RECEIPT_STATUSES.has(String(value.status)) &&
    isTimestamp(value.receivedAt) &&
    (value.ackedAt === undefined || isTimestamp(value.ackedAt))
  );
}

function isCapabilityArray(value: unknown): value is Capability[] {
  return (
    Array.isArray(value) &&
    value.length <= CAPABILITIES.size &&
    value.every((item) =>
      CAPABILITIES.has(item as Capability),
    )
  );
}

export function isRemoteAttention(value: unknown): value is RemoteAttention {
  if (!isRecord(value) || !isString(value.status, 20)) return false;
  return (
    ["working", "idle", "decision", "input", "finished"].includes(
      value.status,
    ) &&
    (value.receivedAt === undefined ||
      value.receivedAt === null ||
      isTimestamp(value.receivedAt)) &&
    (value.preview === undefined ||
      value.preview === null ||
      (typeof value.preview === "string" && value.preview.length <= 20_000))
  );
}

export function isRemoteSession(value: unknown): value is RemoteSession {
  if (!isRecord(value)) return false;
  return (
    isString(value.name, 300) &&
    isString(value.displayName, 500) &&
    isString(value.defaultDisplayName, 500) &&
    isString(value.projectRoot, 4096) &&
    isString(value.cwd, 4096) &&
    AGENTS.has(value.agent as AgentKind) &&
    isOptionalString(value.gitBranch, 500) &&
    isRemoteAttention(value.attention) &&
    isOptionalString(value.lastMessage) &&
    isOptionalUTF8String(value.liveMessage, STREAM_MESSAGE_BYTES) &&
    (value.liveMessageTruncated === undefined ||
      typeof value.liveMessageTruncated === "boolean") &&
    isTimestamp(value.lastActivity) &&
    typeof value.isAttached === "boolean" &&
    typeof value.unacknowledged === "boolean" &&
    typeof value.launching === "boolean"
  );
}

export function isRemoteProject(value: unknown): value is RemoteProject {
  if (!isRecord(value)) return false;
  return (
    isString(value.rootPath, 4096) &&
    isString(value.name, 500) &&
    isOptionalString(value.emoji, 32)
  );
}

function validPayload(type: ServerEventType, payload: unknown): boolean {
  if (!isRecord(payload)) return false;
  switch (type) {
    case "relay.ready":
      return (
        isString(payload.desktopId, 200) &&
        payload.role === "mobile" &&
        isString(payload.deviceId, 200) &&
        isString(payload.connectionId, 200) &&
        isNonNegativeInteger(payload.latestSequence) &&
        isTimestamp(payload.connectedAt)
      );
    case "desktop.presence":
      return (
        typeof payload.desktopOnline === "boolean" &&
        isNonNegativeInteger(payload.mobileCount)
      );
    case "relay.receipt":
      return (
        isString(payload.commandId, 200) &&
        isNonNegativeInteger(payload.sequence) &&
        RECEIPT_STATUSES.has(String(payload.status)) &&
        typeof payload.replay === "boolean"
      );
    case "relay.resume.result":
      return (
        isString(payload.requestId, 200) &&
        Array.isArray(payload.commands) &&
        payload.commands.length <= 100 &&
        payload.commands.every(isCommandMetadata) &&
        typeof payload.truncated === "boolean" &&
        isNonNegativeInteger(payload.latestSequence)
      );
    case "relay.pong":
      return isString(payload.requestId, 200);
    case "ack":
      return (
        isString(payload.commandType, 100) &&
        isOptionalString(payload.resourceID, 500)
      );
    case "error":
      return (
        isString(payload.code, 200) &&
        isString(payload.message, 20_000) &&
        typeof payload.retryable === "boolean"
      );
    case "session.snapshot":
      return (
        isTimestamp(payload.generatedAt) &&
        Array.isArray(payload.sessions) &&
        payload.sessions.length <= 500 &&
        payload.sessions.every(isRemoteSession) &&
        Array.isArray(payload.projects) &&
        payload.projects.length <= 500 &&
        payload.projects.every(isRemoteProject) &&
        isCapabilityArray(payload.capabilities) &&
        (payload.truncated === undefined || typeof payload.truncated === "boolean") &&
        (payload.totalSessionCount === undefined ||
          isNonNegativeInteger(payload.totalSessionCount)) &&
        (payload.totalProjectCount === undefined ||
          isNonNegativeInteger(payload.totalProjectCount))
      );
    case "message.delivered":
      return isString(payload.session, 300);
    case "session.message.started":
    case "session.message.updated":
    case "session.message.completed":
      return (
        isString(payload.session, 300) &&
        isString(payload.messageID, 200) &&
        isNonNegativeInteger(payload.sequence) &&
        typeof payload.text === "string" &&
        utf8ByteLength(payload.text) <= STREAM_MESSAGE_BYTES &&
        typeof payload.truncated === "boolean"
      );
    case "session.terminal.snapshot":
      return (
        isString(payload.session, 300) &&
        isString(payload.subscriptionId, 128) &&
        isString(payload.revision, 128) &&
        (payload.content === undefined ||
          payload.content === null ||
          (typeof payload.content === "string" &&
            utf8ByteLength(payload.content) <= TERMINAL_SNAPSHOT_BYTES)) &&
        isNonNegativeInteger(payload.columns) &&
        payload.columns >= 1 && payload.columns <= 1_000 &&
        isNonNegativeInteger(payload.rows) &&
        payload.rows >= 1 && payload.rows <= 1_000 &&
        isNonNegativeInteger(payload.cursorX) &&
        payload.cursorX < payload.columns &&
        isNonNegativeInteger(payload.cursorY) &&
        payload.cursorY < payload.rows &&
        typeof payload.truncated === "boolean"
      );
  }
}

export function parseServerEvent(raw: string | unknown): ProtocolParseResult {
  let candidate: unknown = raw;
  if (typeof raw === "string") {
    if (raw.length > 1_000_000) {
      return {
        ok: false,
        code: "invalid_json",
        message: "Relay frame exceeds the 1 MB control-plane limit.",
      };
    }
    try {
      candidate = JSON.parse(raw) as unknown;
    } catch {
      return { ok: false, code: "invalid_json", message: "Malformed JSON frame." };
    }
  }

  if (!isRecord(candidate)) {
    return {
      ok: false,
      code: "invalid_envelope",
      message: "Relay frame must be an object.",
    };
  }
  if (candidate.version !== PROTOCOL_VERSION) {
    return {
      ok: false,
      code: "unsupported_version",
      message: `Expected protocol v${PROTOCOL_VERSION}.`,
    };
  }
  if (
    !isString(candidate.id, 200) ||
    !isString(candidate.type, 100) ||
    !isTimestamp(candidate.sentAt) ||
    (candidate.replyTo !== undefined &&
      candidate.replyTo !== null &&
      !isString(candidate.replyTo, 200))
  ) {
    return {
      ok: false,
      code: "invalid_envelope",
      message: "Relay frame has an invalid id, type, or timestamp.",
    };
  }
  if (!SERVER_EVENT_TYPES.has(candidate.type as ServerEventType)) {
    return {
      ok: false,
      code: "unknown_type",
      message: `Unknown relay event: ${candidate.type}`,
    };
  }

  const type = candidate.type as ServerEventType;
  if (!validPayload(type, candidate.payload)) {
    return {
      ok: false,
      code: "invalid_payload",
      message: `Invalid payload for ${type}.`,
    };
  }

  return { ok: true, event: candidate as unknown as ServerEvent };
}
