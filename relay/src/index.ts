import { DurableObject } from "cloudflare:workers";

import {
  COMMAND_RETENTION_MS,
  MAX_FRAME_BYTES,
  MAX_RESUME_COMMANDS,
  PROTOCOL_VERSION,
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
const OPEN = 1;

type ConnectionAttachment = {
  version: typeof PROTOCOL_VERSION;
  desktopId: string;
  role: Role;
  deviceId: string;
  connectionId: string;
  connectedAt: number;
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

function extractBearerToken(request: Request): string | null {
  const authorization = request.headers.get("Authorization");
  if (authorization === null || authorization.length > 4_096) return null;
  const match = /^Bearer ([^\s]+)$/.exec(authorization);
  return match?.[1] ?? null;
}

async function tokensMatch(provided: string, expected: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [providedHash, expectedHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(provided)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  // SHA-256 gives fixed-length inputs. Compare every byte without an early
  // return so token content does not affect comparison work.
  const providedBytes = new Uint8Array(providedHash);
  const expectedBytes = new Uint8Array(expectedHash);
  let difference = 0;
  for (let index = 0; index < providedBytes.length; index += 1) {
    difference |=
      (providedBytes.at(index) ?? 0) ^ (expectedBytes.at(index) ?? 0);
  }
  return difference === 0;
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
    Number.isSafeInteger(value.connectedAt)
  );
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
  }

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const desktopId = request.headers.get(INTERNAL_DESKTOP_ID_HEADER);
    const role = request.headers.get(INTERNAL_ROLE_HEADER);
    const deviceId = request.headers.get(INTERNAL_DEVICE_ID_HEADER);

    if (
      url.pathname !== "/connect" ||
      request.headers.get("Upgrade")?.toLowerCase() !== "websocket" ||
      !isValidIdentifier(desktopId) ||
      !isRole(role) ||
      !isValidIdentifier(deviceId)
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
    };

    this.ctx.acceptWebSocket(server, [
      `role:${role}`,
      `device:${deviceId}`,
      `connection:${attachment.connectionId}`,
    ]);
    server.serializeAttachment(attachment);

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

  override async webSocketMessage(
    socket: WebSocket,
    raw: string | ArrayBuffer,
  ): Promise<void> {
    const attachment = this.attachment(socket);
    if (attachment === null) {
      socket.close(1011, "Missing connection state.");
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
        now + COMMAND_RETENTION_MS,
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

    this.sendReceipt(mobile, inserted, false);
  }

  private handleDesktopEvent(
    attachment: ConnectionAttachment,
    event: DesktopEvent,
  ): void {
    this.pruneExpiredCommands();

    if (event.replyTo === undefined) {
      if (event.type === "session.snapshot") {
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
        ackedAt + COMMAND_RETENTION_MS,
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

  private attachment(socket: WebSocket): ConnectionAttachment | null {
    const value: unknown = socket.deserializeAttachment();
    return isConnectionAttachment(value) ? value : null;
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
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/health" && request.method === "GET") {
      return jsonResponse({
        ok: true,
        service: "pass-mobile-relay",
        protocolVersion: PROTOCOL_VERSION,
      });
    }
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

    if (env.RELAY_AUTH_TOKEN.length === 0) {
      structuredLog("error", "required relay auth secret is empty");
      return jsonResponse({ error: "Relay authentication is unavailable." }, 500);
    }
    const token = extractBearerToken(request);
    if (token === null || !(await tokensMatch(token, env.RELAY_AUTH_TOKEN))) {
      return jsonResponse(
        { error: "Unauthorized." },
        401,
        { "WWW-Authenticate": "Bearer" },
      );
    }

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

    const desktopId =
      request.headers.get("X-Pass-Desktop-ID") ??
      url.searchParams.get("desktopId");
    const roleValue =
      request.headers.get("X-Pass-Role") ?? url.searchParams.get("role");
    if (!isValidIdentifier(desktopId) || !isRole(roleValue)) {
      return jsonResponse({ error: "Invalid desktop id or role." }, 400);
    }

    const deviceId =
      roleValue === "desktop"
        ? desktopId
        : (request.headers.get("X-Pass-Device-ID") ??
          url.searchParams.get("deviceId"));
    if (!isValidIdentifier(deviceId)) {
      return jsonResponse({ error: "Mobile device id is required." }, 400);
    }

    const room = env.DESKTOP_ROOMS.getByName(desktopId);
    const internalRequest = new Request("https://relay.internal/connect", {
      method: "GET",
      headers: {
        Upgrade: "websocket",
        [INTERNAL_DESKTOP_ID_HEADER]: desktopId,
        [INTERNAL_ROLE_HEADER]: roleValue,
        [INTERNAL_DEVICE_ID_HEADER]: deviceId,
      },
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
} satisfies ExportedHandler<Env>;
