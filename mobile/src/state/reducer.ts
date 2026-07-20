import type {
  Capability,
  ClientCommand,
  ClientCommandType,
  RemoteProject,
  RemoteSession,
  SessionMessageStreamPayload,
  ServerEvent,
  VoiceActionConfirmation,
  VoiceStatus,
  VoiceTurn,
} from "../protocol/types.ts";

export type ConnectionPhase =
  | "unconfigured"
  | "disconnected"
  | "connecting"
  | "authenticating"
  | "online"
  | "desktop-offline"
  | "reconnecting"
  | "error";

export type CommandStatus =
  | "sending"
  | "accepted"
  | "completed"
  | "delivered"
  | "failed";

export interface PendingCommand {
  id: string;
  type: ClientCommandType;
  sentAt: string;
  status: CommandStatus;
  session?: string;
  preview?: string;
  error?: string;
}

export interface RemoteActivity {
  id: string;
  kind: "message" | "attention" | "session" | "voice";
  title: string;
  detail?: string;
  session?: string;
  at: string;
  status?: CommandStatus;
}

export interface SessionMessageStream {
  messageID: string;
  sequence: number;
  text: string;
  truncated: boolean;
  phase: "streaming" | "completed";
  updatedAt: string;
}

export interface RemoteState {
  connection: {
    phase: ConnectionPhase;
    attempt: number;
    desktopOnline: boolean;
    lastError?: string;
    lastConnectedAt?: string;
  };
  sessionsByName: Record<string, RemoteSession>;
  projectsByRoot: Record<string, RemoteProject>;
  capabilities: Capability[];
  pendingCommands: Record<string, PendingCommand>;
  activities: RemoteActivity[];
  messageStreamsBySession: Record<string, SessionMessageStream>;
  voice: {
    status: VoiceStatus;
    conversationId?: string;
    message?: string;
    turns: VoiceTurn[];
    actions: VoiceActionConfirmation[];
  };
  lastSyncedAt?: string;
  snapshotTruncation?: {
    shownSessionCount: number;
    totalSessionCount: number;
    shownProjectCount: number;
    totalProjectCount: number;
  };
  latestSequence: number;
  protocolErrors: number;
}

export const initialRemoteState: RemoteState = {
  connection: {
    phase: "unconfigured",
    attempt: 0,
    desktopOnline: false,
  },
  sessionsByName: {},
  projectsByRoot: {},
  capabilities: [],
  pendingCommands: {},
  activities: [],
  messageStreamsBySession: {},
  voice: { status: "idle", turns: [], actions: [] },
  latestSequence: 0,
  protocolErrors: 0,
};

export type RemoteAction =
  | { type: "RESET"; configured: boolean }
  | {
      type: "CONNECTION_PHASE";
      phase: ConnectionPhase;
      attempt?: number;
      error?: string;
    }
  | { type: "COMMAND_SENT"; command: ClientCommand }
  | { type: "EVENT_RECEIVED"; event: ServerEvent }
  | { type: "PROTOCOL_ERROR"; message: string };

function indexBy<T>(items: T[], key: (item: T) => string): Record<string, T> {
  return Object.fromEntries(items.map((item) => [key(item), item]));
}

function keepNewest<T>(items: T[], max: number): T[] {
  return items.length <= max ? items : items.slice(items.length - max);
}

function commandMetadata(command: ClientCommand): Pick<PendingCommand, "session" | "preview"> {
  switch (command.type) {
    case "session.sendMessage":
      return {
        session: command.payload.session,
        preview: command.payload.text.slice(0, 500),
      };
    case "session.answerDecision":
      return {
        session: command.payload.session,
        preview: command.payload.decision,
      };
    case "session.create":
      return { preview: `${command.payload.agent} · ${command.payload.projectRoot}` };
    default:
      return {};
  }
}

function addCommandActivity(
  activities: RemoteActivity[],
  command: ClientCommand,
): RemoteActivity[] {
  if (command.type !== "session.sendMessage") return activities;
  return keepNewest(
    [
      ...activities,
      {
        id: command.id,
        kind: "message" as const,
        title: "Message sent from mobile",
        detail: command.payload.text.slice(0, 2_000),
        session: command.payload.session,
        at: command.sentAt,
        status: "sending" as const,
      },
    ],
    150,
  );
}

function updateActivityStatus(
  activities: RemoteActivity[],
  commandId: string,
  status: CommandStatus,
  detail?: string,
): RemoteActivity[] {
  return activities.map((item) =>
    item.id === commandId
      ? { ...item, status, ...(detail ? { detail } : {}) }
      : item,
  );
}

function updateCommand(
  commands: Record<string, PendingCommand>,
  id: string,
  update: Partial<PendingCommand>,
): Record<string, PendingCommand> {
  const current = commands[id];
  if (!current) return commands;
  return { ...commands, [id]: { ...current, ...update } };
}

function snapshotActivities(state: RemoteState, event: Extract<ServerEvent, { type: "session.snapshot" }>) {
  const changes: RemoteActivity[] = [];
  for (const session of event.payload.sessions) {
    const previous = state.sessionsByName[session.name];
    if (!previous || previous.attention.status === session.attention.status) continue;
    const status = session.attention.status;
    changes.push({
      id: `${event.id}:${session.name}`,
      kind: "attention",
      title:
        status === "decision"
          ? "Needs a decision"
          : status === "input"
            ? "Needs input"
            : status === "working"
              ? "Agent resumed work"
              : status === "finished"
                ? "Agent finished"
                : "Agent is idle",
      ...(session.attention.preview
        ? { detail: session.attention.preview }
        : {}),
      session: session.name,
      at: session.attention.receivedAt ?? event.payload.generatedAt,
    });
  }
  return keepNewest([...state.activities, ...changes], 150);
}

function snapshotMessageStreams(
  state: RemoteState,
  event: Extract<ServerEvent, { type: "session.snapshot" }>,
): Record<string, SessionMessageStream> {
  const streams: Record<string, SessionMessageStream> = {};
  for (const session of event.payload.sessions) {
    if (!session.liveMessage) continue;
    const current = state.messageStreamsBySession[session.name];
    const currentIsNewer =
      current?.phase === "streaming" &&
      current.updatedAt.localeCompare(event.payload.generatedAt) > 0;
    streams[session.name] = currentIsNewer
      ? current
      : {
          messageID: current?.messageID ?? `snapshot:${event.id}:${session.name}`,
          sequence: current?.sequence ?? 0,
          text: session.liveMessage,
          truncated: session.liveMessageTruncated === true,
          phase: "streaming",
          updatedAt: event.payload.generatedAt,
        };
  }
  return streams;
}

function applyMessageStream(
  state: RemoteState,
  payload: SessionMessageStreamPayload,
  phase: SessionMessageStream["phase"],
  updatedAt: string,
): RemoteState {
  const current = state.messageStreamsBySession[payload.session];
  if (
    current?.messageID === payload.messageID &&
    current.sequence >= payload.sequence
  ) {
    return state;
  }

  const stream: SessionMessageStream = {
    messageID: payload.messageID,
    sequence: payload.sequence,
    text: payload.text,
    truncated: payload.truncated,
    phase,
    updatedAt,
  };
  const session = state.sessionsByName[payload.session];
  const sessionsByName = session
    ? {
        ...state.sessionsByName,
        [payload.session]: {
          ...session,
          liveMessage: phase === "streaming" ? payload.text : null,
          liveMessageTruncated:
            phase === "streaming" ? payload.truncated : undefined,
          ...(phase === "completed" ? { lastMessage: payload.text } : {}),
        },
      }
    : state.sessionsByName;

  return {
    ...state,
    sessionsByName,
    messageStreamsBySession: {
      ...state.messageStreamsBySession,
      [payload.session]: stream,
    },
  };
}

function receiptStatus(
  status: Extract<ServerEvent, { type: "relay.receipt" }>["payload"]["status"],
  commandType?: string,
): CommandStatus {
  switch (status) {
    case "forwarded":
      return "sending";
    case "accepted":
      return commandType === "session.sendMessage" ? "accepted" : "completed";
    case "completed":
      return commandType === "session.sendMessage" ? "delivered" : "completed";
    case "delivery_failed":
    case "rejected":
      return "failed";
  }
}

function reduceEvent(state: RemoteState, event: ServerEvent): RemoteState {
  switch (event.type) {
    case "relay.ready":
      return {
        ...state,
        connection: {
          ...state.connection,
          phase: "authenticating",
          lastConnectedAt: event.payload.connectedAt,
        },
        latestSequence: Math.max(state.latestSequence, event.payload.latestSequence),
      };
    case "desktop.presence":
      return {
        ...state,
        connection: {
          ...state.connection,
          phase: event.payload.desktopOnline
            ? state.connection.phase === "online"
              ? "online"
              : "authenticating"
            : "desktop-offline",
          desktopOnline: event.payload.desktopOnline,
        },
      };
    case "relay.receipt": {
      const status = receiptStatus(
        event.payload.status,
        state.pendingCommands[event.payload.commandId]?.type,
      );
      return {
        ...state,
        latestSequence: Math.max(state.latestSequence, event.payload.sequence),
        pendingCommands: updateCommand(
          state.pendingCommands,
          event.payload.commandId,
          {
            status,
            ...(status === "failed"
              ? { error: `Relay marked command ${event.payload.status}.` }
              : {}),
          },
        ),
        activities: updateActivityStatus(
          state.activities,
          event.payload.commandId,
          status,
        ),
      };
    }
    case "relay.resume.result": {
      let pendingCommands = state.pendingCommands;
      let activities = state.activities;
      for (const command of event.payload.commands) {
        const status = receiptStatus(command.status, command.commandType);
        pendingCommands = updateCommand(pendingCommands, command.commandId, { status });
        activities = updateActivityStatus(activities, command.commandId, status);
      }
      return {
        ...state,
        pendingCommands,
        activities,
        latestSequence: Math.max(state.latestSequence, event.payload.latestSequence),
      };
    }
    case "relay.pong":
      return state;
    case "ack": {
      if (!event.replyTo) return state;
      const commandType =
        state.pendingCommands[event.replyTo]?.type ?? event.payload.commandType;
      const status =
        commandType === "session.sendMessage" ? "accepted" : "completed";
      return {
        ...state,
        pendingCommands: updateCommand(state.pendingCommands, event.replyTo, {
          status,
        }),
        activities: updateActivityStatus(
          state.activities,
          event.replyTo,
          status,
        ),
      };
    }
    case "error": {
      const offline = ["desktop.offline", "desktop_offline"].includes(
        event.payload.code,
      );
      if (!event.replyTo) {
        return {
          ...state,
          connection: {
            ...state.connection,
            phase: offline ? "desktop-offline" : "error",
            desktopOnline: offline ? false : state.connection.desktopOnline,
            lastError: event.payload.message,
          },
        };
      }
      return {
        ...state,
        pendingCommands: updateCommand(state.pendingCommands, event.replyTo, {
          status: "failed",
          error: event.payload.message,
        }),
        activities: updateActivityStatus(
          state.activities,
          event.replyTo,
          "failed",
          event.payload.message,
        ),
        ...(offline
          ? {
              connection: {
                ...state.connection,
                phase: "desktop-offline" as const,
                desktopOnline: false,
                lastError: event.payload.message,
              },
            }
          : {}),
      };
    }
    case "session.snapshot":
      return {
        ...state,
        connection: {
          phase: "online",
          attempt: 0,
          desktopOnline: true,
          lastConnectedAt: event.sentAt,
        },
        sessionsByName: indexBy(event.payload.sessions, (session) => session.name),
        projectsByRoot: indexBy(event.payload.projects, (project) => project.rootPath),
        capabilities: event.payload.capabilities,
        activities: snapshotActivities(state, event),
        messageStreamsBySession: snapshotMessageStreams(state, event),
        lastSyncedAt: event.payload.generatedAt,
        snapshotTruncation: event.payload.truncated
          ? {
              shownSessionCount: event.payload.sessions.length,
              totalSessionCount:
                event.payload.totalSessionCount ?? event.payload.sessions.length,
              shownProjectCount: event.payload.projects.length,
              totalProjectCount:
                event.payload.totalProjectCount ?? event.payload.projects.length,
            }
          : undefined,
      };
    case "session.message.started":
    case "session.message.updated":
      return applyMessageStream(
        state,
        event.payload,
        "streaming",
        event.sentAt,
      );
    case "session.message.completed":
      return applyMessageStream(
        state,
        event.payload,
        "completed",
        event.sentAt,
      );
    case "message.delivered": {
      const commandId = event.replyTo ?? event.id;
      const pendingCommands = updateCommand(
        state.pendingCommands,
        commandId,
        { status: "delivered" },
      );
      const hadActivity = state.activities.some((item) => item.id === commandId);
      const deliveredActivity: RemoteActivity = {
        id: commandId,
        kind: "message",
        title: "Instruction delivered",
        session: event.payload.session,
        at: event.sentAt,
        status: "delivered",
      };
      const activities = hadActivity
        ? updateActivityStatus(state.activities, commandId, "delivered")
        : keepNewest([...state.activities, deliveredActivity], 150);
      return { ...state, pendingCommands, activities };
    }
  }
}

export function remoteReducer(state: RemoteState, action: RemoteAction): RemoteState {
  switch (action.type) {
    case "RESET":
      return {
        ...initialRemoteState,
        connection: {
          ...initialRemoteState.connection,
          phase: action.configured ? "disconnected" : "unconfigured",
        },
      };
    case "CONNECTION_PHASE":
      return {
        ...state,
        connection: {
          ...state.connection,
          phase: action.phase,
          attempt: action.attempt ?? state.connection.attempt,
          desktopOnline:
            action.phase === "online" ? true : action.phase === "desktop-offline" ? false : state.connection.desktopOnline,
          ...(action.error ? { lastError: action.error } : {}),
        },
      };
    case "COMMAND_SENT": {
      const metadata = commandMetadata(action.command);
      const command: PendingCommand = {
        id: action.command.id,
        type: action.command.type,
        sentAt: action.command.sentAt,
        status: "sending",
        ...metadata,
      };
      const entries = Object.values({
        ...state.pendingCommands,
        [command.id]: command,
      }).sort((a, b) => a.sentAt.localeCompare(b.sentAt));
      return {
        ...state,
        pendingCommands: indexBy(keepNewest(entries, 150), (item) => item.id),
        activities: addCommandActivity(state.activities, action.command),
      };
    }
    case "EVENT_RECEIVED":
      return reduceEvent(state, action.event);
    case "PROTOCOL_ERROR":
      return {
        ...state,
        protocolErrors: state.protocolErrors + 1,
        connection: { ...state.connection, lastError: action.message },
      };
  }
}
