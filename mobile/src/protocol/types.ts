export const PROTOCOL_VERSION = 1 as const;

export type ProtocolVersion = typeof PROTOCOL_VERSION;

export type AgentKind = "claude" | "codex" | "pi" | "shell" | "generic";

export type Capability =
  | "sessions:read"
  | "sessions:write"
  | "projects:read"
  | "voice:use"
  | "decisions:answer";

export type AttentionStatus =
  | "working"
  | "idle"
  | "decision"
  | "input"
  | "finished";

export interface RemoteAttention {
  status: AttentionStatus;
  receivedAt?: string | null;
  preview?: string | null;
}

export interface RemoteSession {
  name: string;
  displayName: string;
  defaultDisplayName: string;
  projectRoot: string;
  cwd: string;
  agent: AgentKind;
  gitBranch?: string | null;
  attention: RemoteAttention;
  lastMessage?: string | null;
  lastActivity: string;
  isAttached: boolean;
  unacknowledged: boolean;
  launching: boolean;
}

export interface RemoteProject {
  rootPath: string;
  name: string;
  emoji?: string | null;
}

export type VoiceStatus =
  | "idle"
  | "connecting"
  | "listening"
  | "thinking"
  | "speaking"
  | "interrupted"
  | "error";

export interface VoiceTurn {
  id: string;
  role: "user" | "assistant" | "system";
  text: string;
  at: string;
}

export interface VoiceActionConfirmation {
  id: string;
  label: string;
  status: "pending" | "confirmed" | "failed";
  at: string;
  session?: string;
  commandId?: string;
}

export interface ClientCommandPayloadMap {
  "relay.resume": { afterSequence: number };
  "relay.ping": Record<string, never>;
  "session.list": Record<string, never>;
  "session.create": {
    projectRoot: string;
    agent: Extract<AgentKind, "claude" | "codex" | "pi">;
    initialPrompt?: string;
  };
  "session.sendMessage": { session: string; text: string };
  "session.answerDecision": {
    session: string;
    decision: "allowOnce" | "allowAll" | "deny";
  };
  "project.list": Record<string, never>;
}

export type ClientCommandType = keyof ClientCommandPayloadMap;

export interface EnvelopeBase<T extends string> {
  version: ProtocolVersion;
  id: string;
  type: T;
  sentAt: string;
}

export type ClientCommand<K extends ClientCommandType = ClientCommandType> =
  K extends ClientCommandType
    ? EnvelopeBase<K> & { payload: ClientCommandPayloadMap[K] }
    : never;

export type ServerEventPayloadMap = {
  "relay.ready": {
    desktopId: string;
    role: "mobile";
    deviceId: string;
    connectionId: string;
    latestSequence: number;
    connectedAt: string;
  };
  "desktop.presence": { desktopOnline: boolean; mobileCount: number };
  "relay.receipt": {
    commandId: string;
    sequence: number;
    status: "forwarded" | "delivery_failed" | "accepted" | "completed" | "rejected";
    replay: boolean;
  };
  "relay.resume.result": {
    requestId: string;
    commands: Array<{
      commandId: string;
      sequence: number;
      commandType: string;
      mutating: boolean;
      status: "forwarded" | "delivery_failed" | "accepted" | "completed" | "rejected";
      receivedAt: string;
      ackedAt?: string;
    }>;
    truncated: boolean;
    latestSequence: number;
  };
  "relay.pong": { requestId: string };
  ack: { commandType: string; resourceID?: string | null };
  error: {
    code: string;
    message: string;
    retryable: boolean;
  };
  "session.snapshot": {
    generatedAt: string;
    sessions: RemoteSession[];
    projects: RemoteProject[];
    capabilities: Capability[];
    truncated?: boolean;
    totalSessionCount?: number;
    totalProjectCount?: number;
  };
  "message.delivered": { session: string };
};

export type ServerEventType = keyof ServerEventPayloadMap;

export type ServerEvent<K extends ServerEventType = ServerEventType> =
  K extends ServerEventType
    ? EnvelopeBase<K> & {
        replyTo?: string | null;
        payload: ServerEventPayloadMap[K];
      }
    : never;

export interface PairingQrPayload {
  v: ProtocolVersion;
  relayUrl: string;
  desktopId: string;
  authorizationToken: string;
  desktopName?: string;
  desktopPublicKey?: string;
}

export interface PairedDesktop {
  protocolVersion: ProtocolVersion;
  relayUrl: string;
  desktopId: string;
  desktopName: string;
  desktopPublicKey?: string;
  deviceId: string;
  credential: string;
  scopes: Capability[];
  pairedAt: string;
}

export interface UserPreferences {
  notificationsEnabled: boolean;
  decisionAlerts: boolean;
  voiceMode: "push-to-talk" | "hands-free";
}

export const DEFAULT_PREFERENCES: UserPreferences = {
  notificationsEnabled: true,
  decisionAlerts: true,
  voiceMode: "push-to-talk",
};
