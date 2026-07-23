import WebSocket from "ws";
import { randomUUID } from "node:crypto";
import type { ActionResult, CreateSessionInput, DeckSession, PairingProfile, ProjectChoice, TerminalFrame } from "../shared/types.ts";

type RemoteSnapshot = {
  sessions: DeckSession[];
  projects: ProjectChoice[];
  capabilities: string[];
};

type ServerEvent = {
  version: 1;
  id: string;
  type: string;
  sentAt: string;
  replyTo?: string;
  payload: Record<string, unknown>;
};

export function socketURL(relayUrl: string): string {
  const url = new URL(relayUrl);
  if (url.protocol !== "https:" && url.protocol !== "http:" && url.protocol !== "wss:" && url.protocol !== "ws:") {
    throw new Error("Relay URL은 HTTPS 또는 WSS여야 합니다.");
  }
  url.protocol = url.protocol === "https:" ? "wss:" : url.protocol === "http:" ? "ws:" : url.protocol;
  url.pathname = url.pathname.replace(/\/+$/, "").endsWith("/connect")
    ? url.pathname.replace(/\/+$/, "")
    : `${url.pathname.replace(/\/+$/, "")}/connect`;
  url.search = "";
  return url.toString();
}

export function parsePairingProfile(raw: string): PairingProfile {
  const value = JSON.parse(raw) as Record<string, unknown>;
  const credential = value.credential ?? value.authorizationToken ?? value.pairingToken;
  if (typeof value.relayUrl !== "string" || typeof value.desktopId !== "string" || typeof credential !== "string") {
    throw new Error("relayUrl, desktopId, credential(또는 authorizationToken)이 필요합니다.");
  }
  socketURL(value.relayUrl);
  return {
    relayUrl: value.relayUrl,
    desktopId: value.desktopId,
    desktopName: typeof value.desktopName === "string" ? value.desktopName : "Pass Desktop",
    deviceId: typeof value.deviceId === "string" ? value.deviceId : `deck_${randomUUID()}`,
    credential,
    ...(typeof value.credentialExpiresAt === "string" ? { credentialExpiresAt: value.credentialExpiresAt } : {}),
    ...(typeof value.refreshCredential === "string" ? { refreshCredential: value.refreshCredential } : {}),
    ...(typeof value.refreshExpiresAt === "string" ? { refreshExpiresAt: value.refreshExpiresAt } : {}),
  };
}

export class RemoteDeckClient {
  private socket?: WebSocket;
  private desktopOnline = false;
  private reconnectTimer?: NodeJS.Timeout;
  private terminalRenewTimer?: NodeJS.Timeout;
  private credentialRefreshTimer?: NodeJS.Timeout;
  private stopped = true;
  private profile?: PairingProfile;
  private snapshot: RemoteSnapshot = { sessions: [], projects: [], capabilities: [] };
  private frames = new Map<string, TerminalFrame>();
  private selected?: string;
  private readonly notify: () => void;
  private readonly onProfileUpdate?: (profile: PairingProfile) => void;

  constructor(notify: () => void, onProfileUpdate?: (profile: PairingProfile) => void) {
    this.notify = notify;
    this.onProfileUpdate = onProfileUpdate;
  }

  get data() { return { ...this.snapshot, desktopOnline: this.desktopOnline, frame: this.selected ? this.frames.get(this.selected) : undefined }; }

  connect(profile: PairingProfile): void {
    this.disconnect();
    this.profile = profile;
    this.stopped = false;
    this.scheduleCredentialRefresh();
    this.open();
  }

  disconnect(): void {
    this.stopped = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    if (this.terminalRenewTimer) clearInterval(this.terminalRenewTimer);
    if (this.credentialRefreshTimer) clearTimeout(this.credentialRefreshTimer);
    this.socket?.close(1000, "deck client closed");
    this.socket = undefined;
    this.desktopOnline = false;
    this.notify();
  }

  select(name?: string): void {
    if (this.terminalRenewTimer) clearInterval(this.terminalRenewTimer);
    if (this.selected && this.selected !== name) this.send("session.terminal.close", { session: this.selected, subscriptionId: `deck:${this.selected}` }, true);
    this.selected = name;
    if (name) {
      const renew = () => {
        const previousRevision = this.frames.get(name)?.revision;
        this.send("session.terminal.open", {
          session: name,
          subscriptionId: `deck:${name}`,
          ...(previousRevision ? { previousRevision } : {}),
        }, true);
      };
      renew();
      this.terminalRenewTimer = setInterval(renew, 10_000);
    }
  }

  sendMessage(session: string, text: string) { return this.command("session.sendMessage", { session, text }); }
  answerDecision(session: string, decision: string) { return this.command("session.answerDecision", { session, decision }); }
  sendTerminalInput(session: string, input: string) { return this.command("session.terminal.input", { session, subscriptionId: `deck:${session}`, input }); }
  createSession(input: CreateSessionInput) { return this.command("session.create", input as unknown as Record<string, unknown>); }

  private command(type: string, payload: Record<string, unknown>): ActionResult {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return { ok: false, error: "Relay 연결이 준비되지 않았습니다." };
    if (!this.desktopOnline) return { ok: false, error: "원격 데스크톱이 오프라인입니다." };
    this.send(type, payload);
    return { ok: true };
  }

  private open(): void {
    if (!this.profile || this.stopped) return;
    const profile = this.profile;
    const socket = new WebSocket(socketURL(profile.relayUrl), {
      headers: {
        Authorization: `Bearer ${profile.credential}`,
        "X-Pass-Protocol-Version": "1",
        "X-Pass-Desktop-ID": profile.desktopId,
        "X-Pass-Role": "mobile",
        "X-Pass-Device-ID": profile.deviceId,
      },
    });
    this.socket = socket;
    socket.on("open", () => this.notify());
    socket.on("message", (data) => this.handle(data.toString()));
    socket.on("close", () => {
      if (this.socket !== socket) return;
      this.socket = undefined;
      this.desktopOnline = false;
      this.notify();
      if (!this.stopped) this.reconnectTimer = setTimeout(() => this.open(), 1500);
    });
    socket.on("error", () => this.notify());
  }

  private scheduleCredentialRefresh(): void {
    if (this.credentialRefreshTimer) clearTimeout(this.credentialRefreshTimer);
    if (!this.profile?.refreshCredential || !this.profile.credentialExpiresAt) return;
    const delay = Math.max(0, Date.parse(this.profile.credentialExpiresAt) - Date.now() - 60_000);
    this.credentialRefreshTimer = setTimeout(() => void this.refreshCredential(), delay);
  }

  private async refreshCredential(): Promise<void> {
    const profile = this.profile;
    if (!profile?.refreshCredential) return;
    try {
      const response = await fetch(`${profile.relayUrl.replace(/\/+$/, "")}/v2/token/refresh`, {
        method: "POST",
        headers: { Authorization: `Bearer ${profile.refreshCredential}` },
      });
      const payload = await response.json() as { credentials?: { accessToken: string; accessExpiresAt: string; refreshToken: string; refreshExpiresAt: string } };
      if (!response.ok || !payload.credentials) throw new Error("Credential refresh failed.");
      this.profile = {
        ...profile,
        credential: payload.credentials.accessToken,
        credentialExpiresAt: payload.credentials.accessExpiresAt,
        refreshCredential: payload.credentials.refreshToken,
        refreshExpiresAt: payload.credentials.refreshExpiresAt,
      };
      this.onProfileUpdate?.(this.profile);
      this.connect(this.profile);
    } catch {
      this.notify();
      if (!this.stopped) this.credentialRefreshTimer = setTimeout(() => void this.refreshCredential(), 30_000);
    }
  }

  private handle(raw: string): void {
    let event: ServerEvent;
    try { event = JSON.parse(raw) as ServerEvent; } catch { return; }
    if (event.version !== 1 || typeof event.type !== "string") return;
    if (event.type === "relay.ready") {
      this.send("relay.resume", { afterSequence: 0 });
      this.send("session.list", {});
      this.send("project.list", {});
    } else if (event.type === "desktop.presence") {
      this.desktopOnline = event.payload.desktopOnline === true;
      if (this.desktopOnline) this.send("session.list", {});
    } else if (event.type === "session.snapshot") {
      const sessions = Array.isArray(event.payload.sessions) ? event.payload.sessions as DeckSession[] : [];
      const projects = Array.isArray(event.payload.projects) ? event.payload.projects as ProjectChoice[] : [];
      const capabilities = Array.isArray(event.payload.capabilities) ? event.payload.capabilities as string[] : [];
      this.snapshot = { sessions, projects, capabilities };
      if (this.selected) this.send("session.terminal.open", { session: this.selected, subscriptionId: `deck:${this.selected}` }, true);
    } else if (event.type === "session.terminal.snapshot") {
      const payload = event.payload as unknown as TerminalFrame & { subscriptionId: string };
      const previous = this.frames.get(payload.session);
      this.frames.set(payload.session, { ...payload, content: payload.content ?? previous?.content ?? "" });
    } else if (event.type.startsWith("session.message.")) {
      const session = event.payload.session;
      if (typeof session === "string") {
        const index = this.snapshot.sessions.findIndex((item) => item.name === session);
        if (index >= 0) this.snapshot.sessions[index] = { ...this.snapshot.sessions[index], lastMessage: String(event.payload.text ?? "") };
      }
    }
    this.notify();
  }

  private send(type: string, payload: Record<string, unknown>, quiet = false): void {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return;
    this.socket.send(JSON.stringify({ version: 1, id: `deck_${randomUUID()}`, type, sentAt: new Date().toISOString(), payload }));
    if (!quiet) this.notify();
  }
}
