import {
  createCommand,
  encodeCommand,
  validateCommand,
} from "../protocol/commands.ts";
import { parseServerEvent } from "../protocol/guards.ts";
import {
  PROTOCOL_VERSION,
  type ClientCommand,
  type ClientCommandPayloadMap,
  type ClientCommandType,
  type PairedDesktop,
  type ServerEvent,
} from "../protocol/types.ts";
import type { ConnectionPhase } from "../state/reducer.ts";

type SocketMessageEvent = { data: unknown };
type SocketCloseEvent = { code: number; reason?: string };

interface SocketLike {
  readonly readyState: number;
  onopen: (() => void) | null;
  onmessage: ((event: SocketMessageEvent) => void) | null;
  onerror: (() => void) | null;
  onclose: ((event: SocketCloseEvent) => void) | null;
  send(data: string): void;
  close(code?: number, reason?: string): void;
}

type ReactNativeWebSocketOptions = {
  headers?: Record<string, string>;
};

export type SocketFactory = (
  url: string,
  protocols: string[],
  options: ReactNativeWebSocketOptions,
) => SocketLike;

export type RemoteClientStatus = {
  phase: ConnectionPhase;
  attempt: number;
  error?: string;
};

type RemoteClientOptions = {
  pairing: PairedDesktop;
  onEvent: (event: ServerEvent) => void;
  onCommand?: (command: ClientCommand) => void;
  onStatus: (status: RemoteClientStatus) => void;
  onProtocolError?: (message: string) => void;
  socketFactory?: SocketFactory;
  random?: () => number;
  uuidFactory: () => string;
  openTimeoutMs?: number;
  maximumOutboundFrameBytes?: number;
};

const OPEN = 1;
const MUTATING_COMMANDS = new Set<ClientCommandType>([
  "session.create",
  "session.sendMessage",
  "session.answerDecision",
]);

export class RemoteClientError extends Error {
  readonly code: "not_connected" | "desktop_offline" | "send_failed";

  constructor(
    code: "not_connected" | "desktop_offline" | "send_failed",
    message: string,
  ) {
    super(message);
    this.name = "RemoteClientError";
    this.code = code;
  }
}

function defaultSocketFactory(
  url: string,
  protocols: string[],
  options: ReactNativeWebSocketOptions,
): SocketLike {
  const ReactNativeWebSocket = WebSocket as unknown as new (
    url: string,
    protocols?: string[],
    options?: ReactNativeWebSocketOptions,
  ) => SocketLike;
  return new ReactNativeWebSocket(url, protocols, options);
}

export function controlSocketUrl(pairing: PairedDesktop): string {
  const url = new URL(pairing.relayUrl);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  const path = url.pathname.replace(/\/+$/, "");
  url.pathname = path.endsWith("/connect") ? path : `${path}/connect`;
  url.search = "";
  return url.toString();
}

export function reconnectDelayMs(
  attempt: number,
  random: () => number = Math.random,
): number {
  const ceiling = Math.min(30_000, 750 * 2 ** Math.min(attempt, 8));
  return Math.round(ceiling * (0.5 + random() * 0.5));
}

export class RemoteClient {
  private readonly options: RemoteClientOptions;
  private socket: SocketLike | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private openTimer: ReturnType<typeof setTimeout> | null = null;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private stopped = true;
  private reconnectAttempt = 0;
  private authenticated = false;
  private desktopOnline = false;
  private latestSequence = 0;
  private resumeRequestId: string | null = null;
  private resumeCursor: number | null = null;

  constructor(options: RemoteClientOptions) {
    this.options = options;
  }

  connect(): void {
    if (this.socket || !this.stopped) return;
    this.stopped = false;
    this.openSocket();
  }

  reconnect(): void {
    this.stop(false);
    this.reconnectAttempt = 0;
    this.stopped = false;
    this.openSocket();
  }

  stop(notify = true): void {
    this.stopped = true;
    this.authenticated = false;
    this.desktopOnline = false;
    this.resumeRequestId = null;
    this.resumeCursor = null;
    this.clearTimers();
    const socket = this.socket;
    this.socket = null;
    if (socket) {
      socket.onopen = null;
      socket.onmessage = null;
      socket.onerror = null;
      socket.onclose = null;
      socket.close(1000, "mobile client paused");
    }
    if (notify) {
      this.options.onStatus({ phase: "disconnected", attempt: 0 });
    }
  }

  send<K extends ClientCommandType>(
    type: K,
    payload: ClientCommandPayloadMap[K],
  ): ClientCommand<K> {
    const command = createCommand(type, payload, {
      uuidFactory: this.options.uuidFactory,
    });
    validateCommand(command);
    if (!this.socket || this.socket.readyState !== OPEN || !this.authenticated) {
      throw new RemoteClientError(
        "not_connected",
        "The relay connection is not ready yet.",
      );
    }
    if (!this.desktopOnline && MUTATING_COMMANDS.has(type)) {
      throw new RemoteClientError(
        "desktop_offline",
        "The paired desktop is offline. Mutating commands are not queued.",
      );
    }
    this.sendRaw(command);
    this.options.onCommand?.(command);
    return command;
  }

  private openSocket(): void {
    this.options.onStatus({
      phase: this.reconnectAttempt > 0 ? "reconnecting" : "connecting",
      attempt: this.reconnectAttempt,
    });
    let socket: SocketLike;
    try {
      socket = (this.options.socketFactory ?? defaultSocketFactory)(
        controlSocketUrl(this.options.pairing),
        [],
        {
          headers: {
            Authorization: `Bearer ${this.options.pairing.credential}`,
            "X-Pass-Protocol-Version": String(PROTOCOL_VERSION),
            "X-Pass-Desktop-ID": this.options.pairing.desktopId,
            "X-Pass-Role": "mobile",
            "X-Pass-Device-ID": this.options.pairing.deviceId,
          },
        },
      );
    } catch (error) {
      this.scheduleReconnect(error instanceof Error ? error.message : "WebSocket failed.");
      return;
    }
    this.socket = socket;
    this.openTimer = setTimeout(() => {
      if (this.socket === socket && !this.desktopOnline) {
        socket.close(4000, "connection timeout");
      }
    }, this.options.openTimeoutMs ?? 15_000);

    socket.onopen = () => {
      if (this.socket !== socket) return;
      // A successful HTTP upgrade already authenticated the bearer credential.
      this.authenticated = true;
      this.options.onStatus({
        phase: "authenticating",
        attempt: this.reconnectAttempt,
      });
    };
    socket.onmessage = (message) => {
      if (this.socket !== socket) return;
      this.handleMessage(message.data);
    };
    socket.onerror = () => {
      if (this.socket !== socket) return;
      this.options.onStatus({
        phase: "error",
        attempt: this.reconnectAttempt,
        error: "WebSocket transport error.",
      });
    };
    socket.onclose = (event) => {
      if (this.socket !== socket) return;
      this.socket = null;
      this.authenticated = false;
      this.desktopOnline = false;
      this.clearConnectionTimers();
      if (!this.stopped) {
        const reason = event.reason
          ? `Connection closed: ${event.reason}`
          : `Connection closed (${event.code}).`;
        this.scheduleReconnect(reason);
      }
    };
  }

  private handleMessage(raw: unknown): void {
    if (typeof raw !== "string") {
      this.options.onProtocolError?.("Ignored a non-text control-plane frame.");
      return;
    }
    const parsed = parseServerEvent(raw);
    if (!parsed.ok) {
      this.options.onProtocolError?.(parsed.message);
      return;
    }
    const event = parsed.event;
    if (event.type === "relay.ready") {
      this.reconnectAttempt = 0;
      this.startHeartbeat();
      try {
        this.requestResume(this.latestSequence);
      } catch {
        // Presence or close will settle the connection immediately after relay.ready.
      }
    } else if (event.type === "desktop.presence") {
      const wasDesktopOnline = this.desktopOnline;
      this.desktopOnline = event.payload.desktopOnline;
      this.reconnectAttempt = 0;
      this.clearOpenTimer();
      if (event.payload.desktopOnline) {
        if (!wasDesktopOnline) {
          this.options.onStatus({ phase: "authenticating", attempt: 0 });
          this.requestSnapshot();
        }
      } else {
        this.options.onStatus({ phase: "desktop-offline", attempt: 0 });
      }
    } else if (event.type === "relay.receipt") {
      this.latestSequence = Math.max(this.latestSequence, event.payload.sequence);
    } else if (event.type === "relay.resume.result") {
      const matchesActivePage = event.payload.requestId === this.resumeRequestId;
      const requestedCursor = matchesActivePage ? this.resumeCursor : null;
      this.latestSequence = Math.max(
        this.latestSequence,
        event.payload.latestSequence,
      );
      if (
        requestedCursor !== null &&
        event.payload.truncated &&
        event.payload.latestSequence > requestedCursor
      ) {
        try {
          this.requestResume(event.payload.latestSequence);
        } catch {
          this.resumeRequestId = null;
          this.resumeCursor = null;
        }
      } else if (matchesActivePage) {
        this.resumeRequestId = null;
        this.resumeCursor = null;
      }
    } else if (event.type === "session.snapshot") {
      this.desktopOnline = true;
      this.reconnectAttempt = 0;
      this.clearOpenTimer();
      this.options.onStatus({ phase: "online", attempt: 0 });
    } else if (
      event.type === "error" &&
      ["desktop.offline", "desktop_offline"].includes(event.payload.code)
    ) {
      this.desktopOnline = false;
      this.reconnectAttempt = 0;
      this.clearOpenTimer();
      this.options.onStatus({
        phase: "desktop-offline",
        attempt: 0,
        error: event.payload.message,
      });
    }
    this.options.onEvent(event);
  }

  private requestSnapshot(): void {
    try {
      this.send("session.list", {});
      this.send("project.list", {});
    } catch {
      // A close racing presence will be handled by the reconnect path.
    }
  }

  private requestResume(afterSequence: number): void {
    const command = createCommand(
      "relay.resume",
      { afterSequence },
      { uuidFactory: this.options.uuidFactory },
    );
    this.resumeRequestId = command.id;
    this.resumeCursor = afterSequence;
    try {
      this.sendRaw(command);
    } catch (error) {
      this.resumeRequestId = null;
      this.resumeCursor = null;
      throw error;
    }
  }

  private sendRaw(command: ClientCommand): void {
    const socket = this.socket;
    if (!socket || socket.readyState !== OPEN) {
      throw new RemoteClientError("send_failed", "WebSocket is not open.");
    }
    try {
      socket.send(
        encodeCommand(command, this.options.maximumOutboundFrameBytes),
      );
    } catch (error) {
      throw new RemoteClientError(
        "send_failed",
        error instanceof Error ? error.message : "Could not send command.",
      );
    }
  }

  private scheduleReconnect(error: string): void {
    if (this.stopped || this.reconnectTimer) return;
    this.reconnectAttempt += 1;
    const delay = reconnectDelayMs(
      this.reconnectAttempt - 1,
      this.options.random ?? Math.random,
    );
    this.options.onStatus({
      phase: "reconnecting",
      attempt: this.reconnectAttempt,
      error,
    });
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      if (!this.stopped) this.openSocket();
    }, delay);
  }

  private startHeartbeat(): void {
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = setInterval(() => {
      if (!this.socket || this.socket.readyState !== OPEN) return;
      try {
        this.sendRaw(
          createCommand("relay.ping", {}, {
            uuidFactory: this.options.uuidFactory,
          }),
        );
      } catch {
        // The close handler owns reconnection.
      }
    }, 25_000);
  }

  private clearOpenTimer(): void {
    if (this.openTimer) clearTimeout(this.openTimer);
    this.openTimer = null;
  }

  private clearConnectionTimers(): void {
    this.clearOpenTimer();
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = null;
  }

  private clearTimers(): void {
    this.clearConnectionTimers();
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
  }
}
