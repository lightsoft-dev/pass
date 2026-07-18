import {
  PROTOCOL_VERSION,
  type ClientCommand,
  type ClientCommandPayloadMap,
  type ClientCommandType,
} from "./types.ts";

export const COMMAND_LIMITS = {
  messageCharacters: 64 * 1_024,
  initialPromptCharacters: 64 * 1_024,
  sessionCharacters: 300,
  projectPathCharacters: 4_096,
  outboundFrameBytes: 1_024 * 1_024,
} as const;

export type CommandValidationCode =
  | "invalid_session"
  | "invalid_project"
  | "invalid_message"
  | "message_too_large"
  | "initial_prompt_too_large"
  | "outbound_frame_too_large";

export class CommandValidationError extends Error {
  readonly code: CommandValidationCode;

  constructor(code: CommandValidationCode, message: string) {
    super(message);
    this.name = "CommandValidationError";
    this.code = code;
  }
}

const graphemeSegmenter =
  typeof Intl.Segmenter === "function"
    ? new Intl.Segmenter(undefined, { granularity: "grapheme" })
    : null;

/** Counts user-visible characters like Swift's String.count when Segmenter is available. */
export function characterCount(value: string): number {
  if (graphemeSegmenter) {
    let count = 0;
    for (const _segment of graphemeSegmenter.segment(value)) count += 1;
    return count;
  }
  return Array.from(value).length;
}

/** TextEncoder-compatible UTF-8 byte count without requiring a browser global. */
export function utf8ByteLength(value: string): number {
  let bytes = 0;
  for (const character of value) {
    const codePoint = character.codePointAt(0) ?? 0;
    if (codePoint <= 0x7f) bytes += 1;
    else if (codePoint <= 0x7ff) bytes += 2;
    else if (codePoint <= 0xffff) bytes += 3;
    else bytes += 4;
  }
  return bytes;
}

function requireSession(session: string): void {
  const normalized = session.trim();
  if (!normalized) {
    throw new CommandValidationError(
      "invalid_session",
      "Session name is required.",
    );
  }
  if (characterCount(normalized) > COMMAND_LIMITS.sessionCharacters) {
    throw new CommandValidationError(
      "invalid_session",
      `Session name must be ${COMMAND_LIMITS.sessionCharacters} characters or fewer.`,
    );
  }
}

/** Mirrors the desktop command-handler limits before a frame reaches the relay. */
export function validateCommand(command: ClientCommand): void {
  switch (command.type) {
    case "session.create": {
      const root = command.payload.projectRoot.trim();
      if (!root) {
        throw new CommandValidationError(
          "invalid_project",
          "Project root is required.",
        );
      }
      if (characterCount(root) > COMMAND_LIMITS.projectPathCharacters) {
        throw new CommandValidationError(
          "invalid_project",
          `Project root must be ${COMMAND_LIMITS.projectPathCharacters.toLocaleString("en-US")} characters or fewer.`,
        );
      }
      if (
        command.payload.initialPrompt !== undefined &&
        characterCount(command.payload.initialPrompt) >
          COMMAND_LIMITS.initialPromptCharacters
      ) {
        throw new CommandValidationError(
          "initial_prompt_too_large",
          `Initial prompt must be ${COMMAND_LIMITS.initialPromptCharacters.toLocaleString("en-US")} characters or fewer.`,
        );
      }
      return;
    }
    case "session.sendMessage":
      requireSession(command.payload.session);
      if (!command.payload.text.trim()) {
        throw new CommandValidationError(
          "invalid_message",
          "Message text is required.",
        );
      }
      if (characterCount(command.payload.text) > COMMAND_LIMITS.messageCharacters) {
        throw new CommandValidationError(
          "message_too_large",
          `Message must be ${COMMAND_LIMITS.messageCharacters.toLocaleString("en-US")} characters or fewer.`,
        );
      }
      return;
    case "session.answerDecision":
      requireSession(command.payload.session);
      return;
    case "relay.resume":
    case "relay.ping":
    case "session.list":
    case "project.list":
      return;
  }
}

/** Serializes only frames that fit the relay's complete UTF-8 frame limit. */
export function encodeCommand(
  command: ClientCommand,
  maximumBytes: number = COMMAND_LIMITS.outboundFrameBytes,
): string {
  const encoded = JSON.stringify(command);
  const byteLength = utf8ByteLength(encoded);
  if (byteLength > maximumBytes) {
    throw new CommandValidationError(
      "outbound_frame_too_large",
      `Command frame is ${byteLength.toLocaleString("en-US")} UTF-8 bytes; the relay limit is ${maximumBytes.toLocaleString("en-US")} bytes.`,
    );
  }
  return encoded;
}

function secureUuid(): string {
  const randomUuid = globalThis.crypto?.randomUUID;
  if (randomUuid) return randomUuid.call(globalThis.crypto);
  throw new Error("A cryptographically secure UUID factory is required.");
}

export function createProtocolId(
  prefix: "cmd" | "evt" | "dev" = "cmd",
  uuidFactory: () => string = secureUuid,
): string {
  return `${prefix}_${uuidFactory()}`;
}

export function createCommand<K extends ClientCommandType>(
  type: K,
  payload: ClientCommandPayloadMap[K],
  options: { id?: string; now?: () => Date; uuidFactory?: () => string } = {},
): ClientCommand<K> {
  return {
    version: PROTOCOL_VERSION,
    id: options.id ?? createProtocolId("cmd", options.uuidFactory ?? secureUuid),
    type,
    sentAt: (options.now ?? (() => new Date()))().toISOString(),
    payload,
  } as ClientCommand<K>;
}
