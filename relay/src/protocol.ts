export const PROTOCOL_VERSION = 1 as const;

export const COMMAND_RETENTION_MS = 10 * 60 * 1_000;
export const TERMINAL_COMMAND_RETENTION_MS = 60 * 1_000;
// The desktop owns command-payload limits (currently 64 Ki Swift Characters).
// The relay only caps the complete UTF-8 frame to bound parsing/memory work.
export const MAX_FRAME_BYTES = 1_024 * 1_024;
export const MAX_RESUME_COMMANDS = 100;

export type Role = "desktop" | "mobile";

export const COMMAND_TYPES = [
  "session.list",
  "session.create",
  "session.sendMessage",
  "session.answerDecision",
  "session.terminal.open",
  "session.terminal.input",
  "session.terminal.close",
  "project.list",
] as const;

export type KnownCommandType = (typeof COMMAND_TYPES)[number];

export const MUTATING_COMMAND_TYPES = [
  "session.create",
  "session.sendMessage",
  "session.answerDecision",
  "session.terminal.input",
] as const satisfies readonly KnownCommandType[];

export const DESKTOP_EVENT_TYPES = [
  "ack",
  "error",
  "session.snapshot",
  "message.delivered",
  "session.message.started",
  "session.message.updated",
  "session.message.completed",
  "session.terminal.snapshot",
] as const;

export type DesktopEventType = (typeof DESKTOP_EVENT_TYPES)[number];
export type StoredCommandStatus =
  | "forwarded"
  | "delivery_failed"
  | "accepted"
  | "completed"
  | "rejected";

/**
 * Wire shape consumed by the Swift RemoteGateway. Unknown command types remain
 * valid so the desktop can return its forward-compatible unsupported_command
 * response. The relay only interprets ids and known mutation semantics.
 */
export type MobileCommand = {
  version: typeof PROTOCOL_VERSION;
  id: string;
  type: string;
  sentAt: string;
  payload: Record<string, unknown>;
};

/**
 * Desktop-to-mobile envelope emitted by Swift. Known v1 types receive relay
 * delivery-state semantics, while additive future types may still be routed by
 * replyTo without requiring a relay deployment first.
 */
export type DesktopEvent = {
  version: typeof PROTOCOL_VERSION;
  id: string;
  type: string;
  sentAt: string;
  replyTo?: string;
  payload: unknown;
};

export type ResumeRequest = {
  version: typeof PROTOCOL_VERSION;
  id: string;
  type: "relay.resume";
  sentAt: string;
  payload: {
    afterSequence: number;
  };
};

export type PingMessage = {
  version: typeof PROTOCOL_VERSION;
  id: string;
  type: "relay.ping";
  sentAt: string;
  payload: Record<string, never>;
};

export type ClientMessage =
  | { kind: "command"; message: MobileCommand }
  | { kind: "desktopEvent"; message: DesktopEvent }
  | { kind: "resume"; message: ResumeRequest }
  | { kind: "ping"; message: PingMessage };

export type CommandMetadata = {
  commandId: string;
  sequence: number;
  commandType: string;
  mutating: boolean;
  status: StoredCommandStatus;
  receivedAt: string;
  ackedAt?: string;
};

type RelayEnvelope<Type extends string, Payload> = {
  version: typeof PROTOCOL_VERSION;
  id: string;
  type: Type;
  sentAt: string;
  payload: Payload;
};

export type MobileRelayMessage =
  | RelayEnvelope<
      "relay.ready",
      {
        desktopId: string;
        role: "mobile";
        deviceId: string;
        connectionId: string;
        latestSequence: number;
        connectedAt: string;
      }
    >
  | RelayEnvelope<
      "desktop.presence",
      {
        desktopOnline: boolean;
        mobileCount: number;
      }
    >
  | RelayEnvelope<
      "relay.receipt",
      {
        commandId: string;
        sequence: number;
        status: StoredCommandStatus;
        replay: boolean;
      }
    >
  | RelayEnvelope<
      "relay.resume.result",
      {
        requestId: string;
        commands: CommandMetadata[];
        truncated: boolean;
        latestSequence: number;
      }
    >
  | RelayEnvelope<
      "relay.pong",
      {
        requestId: string;
      }
    >;

export type MobileServerMessage = DesktopEvent | MobileRelayMessage;

export type ParseFailure = {
  ok: false;
  code: "invalid_message" | "unsupported_version";
  message: string;
  refId?: string;
};

export type ParseResult =
  | { ok: true; value: ClientMessage }
  | ParseFailure;

const IDENTIFIER_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const TYPE_PATTERN = /^[A-Za-z][A-Za-z0-9._:-]{0,127}$/;
const RFC3339_PATTERN =
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|[+-](\d{2}):(\d{2}))$/;
const MUTATING_COMMAND_TYPE_SET = new Set<string>(MUTATING_COMMAND_TYPES);
const DESKTOP_EVENT_TYPE_SET = new Set<string>(DESKTOP_EVENT_TYPES);
const STORED_STATUS_SET = new Set<string>([
  "forwarded",
  "delivery_failed",
  "accepted",
  "completed",
  "rejected",
]);

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function isValidIdentifier(value: unknown): value is string {
  return typeof value === "string" && IDENTIFIER_PATTERN.test(value);
}

export function isValidType(value: unknown): value is string {
  return typeof value === "string" && TYPE_PATTERN.test(value);
}

export function isRole(value: unknown): value is Role {
  return value === "desktop" || value === "mobile";
}

export function isDesktopEventType(value: unknown): value is DesktopEventType {
  return typeof value === "string" && DESKTOP_EVENT_TYPE_SET.has(value);
}

export function isMutatingCommand(commandType: string): boolean {
  return MUTATING_COMMAND_TYPE_SET.has(commandType);
}

export function commandRetentionMs(commandType: string): number {
  return commandType.startsWith("session.terminal.")
    ? TERMINAL_COMMAND_RETENTION_MS
    : COMMAND_RETENTION_MS;
}

export function isStoredCommandStatus(
  value: unknown,
): value is StoredCommandStatus {
  return typeof value === "string" && STORED_STATUS_SET.has(value);
}

export function parseIsoTimestamp(value: unknown): value is string {
  if (typeof value !== "string" || value.length > 64) return false;
  const match = RFC3339_PATTERN.exec(value);
  if (match === null) return false;

  const year = Number(match.at(1));
  const month = Number(match.at(2));
  const day = Number(match.at(3));
  const hour = Number(match.at(4));
  const minute = Number(match.at(5));
  const second = Number(match.at(6));
  const offsetHour = match.at(7);
  const offsetMinute = match.at(8);

  if (
    month < 1 ||
    month > 12 ||
    hour > 23 ||
    minute > 59 ||
    second > 59 ||
    (offsetHour !== undefined && Number(offsetHour) > 23) ||
    (offsetMinute !== undefined && Number(offsetMinute) > 59)
  ) {
    return false;
  }

  const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const daysInMonth = [
    31,
    leapYear ? 29 : 28,
    31,
    30,
    31,
    30,
    31,
    31,
    30,
    31,
    30,
    31,
  ] as const;
  const maximumDay = daysInMonth.at(month - 1);
  return maximumDay !== undefined && day >= 1 && day <= maximumDay;
}

export function parseClientMessage(raw: string): ParseResult {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return {
      ok: false,
      code: "invalid_message",
      message: "Message must be valid JSON.",
    };
  }

  if (!isRecord(value)) {
    return {
      ok: false,
      code: "invalid_message",
      message: "Message must be a JSON object.",
    };
  }

  const refId = isValidIdentifier(value.id) ? value.id : undefined;
  if (value.version !== PROTOCOL_VERSION) {
    return {
      ok: false,
      code: "unsupported_version",
      message: `Only protocol version ${PROTOCOL_VERSION} is supported.`,
      ...(refId === undefined ? {} : { refId }),
    };
  }
  if (
    !isValidIdentifier(value.id) ||
    !isValidType(value.type) ||
    !parseIsoTimestamp(value.sentAt)
  ) {
    return {
      ok: false,
      code: "invalid_message",
      message: "Message requires a valid id, type, and ISO-8601 sentAt.",
      ...(refId === undefined ? {} : { refId }),
    };
  }

  if (value.type === "relay.resume") {
    if (
      !isRecord(value.payload) ||
      typeof value.payload.afterSequence !== "number" ||
      !Number.isSafeInteger(value.payload.afterSequence) ||
      value.payload.afterSequence < 0
    ) {
      return {
        ok: false,
        code: "invalid_message",
        message: "relay.resume requires a non-negative afterSequence.",
        refId: value.id,
      };
    }
    return {
      ok: true,
      value: {
        kind: "resume",
        message: {
          version: PROTOCOL_VERSION,
          id: value.id,
          type: "relay.resume",
          sentAt: value.sentAt,
          payload: { afterSequence: value.payload.afterSequence },
        },
      },
    };
  }

  if (value.type === "relay.ping") {
    if (!isRecord(value.payload)) {
      return {
        ok: false,
        code: "invalid_message",
        message: "relay.ping requires an object payload.",
        refId: value.id,
      };
    }
    return {
      ok: true,
      value: {
        kind: "ping",
        message: {
          version: PROTOCOL_VERSION,
          id: value.id,
          type: "relay.ping",
          sentAt: value.sentAt,
          payload: {},
        },
      },
    };
  }

  // A replyTo unambiguously marks a desktop response, including additive
  // future event types unknown to this relay build. Known unsolicited event
  // types are also parsed here; unknown unsolicited types remain ambiguous and
  // are interpreted according to the authenticated socket role by the room.
  if (isDesktopEventType(value.type) || value.replyTo !== undefined) {
    if (
      value.replyTo !== undefined &&
      !isValidIdentifier(value.replyTo)
    ) {
      return {
        ok: false,
        code: "invalid_message",
        message: "Desktop event replyTo must be a valid identifier.",
        refId: value.id,
      };
    }
    return {
      ok: true,
      value: {
        kind: "desktopEvent",
        message: {
          version: PROTOCOL_VERSION,
          id: value.id,
          type: value.type,
          sentAt: value.sentAt,
          ...(value.replyTo === undefined ? {} : { replyTo: value.replyTo }),
          payload: value.payload,
        },
      },
    };
  }

  if (!isRecord(value.payload)) {
    return {
      ok: false,
      code: "invalid_message",
      message: "Command requires an object payload.",
      refId: value.id,
    };
  }

  return {
    ok: true,
    value: {
      kind: "command",
      message: {
        version: PROTOCOL_VERSION,
        id: value.id,
        type: value.type,
        sentAt: value.sentAt,
        payload: value.payload,
      },
    },
  };
}
