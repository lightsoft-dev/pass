import { DurableObject } from "cloudflare:workers";

import {
  authenticateDeviceCredential,
  extractBearerToken,
  tokensMatch,
} from "./auth";
import { handleControlRequest } from "./control";

import {
  MAX_FRAME_BYTES,
  MAX_RESUME_COMMANDS,
  PROTOCOL_VERSION,
  commandRetentionMs,
  isMutatingCommand,
  isRecord,
  isRole,
  isStoredCommandStatus,
  isValidIdentifier,
  parseClientMessage,
  type CommandMetadata,
  type DesktopEvent,
  type MobileCommand,
  type MobileRelayMessage,
  type MobileServerMessage,
  type Role,
  type StoredCommandStatus,
} from "./protocol";

const INTERNAL_DESKTOP_ID_HEADER = "X-Pass-Internal-Desktop-ID";
const INTERNAL_ROLE_HEADER = "X-Pass-Internal-Role";
const INTERNAL_DEVICE_ID_HEADER = "X-Pass-Internal-Device-ID";
const INTERNAL_ACCOUNT_ID_HEADER = "X-Pass-Internal-Account-ID";
const INTERNAL_AUTHORIZATION_HEADER = "X-Pass-Internal-Authorization";
const INTERNAL_SCOPES_HEADER = "X-Pass-Internal-Scopes";
const INTERNAL_CREDENTIAL_EXPIRES_AT_HEADER = "X-Pass-Internal-Credential-Expires-At";
const OPEN = 1;
const TERMINAL_SUBSCRIPTION_LIFETIME_MS = 45 * 1_000;

const DEVELOPMENT_SCOPES = [
  "sessions:read",
  "sessions:write",
  "sessions:stream",
  "sessions:terminal",
  "projects:read",
  "decisions:answer",
] as const;

type RelayEnv = Env & {
  ALLOW_DEVELOPMENT_AUTH?: string;
  DEVICE_CREDENTIAL_PEPPER?: string;
  OIDC_ISSUER?: string;
  OIDC_AUDIENCE?: string;
  OIDC_JWKS_URL?: string;
};

type ConnectionAttachment = {
  version: typeof PROTOCOL_VERSION;
  desktopId: string;
  role: Role;
  deviceId: string;
  connectionId: string;
  connectedAt: number;
  accountId?: string;
  authorization?: "development" | "device";
  scopes?: string[];
  credentialExpiresAt?: number;
};

type CommandRow = {
  sequence: number;
  command_id: string;
  origin_device_id: string;
  origin_connection_id: string;
  command_type: string;
  mutating: number;
  status: string;
  received_at: number;
  acked_at: number | null;
  expires_at: number;
};

type LatestSequenceRow = {
  latest_sequence: number;
};

type TerminalSubscriptionRow = {
  subscription_id: string;
  origin_device_id: string;
  expires_at: number;
};

function jsonResponse(
  body: Record<string, unknown>,
  status = 200,
  extraHeaders?: HeadersInit,
): Response {
  const headers = new Headers(extraHeaders);
  headers.set("Content-Type", "application/json; charset=utf-8");
  headers.set("Cache-Control", "no-store");
  return Response.json(body, { status, headers });
}

function structuredLog(
  level: "info" | "warn" | "error",
  message: string,
  fields: Record<string, unknown> = {},
): void {
  const entry = JSON.stringify({
    level,
    message,
    timestamp: new Date().toISOString(),
    ...fields,
  });
  if (level === "error") {
    console.error(entry);
  } else if (level === "warn") {
    console.warn(entry);
  } else {
    console.log(entry);
  }
}

async function rateLimitKey(request: Request): Promise<string> {
  const token = extractBearerToken(request);
  if (token !== null) {
    const digest = new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)),
    );
    return `credential:${Array.from(digest.slice(0, 16), (byte) =>
      byte.toString(16).padStart(2, "0")).join("")}`;
  }
  return `anonymous:${request.headers.get("CF-Connecting-IP") ?? "unknown"}`;
}

async function enforceRateLimit(
  request: Request,
  limiter: RateLimit,
): Promise<Response | null> {
  const result = await limiter.limit({ key: await rateLimitKey(request) });
  if (result.success) return null;
  return jsonResponse(
    { error: { code: "rate_limited", message: "Too many requests. Try again shortly." } },
    429,
    { "Retry-After": "60" },
  );
}

function isConnectionAttachment(value: unknown): value is ConnectionAttachment {
  return (
    isRecord(value) &&
    value.version === PROTOCOL_VERSION &&
    isValidIdentifier(value.desktopId) &&
    isRole(value.role) &&
    isValidIdentifier(value.deviceId) &&
    isValidIdentifier(value.connectionId) &&
    typeof value.connectedAt === "number" &&
    Number.isSafeInteger(value.connectedAt) &&
    (value.accountId === undefined || isValidIdentifier(value.accountId)) &&
    (value.authorization === undefined ||
      value.authorization === "development" ||
      value.authorization === "device") &&
    (value.scopes === undefined ||
      (Array.isArray(value.scopes) &&
        value.scopes.length <= 32 &&
        value.scopes.every((scope) => typeof scope === "string" && scope.length <= 128)))
    && (value.credentialExpiresAt === undefined ||
      (typeof value.credentialExpiresAt === "number" &&
        Number.isSafeInteger(value.credentialExpiresAt)))
  );
}

function parseInternalScopes(raw: string | null): string[] | null {
  if (raw === null || raw.length > 4_096) return null;
  try {
    const value: unknown = JSON.parse(raw);
    if (
      !Array.isArray(value) ||
      value.length > 32 ||
      value.some((scope) => typeof scope !== "string" || scope.length === 0 || scope.length > 128)
    ) {
      return null;
    }
    return [...new Set(value)];
  } catch {
    return null;
  }
}

function requiredCommandScope(commandType: string): string | null {
  switch (commandType) {
    case "session.list":
      return "sessions:read";
    case "project.list":
      return "projects:read";
    case "session.create":
    case "session.sendMessage":
      return "sessions:write";
    case "session.answerDecision":
      return "decisions:answer";
    case "session.terminal.open":
    case "session.terminal.input":
    case "session.terminal.close":
      return "sessions:terminal";
    default:
      return null;
  }
}

function makeRelayEvent<
  Type extends MobileRelayMessage["type"],
  Payload,
>(type: Type, payload: Payload): {
  version: typeof PROTOCOL_VERSION;
  id: string;
  type: Type;
  sentAt: string;
  payload: Payload;
} {
  return {
    version: PROTOCOL_VERSION,
    id: crypto.randomUUID(),
    type,
    sentAt: new Date().toISOString(),
    payload,
  };
}

function makeErrorEvent(
  code: string,
  message: string,
  retryable: boolean,
  replyTo?: string,
): DesktopEvent {
  return {
    version: PROTOCOL_VERSION,
    id: crypto.randomUUID(),
    type: "error",
    sentAt: new Date().toISOString(),
    ...(replyTo === undefined ? {} : { replyTo }),
    payload: { code, message, retryable },
  };
}

function commandStatusForEvent(
  event: DesktopEvent,
): StoredCommandStatus | null {
  switch (event.type) {
    case "ack":
      return "accepted";
    case "error":
      return "rejected";
    case "message.delivered":
    case "session.snapshot":
      return "completed";
    default:
      return null;
  }
}

export class DesktopRoom extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    void this.ctx.blockConcurrencyWhile(async () => {
      this.migrateSchema();
    });
  }

  private migrateSchema(): void {
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS _relay_schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at INTEGER NOT NULL
      )
    `);

    const current = this.ctx.storage.sql
      .exec<{ version: number }>(
        "SELECT COALESCE(MAX(version), 0) AS version FROM _relay_schema_migrations",
      )
      .one().version;

    if (current < 1) {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS commands (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT,
          command_id TEXT NOT NULL UNIQUE,
          origin_device_id TEXT NOT NULL,
          origin_connection_id TEXT NOT NULL,
          command_type TEXT NOT NULL,
          mutating INTEGER NOT NULL,
          status TEXT NOT NULL,
          received_at INTEGER NOT NULL,
          acked_at INTEGER,
          expires_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS commands_device_sequence_idx
          ON commands(origin_device_id, sequence);
        CREATE INDEX IF NOT EXISTS commands_expiry_idx
          ON commands(expires_at);
      `);
      this.ctx.storage.sql.exec(
        "INSERT INTO _relay_schema_migrations (version, applied_at) VALUES (?, ?)",
        1,
        Date.now(),
      );
    }
    if (current < 2) {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS terminal_subscriptions (
          subscription_id TEXT PRIMARY KEY,
          origin_device_id TEXT NOT NULL,
          expires_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS terminal_subscriptions_expiry_idx
          ON terminal_subscriptions(expires_at);
      `);
      this.ctx.storage.sql.exec(
        "INSERT INTO _relay_schema_migrations (version, applied_at) VALUES (?, ?)",
        2,
        Date.now(),
      );
    }
  }

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const desktopId = request.headers.get(INTERNAL_DESKTOP_ID_HEADER);
    const role = request.headers.get(INTERNAL_ROLE_HEADER);
    const deviceId = request.headers.get(INTERNAL_DEVICE_ID_HEADER);
    const accountId = request.headers.get(INTERNAL_ACCOUNT_ID_HEADER);
    const authorization = request.headers.get(INTERNAL_AUTHORIZATION_HEADER);
    const scopes = parseInternalScopes(request.headers.get(INTERNAL_SCOPES_HEADER));
    const rawCredentialExpiry = request.headers.get(INTERNAL_CREDENTIAL_EXPIRES_AT_HEADER);
    const credentialExpiresAt = rawCredentialExpiry === null
      ? undefined
      : Number(rawCredentialExpiry);

    if (url.pathname === "/disconnect" && request.method === "POST") {
      if (!isValidIdentifier(desktopId)) {
        return jsonResponse({ error: "Invalid disconnect request." }, 400);
      }
      const closed = this.disconnectSockets(
        request.headers.get(INTERNAL_DEVICE_ID_HEADER),
      );
      this.broadcastPresence();
      await this.scheduleCredentialExpiry();
      return jsonResponse({ closed });
    }

    if (
      url.pathname !== "/connect" ||
      request.headers.get("Upgrade")?.toLowerCase() !== "websocket" ||
      !isValidIdentifier(desktopId) ||
      !isRole(role) ||
      !isValidIdentifier(deviceId) ||
      (accountId !== null && !isValidIdentifier(accountId)) ||
      (authorization !== "development" && authorization !== "device") ||
      scopes === null ||
      (authorization === "device" &&
        (credentialExpiresAt === undefined ||
          !Number.isSafeInteger(credentialExpiresAt) ||
          credentialExpiresAt <= Date.now()))
    ) {
      return jsonResponse({ error: "Invalid internal relay request." }, 400);
    }

    if (role === "desktop") {
      for (const existing of this.openSockets("role:desktop")) {
        existing.close(4001, "Replaced by a newer desktop connection.");
      }
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    const attachment: ConnectionAttachment = {
      version: PROTOCOL_VERSION,
      desktopId,
      role,
      deviceId,
      connectionId: crypto.randomUUID(),
      connectedAt: Date.now(),
      ...(accountId === null ? {} : { accountId }),
      authorization,
      scopes,
      ...(credentialExpiresAt === undefined ? {} : { credentialExpiresAt }),
    };

    this.ctx.acceptWebSocket(server, [
      `role:${role}`,
      `device:${deviceId}`,
      `connection:${attachment.connectionId}`,
    ]);
    server.serializeAttachment(attachment);
    await this.scheduleCredentialExpiry();

    if (role === "mobile") {
      const ready: MobileRelayMessage = makeRelayEvent("relay.ready", {
        desktopId,
        role: "mobile" as const,
        deviceId,
        connectionId: attachment.connectionId,
        latestSequence: this.latestSequence(),
        connectedAt: new Date(attachment.connectedAt).toISOString(),
      });
      this.send(server, ready);
    }
    this.broadcastPresence();

    structuredLog("info", "websocket connected", {
      desktopId,
      role,
      connectionId: attachment.connectionId,
    });

    return new Response(null, { status: 101, webSocket: client });
  }

  override async alarm(): Promise<void> {
    const now = Date.now();
    for (const socket of this.openSockets()) {
      const attachment = this.attachment(socket);
      if (
        attachment?.authorization === "device" &&
        attachment.credentialExpiresAt !== undefined &&
        attachment.credentialExpiresAt <= now
      ) {
        socket.close(4003, "Credential expired.");
      }
    }
    this.broadcastPresence();
    await this.scheduleCredentialExpiry();
  }

  override async webSocketMessage(
    socket: WebSocket,
    raw: string | ArrayBuffer,
  ): Promise<void> {
    const attachment = this.attachment(socket);
    if (attachment === null) {
      socket.close(1011, "Missing connection state.");
      return;
    }
    if (
      attachment.authorization === "device" &&
      attachment.credentialExpiresAt !== undefined &&
      attachment.credentialExpiresAt <= Date.now()
    ) {
      socket.close(4003, "Credential expired.");
      return;
    }

    if (typeof raw !== "string") {
      this.rejectProtocolInput(
        socket,
        attachment,
        "invalid_message",
        "Binary messages are not supported.",
      );
      return;
    }
    if (
      raw.length > MAX_FRAME_BYTES ||
      new TextEncoder().encode(raw).byteLength > MAX_FRAME_BYTES
    ) {
      this.rejectProtocolInput(
        socket,
        attachment,
        "message_too_large",
        "Message exceeds the relay size limit.",
      );
      socket.close(1009, "Message too large.");
      return;
    }

    const parsed = parseClientMessage(raw);
    if (!parsed.ok) {
      this.rejectProtocolInput(
        socket,
        attachment,
        parsed.code,
        parsed.message,
        parsed.refId,
      );
      return;
    }

    const parsedMessage = parsed.value;
    if (attachment.role === "mobile") {
      if (parsedMessage.kind === "resume") {
        if (!this.hasScope(attachment, "sessions:read")) {
          this.send(
            socket,
            makeErrorEvent("scope.denied", "Credential cannot resume session commands.", false, parsedMessage.message.id),
          );
          return;
        }
        this.handleResume(
          socket,
          attachment,
          parsedMessage.message.id,
          parsedMessage.message.payload.afterSequence,
        );
        return;
      }
      if (parsedMessage.kind === "ping") {
        const pong: MobileRelayMessage = makeRelayEvent("relay.pong", {
          requestId: parsedMessage.message.id,
        });
        this.send(socket, pong);
        return;
      }
      if (parsedMessage.kind === "desktopEvent") {
        this.send(
          socket,
          makeErrorEvent(
            "role.not_allowed",
            "Mobile connections cannot publish desktop events.",
            false,
            parsedMessage.message.id,
          ),
        );
        return;
      }
      this.handleMobileCommand(socket, attachment, parsedMessage.message);
      return;
    }

    if (parsedMessage.kind === "desktopEvent") {
      this.handleDesktopEvent(attachment, parsedMessage.message);
      return;
    }

    if (parsedMessage.kind === "command") {
      // Unknown unsolicited desktop event types are structurally identical to
      // forward-compatible mobile commands. The authenticated desktop role is
      // the final discriminator. handleDesktopEvent intentionally refuses to
      // broadcast unknown events without replyTo.
      this.handleDesktopEvent(attachment, parsedMessage.message);
      return;
    }

    // The desktop data plane is deliberately command-in/event-out only. Never
    // send relay control frames back: the Swift gateway would decode them as
    // commands and create an unsupported-command response loop.
    structuredLog("warn", "desktop sent unsupported relay frame", {
      desktopId: attachment.desktopId,
      connectionId: attachment.connectionId,
      type: parsedMessage.message.type,
    });
    socket.close(1008, "Desktop may only publish event envelopes.");
  }

  override async webSocketClose(
    socket: WebSocket,
    code: number,
    reason: string,
    wasClean: boolean,
  ): Promise<void> {
    const attachment = this.attachment(socket);
    structuredLog("info", "websocket closed", {
      role: attachment?.role ?? "unknown",
      desktopId: attachment?.desktopId ?? "unknown",
      connectionId: attachment?.connectionId ?? "unknown",
      code,
      reason,
      wasClean,
    });
    this.broadcastPresence();
  }

  override async webSocketError(
    socket: WebSocket,
    error: unknown,
  ): Promise<void> {
    const attachment = this.attachment(socket);
    structuredLog("error", "websocket error", {
      role: attachment?.role ?? "unknown",
      desktopId: attachment?.desktopId ?? "unknown",
      connectionId: attachment?.connectionId ?? "unknown",
      error: error instanceof Error ? error.message : String(error),
    });
    this.broadcastPresence();
  }

  private handleMobileCommand(
    mobile: WebSocket,
    attachment: ConnectionAttachment,
    command: MobileCommand,
  ): void {
    this.pruneExpiredCommands();

    const requiredScope = requiredCommandScope(command.type);
    if (
      (requiredScope === null && attachment.authorization === "device") ||
      (requiredScope !== null && !this.hasScope(attachment, requiredScope))
    ) {
      this.send(
        mobile,
        makeErrorEvent(
          "scope.denied",
          "Credential is not authorized for this command.",
          false,
          command.id,
        ),
      );
      return;
    }

    const existing = this.findCommand(command.id);
    if (existing !== null) {
      if (existing.origin_device_id !== attachment.deviceId) {
        this.send(
          mobile,
          makeErrorEvent(
            "command.id_conflict",
            "Command id was already used by another mobile device.",
            false,
            command.id,
          ),
        );
        return;
      }
      this.sendReceipt(mobile, existing, true);
      return;
    }

    const mutating = isMutatingCommand(command.type);
    const desktop = this.currentDesktop();
    if (desktop === null) {
      this.send(
        mobile,
        makeErrorEvent(
          "desktop.offline",
          mutating
            ? "Desktop is offline; mutating commands are never queued."
            : "Desktop is offline; command was not forwarded.",
          true,
          command.id,
        ),
      );
      return;
    }

    const now = Date.now();
    const inserted = this.ctx.storage.sql
      .exec<CommandRow>(
        `INSERT INTO commands (
          command_id,
          origin_device_id,
          origin_connection_id,
          command_type,
          mutating,
          status,
          received_at,
          expires_at
        ) VALUES (?, ?, ?, ?, ?, 'forwarded', ?, ?)
        RETURNING *`,
        command.id,
        attachment.deviceId,
        attachment.connectionId,
        command.type,
        mutating ? 1 : 0,
        now,
        now + commandRetentionMs(command.type),
      )
      .one();

    // Forward the original v1 envelope unchanged for exact Swift decoding.
    if (!this.send(desktop, command)) {
      this.ctx.storage.sql.exec(
        "UPDATE commands SET status = 'delivery_failed' WHERE command_id = ?",
        command.id,
      );
      this.send(
        mobile,
        makeErrorEvent(
          "desktop.offline",
          "Desktop disconnected before the command could be forwarded.",
          true,
          command.id,
        ),
      );
      return;
    }

    this.trackTerminalSubscription(command, attachment.deviceId, now);
    this.sendReceipt(mobile, inserted, false);
  }

  private handleDesktopEvent(
    attachment: ConnectionAttachment,
    event: DesktopEvent,
  ): void {
    this.pruneExpiredCommands();

    if (event.replyTo === undefined) {
      if (event.type === "session.terminal.snapshot") {
        this.routeTerminalSnapshot(event);
        return;
      }
      if (
        event.type === "session.snapshot" ||
        event.type === "session.message.started" ||
        event.type === "session.message.updated" ||
        event.type === "session.message.completed"
      ) {
        this.sendToMobiles(event);
      } else {
        structuredLog("warn", "ignored uncorrelated desktop event", {
          desktopId: attachment.desktopId,
          type: event.type,
          eventId: event.id,
        });
      }
      return;
    }

    const command = this.findCommand(event.replyTo);
    if (command === null) {
      structuredLog("warn", "desktop event references unknown command", {
        desktopId: attachment.desktopId,
        type: event.type,
        eventId: event.id,
        replyTo: event.replyTo,
      });
      return;
    }

    const status = commandStatusForEvent(event);
    const ackedAt = Date.now();
    if (status !== null) {
      this.ctx.storage.sql.exec(
        "UPDATE commands SET status = ?, acked_at = ?, expires_at = ? WHERE command_id = ?",
        status,
        ackedAt,
        ackedAt + commandRetentionMs(command.command_type),
        command.command_id,
      );
    }

    for (const mobile of this.mobileSocketsForDevice(command.origin_device_id)) {
      this.send(mobile, event);
    }
  }

  private handleResume(
    mobile: WebSocket,
    attachment: ConnectionAttachment,
    requestId: string,
    afterSequence: number,
  ): void {
    this.pruneExpiredCommands();
    const rows = this.ctx.storage.sql
      .exec<CommandRow>(
        `SELECT * FROM commands
         WHERE origin_device_id = ? AND sequence > ?
         ORDER BY sequence ASC
         LIMIT ?`,
        attachment.deviceId,
        afterSequence,
        MAX_RESUME_COMMANDS + 1,
      )
      .toArray();
    const page = rows.slice(0, MAX_RESUME_COMMANDS);
    const truncated = rows.length > MAX_RESUME_COMMANDS;
    const commands = page
      .map((row): CommandMetadata => this.commandMetadata(row));
    const pageCursor = page.at(-1)?.sequence ?? afterSequence;

    const result: MobileRelayMessage = makeRelayEvent("relay.resume.result", {
      requestId,
      commands,
      truncated,
      // Existing mobile clients already persist latestSequence as their next
      // afterSequence. Returning the page cursor avoids skipping retained rows
      // when more than MAX_RESUME_COMMANDS metadata entries are available.
      latestSequence: pageCursor,
    });
    this.send(mobile, result);
  }

  private rejectProtocolInput(
    socket: WebSocket,
    attachment: ConnectionAttachment,
    code: string,
    message: string,
    refId?: string,
  ): void {
    if (attachment.role === "mobile") {
      this.send(socket, makeErrorEvent(code, message, false, refId));
      return;
    }
    structuredLog("warn", "invalid desktop protocol frame", {
      desktopId: attachment.desktopId,
      connectionId: attachment.connectionId,
      code,
      refId,
    });
    socket.close(1008, "Invalid desktop event envelope.");
  }

  private sendReceipt(
    mobile: WebSocket,
    row: CommandRow,
    replay: boolean,
  ): void {
    const status = isStoredCommandStatus(row.status)
      ? row.status
      : "delivery_failed";
    const receipt: MobileRelayMessage = makeRelayEvent("relay.receipt", {
      commandId: row.command_id,
      sequence: row.sequence,
      status,
      replay,
    });
    this.send(mobile, receipt);
  }

  private send(
    socket: WebSocket,
    message: MobileServerMessage | MobileCommand,
  ): boolean {
    if (socket.readyState !== OPEN) return false;
    try {
      socket.send(JSON.stringify(message));
      return true;
    } catch (error) {
      structuredLog("warn", "websocket send failed", {
        error: error instanceof Error ? error.message : String(error),
      });
      return false;
    }
  }

  private broadcastPresence(): void {
    const presence: MobileRelayMessage = makeRelayEvent("desktop.presence", {
      desktopOnline: this.currentDesktop() !== null,
      mobileCount: this.openSockets("role:mobile").length,
    });
    this.sendToMobiles(presence);
  }

  private sendToMobiles(message: MobileServerMessage): number {
    let delivered = 0;
    for (const mobile of this.openSockets("role:mobile")) {
      if (this.send(mobile, message)) delivered += 1;
    }
    return delivered;
  }

  private mobileSocketsForDevice(deviceId: string): WebSocket[] {
    return this.openSockets(`device:${deviceId}`).filter(
      (socket) => this.attachment(socket)?.role === "mobile",
    );
  }

  private currentDesktop(): WebSocket | null {
    const sockets = this.openSockets("role:desktop");
    let current: { socket: WebSocket; connectedAt: number } | null = null;
    for (const socket of sockets) {
      const attachment = this.attachment(socket);
      if (
        attachment !== null &&
        (current === null || attachment.connectedAt > current.connectedAt)
      ) {
        current = { socket, connectedAt: attachment.connectedAt };
      }
    }
    return current?.socket ?? null;
  }

  private openSockets(tag?: string): WebSocket[] {
    return this.ctx
      .getWebSockets(tag)
      .filter((socket) => socket.readyState === OPEN);
  }

  private disconnectSockets(deviceId: string | null): number {
    let closed = 0;
    for (const socket of this.openSockets()) {
      const attachment = this.attachment(socket);
      if (attachment === null || (deviceId !== null && attachment.deviceId !== deviceId)) {
        continue;
      }
      socket.close(4003, "Credential revoked.");
      closed += 1;
    }
    return closed;
  }

  private async scheduleCredentialExpiry(): Promise<void> {
    const now = Date.now();
    let nextExpiry: number | null = null;
    for (const socket of this.openSockets()) {
      const expiry = this.attachment(socket)?.credentialExpiresAt;
      if (expiry === undefined || expiry <= now) continue;
      if (nextExpiry === null || expiry < nextExpiry) nextExpiry = expiry;
    }
    if (nextExpiry === null) {
      await this.ctx.storage.deleteAlarm();
    } else {
      await this.ctx.storage.setAlarm(nextExpiry);
    }
  }

  private attachment(socket: WebSocket): ConnectionAttachment | null {
    const value: unknown = socket.deserializeAttachment();
    return isConnectionAttachment(value) ? value : null;
  }

  private hasScope(attachment: ConnectionAttachment, scope: string): boolean {
    const scopes: readonly string[] = attachment.scopes ?? DEVELOPMENT_SCOPES;
    return scopes.includes(scope);
  }

  private findCommand(commandId: string): CommandRow | null {
    return (
      this.ctx.storage.sql
        .exec<CommandRow>(
          "SELECT * FROM commands WHERE command_id = ? LIMIT 1",
          commandId,
        )
        .toArray()[0] ?? null
    );
  }

  private trackTerminalSubscription(
    command: MobileCommand,
    deviceId: string,
    now: number,
  ): void {
    const subscriptionId = command.payload.subscriptionId;
    if (!isValidIdentifier(subscriptionId)) return;
    if (command.type === "session.terminal.open") {
      this.ctx.storage.sql.exec(
        `INSERT INTO terminal_subscriptions (subscription_id, origin_device_id, expires_at)
         VALUES (?, ?, ?)
         ON CONFLICT(subscription_id) DO UPDATE SET
           origin_device_id = excluded.origin_device_id,
           expires_at = excluded.expires_at`,
        subscriptionId,
        deviceId,
        now + TERMINAL_SUBSCRIPTION_LIFETIME_MS,
      );
    } else if (command.type === "session.terminal.close") {
      this.ctx.storage.sql.exec(
        "DELETE FROM terminal_subscriptions WHERE subscription_id = ? AND origin_device_id = ?",
        subscriptionId,
        deviceId,
      );
    }
  }

  private routeTerminalSnapshot(event: DesktopEvent): void {
    if (!isRecord(event.payload)) return;
    const subscriptionId = event.payload.subscriptionId;
    if (!isValidIdentifier(subscriptionId)) return;
    const subscription = this.ctx.storage.sql
      .exec<TerminalSubscriptionRow>(
        `SELECT * FROM terminal_subscriptions
         WHERE subscription_id = ? AND expires_at > ? LIMIT 1`,
        subscriptionId,
        Date.now(),
      )
      .toArray()[0];
    if (subscription === undefined) return;
    for (const mobile of this.mobileSocketsForDevice(subscription.origin_device_id)) {
      this.send(mobile, event);
    }
  }

  private latestSequence(): number {
    return this.ctx.storage.sql
      .exec<LatestSequenceRow>(
        "SELECT COALESCE(MAX(sequence), 0) AS latest_sequence FROM commands",
      )
      .one().latest_sequence;
  }

  private pruneExpiredCommands(): void {
    this.ctx.storage.sql.exec(
      "DELETE FROM commands WHERE expires_at < ?",
      Date.now(),
    );
    this.ctx.storage.sql.exec(
      "DELETE FROM terminal_subscriptions WHERE expires_at < ?",
      Date.now(),
    );
  }

  private commandMetadata(row: CommandRow): CommandMetadata {
    const status = isStoredCommandStatus(row.status)
      ? row.status
      : "delivery_failed";
    return {
      commandId: row.command_id,
      sequence: row.sequence,
      commandType: row.command_type,
      mutating: row.mutating === 1,
      status,
      receivedAt: new Date(row.received_at).toISOString(),
      ...(row.acked_at === null
        ? {}
        : { ackedAt: new Date(row.acked_at).toISOString() }),
    };
  }
}

export default {
  async fetch(request: Request, env: RelayEnv): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/health" && request.method === "GET") {
      return jsonResponse({
        ok: true,
        service: "pass-mobile-relay",
        protocolVersion: PROTOCOL_VERSION,
      });
    }
    if (url.pathname === "/connect" || url.pathname === "/v2" || url.pathname.startsWith("/v2/")) {
      const limiter = url.pathname.startsWith("/v2/pairings")
        ? env.PAIRING_RATE_LIMITER
        : env.AUTH_RATE_LIMITER;
      const limited = await enforceRateLimit(request, limiter);
      if (limited !== null) return limited;
    }
    const controlResponse = await handleControlRequest(request, env);
    if (controlResponse !== null) return controlResponse;
    if (url.pathname !== "/connect") {
      return jsonResponse({ error: "Not found." }, 404);
    }
    if (request.method !== "GET") {
      return jsonResponse(
        { error: "Method not allowed." },
        405,
        { Allow: "GET" },
      );
    }
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return jsonResponse(
        { error: "WebSocket upgrade required." },
        426,
        { Upgrade: "websocket" },
      );
    }

    const token = extractBearerToken(request);
    const protocolVersion =
      request.headers.get("X-Pass-Protocol-Version") ??
      url.searchParams.get("version");
    if (protocolVersion !== String(PROTOCOL_VERSION)) {
      return jsonResponse(
        {
          error: "Unsupported protocol version.",
          supportedVersions: [PROTOCOL_VERSION],
        },
        400,
      );
    }

    let desktopId: string;
    let roleValue: Role;
    let deviceId: string;
    let accountId: string | null = null;
    let authorization: "development" | "device";
    let scopes: readonly string[];
    let credentialExpiresAt: number | null = null;

    if (token?.startsWith("pass_at_") === true) {
      const authenticated = await authenticateDeviceCredential(request, env, "access");
      if (!authenticated.ok) {
        return jsonResponse(
          { error: authenticated.message, code: authenticated.code },
          authenticated.status,
          { "WWW-Authenticate": "Bearer" },
        );
      }
      desktopId = authenticated.value.desktopId;
      roleValue = authenticated.value.role;
      deviceId = authenticated.value.subjectId;
      accountId = authenticated.value.accountId;
      authorization = "device";
      scopes = authenticated.value.scopes;
      credentialExpiresAt = authenticated.value.expiresAt;
    } else {
      if (
        env.ALLOW_DEVELOPMENT_AUTH !== "true" ||
        env.RELAY_AUTH_TOKEN.length === 0 ||
        token === null ||
        !(await tokensMatch(token, env.RELAY_AUTH_TOKEN))
      ) {
        return jsonResponse(
          { error: "Unauthorized." },
          401,
          { "WWW-Authenticate": "Bearer" },
        );
      }
      const requestedDesktopId =
        request.headers.get("X-Pass-Desktop-ID") ??
        url.searchParams.get("desktopId");
      const requestedRole =
        request.headers.get("X-Pass-Role") ?? url.searchParams.get("role");
      if (!isValidIdentifier(requestedDesktopId) || !isRole(requestedRole)) {
        return jsonResponse({ error: "Invalid desktop id or role." }, 400);
      }
      const requestedDeviceId = requestedRole === "desktop"
        ? requestedDesktopId
        : (request.headers.get("X-Pass-Device-ID") ?? url.searchParams.get("deviceId"));
      if (!isValidIdentifier(requestedDeviceId)) {
        return jsonResponse({ error: "Mobile device id is required." }, 400);
      }
      desktopId = requestedDesktopId;
      roleValue = requestedRole;
      deviceId = requestedDeviceId;
      authorization = "development";
      scopes = DEVELOPMENT_SCOPES;
    }

    const room = env.DESKTOP_ROOMS.getByName(desktopId);
    const internalHeaders = new Headers({
      Upgrade: "websocket",
      [INTERNAL_DESKTOP_ID_HEADER]: desktopId,
      [INTERNAL_ROLE_HEADER]: roleValue,
      [INTERNAL_DEVICE_ID_HEADER]: deviceId,
      [INTERNAL_AUTHORIZATION_HEADER]: authorization,
      [INTERNAL_SCOPES_HEADER]: JSON.stringify(scopes),
    });
    if (accountId !== null) internalHeaders.set(INTERNAL_ACCOUNT_ID_HEADER, accountId);
    if (credentialExpiresAt !== null) {
      internalHeaders.set(INTERNAL_CREDENTIAL_EXPIRES_AT_HEADER, String(credentialExpiresAt));
    }
    const internalRequest = new Request("https://relay.internal/connect", {
      method: "GET",
      headers: internalHeaders,
    });

    try {
      return await room.fetch(internalRequest);
    } catch (error) {
      structuredLog("error", "durable object websocket routing failed", {
        desktopId,
        role: roleValue,
        error: error instanceof Error ? error.message : String(error),
      });
      return jsonResponse({ error: "Relay temporarily unavailable." }, 503);
    }
  },
} satisfies ExportedHandler<RelayEnv>;
