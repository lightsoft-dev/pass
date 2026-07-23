export type AgentKind = "claude" | "codex" | "pi" | "shell" | "generic";
export type AttentionStatus = "working" | "idle" | "decision" | "input" | "finished";

export interface DeckSession {
  name: string;
  displayName: string;
  projectRoot: string;
  cwd: string;
  agent: AgentKind;
  gitBranch?: string | null;
  attention: { status: AttentionStatus; preview?: string | null };
  lastMessage?: string | null;
  lastActivity: string;
  isAttached: boolean;
}

export interface TerminalFrame {
  session: string;
  revision: string;
  content: string;
  columns: number;
  rows: number;
  cursorX: number;
  cursorY: number;
  truncated: boolean;
}

export interface ProjectChoice {
  rootPath: string;
  name: string;
  emoji?: string | null;
}

export interface PairingProfile {
  relayUrl: string;
  desktopId: string;
  desktopName: string;
  deviceId: string;
  credential: string;
  credentialExpiresAt?: string;
  refreshCredential?: string;
  refreshExpiresAt?: string;
}

export interface DeckState {
  phase: "offline" | "connecting" | "online" | "desktop-offline" | "error";
  statusText: string;
  sessions: DeckSession[];
  projects: ProjectChoice[];
  selectedSession?: string;
  frame?: TerminalFrame;
  pairing?: {
    qrDataURL: string;
    deviceName: string;
    expiresAt: string;
  };
  pairingError?: string;
}

export interface CreateSessionInput {
  projectRoot: string;
  agent: Extract<AgentKind, "claude" | "codex" | "pi">;
  initialPrompt?: string;
}

export interface ActionResult { ok: boolean; error?: string }

export interface PassDeckAPI {
  getState(): Promise<DeckState>;
  selectSession(name?: string): Promise<DeckState>;
  sendMessage(session: string, text: string): Promise<ActionResult>;
  answerDecision(session: string, decision: "allowOnce" | "allowAll" | "deny"): Promise<ActionResult>;
  sendTerminalInput(session: string, input: string): Promise<ActionResult>;
  createSession(input: CreateSessionInput): Promise<ActionResult>;
  connectRemote(rawProfile: string): Promise<ActionResult>;
  startPairing(relayUrl: string): Promise<ActionResult>;
  disconnectRemote(): Promise<void>;
  onState(listener: (state: DeckState) => void): () => void;
}

declare global {
  interface Window { passDeck: PassDeckAPI }
}
