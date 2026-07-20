import {
  PROTOCOL_VERSION,
  type PairingQrPayload,
} from "./types.ts";

export type PairingParseResult =
  | { ok: true; value: PairingQrPayload }
  | { ok: false; error: string };

type PairingParseOptions = {
  allowInsecureDevelopment?: boolean;
  now?: () => Date;
};
const IDENTIFIER_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;

function nonEmpty(value: unknown, maxLength = 4096): value is string {
  return (
    typeof value === "string" &&
    value.trim().length > 0 &&
    value.length <= maxLength
  );
}

function normalizeRelayUrl(
  raw: string,
  allowInsecureDevelopment: boolean,
): string | null {
  try {
    const url = new URL(raw);
    const validProtocol =
      url.protocol === "https:" ||
      (allowInsecureDevelopment && url.protocol === "http:");
    if (!validProtocol || !url.hostname || url.username || url.password) return null;

    url.search = "";
    url.hash = "";
    url.pathname = url.pathname.replace(/\/+$/, "");
    return url.toString().replace(/\/$/, "");
  } catch {
    return null;
  }
}

function fromUrl(input: string): Record<string, unknown> | null {
  try {
    const url = new URL(input);
    if (
      !["pass:", "passremote:"].includes(url.protocol) ||
      (url.hostname !== "pair" && url.pathname !== "/pair")
    ) {
      return null;
    }
    return {
      v: Number(url.searchParams.get("v")),
      relayUrl: url.searchParams.get("relay"),
      desktopId: url.searchParams.get("desktopId"),
      authorizationToken:
        url.searchParams.get("authorizationToken") ?? url.searchParams.get("token"),
      pairingId: url.searchParams.get("pairingId"),
      pairingSecret: url.searchParams.get("pairingSecret") ?? url.searchParams.get("code"),
      expiresAt: url.searchParams.get("expiresAt"),
      desktopName: url.searchParams.get("desktopName") ?? undefined,
      desktopPublicKey: url.searchParams.get("publicKey") ?? undefined,
    };
  } catch {
    return null;
  }
}

export function parsePairingPayload(
  input: string,
  options: PairingParseOptions = {},
): PairingParseResult {
  const trimmed = input.trim();
  if (!trimmed || trimmed.length > 16_384) {
    return { ok: false, error: "Pairing code is empty or too large." };
  }

  let candidate: unknown = fromUrl(trimmed);
  if (!candidate) {
    try {
      candidate = JSON.parse(trimmed) as unknown;
    } catch {
      return { ok: false, error: "This is not a Pass pairing QR payload." };
    }
  }

  if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) {
    return { ok: false, error: "Pairing payload must be an object." };
  }

  const value = candidate as Record<string, unknown>;
  if (value.v !== PROTOCOL_VERSION && value.v !== 2) {
    return {
      ok: false,
      error: "Unsupported pairing version. Expected v1 or v2.",
    };
  }
  if (!nonEmpty(value.relayUrl, 2048)) {
    return { ok: false, error: "Pairing payload has no relay URL." };
  }
  const relayUrl = normalizeRelayUrl(
    value.relayUrl,
    options.allowInsecureDevelopment === true,
  );
  if (!relayUrl) {
    return {
      ok: false,
      error: "Relay URL must use HTTPS (HTTP is allowed only in development).",
    };
  }
  if (!nonEmpty(value.desktopId, 200)) {
    return { ok: false, error: "Pairing payload is missing a desktop id." };
  }
  if (!IDENTIFIER_PATTERN.test(value.desktopId.trim())) {
    return { ok: false, error: "Desktop id contains unsupported characters." };
  }
  if (value.v === 2) {
    if (
      !nonEmpty(value.pairingId, 200) ||
      !IDENTIFIER_PATTERN.test(value.pairingId.trim()) ||
      !nonEmpty(value.pairingSecret, 256) ||
      !nonEmpty(value.expiresAt, 100)
    ) {
      return { ok: false, error: "Pairing payload is missing a valid one-time code." };
    }
    const expiresAt = new Date(value.expiresAt);
    if (!Number.isFinite(expiresAt.getTime())) {
      return { ok: false, error: "Pairing code has an invalid expiration time." };
    }
    if (expiresAt.getTime() <= (options.now ?? (() => new Date()))().getTime()) {
      return { ok: false, error: "Pairing code has expired. Generate a new code on the Mac." };
    }
    return {
      ok: true,
      value: {
        v: 2,
        relayUrl,
        desktopId: value.desktopId.trim(),
        pairingId: value.pairingId.trim(),
        pairingSecret: value.pairingSecret.trim(),
        expiresAt: expiresAt.toISOString(),
      },
    };
  }

  const authorizationToken = value.authorizationToken ?? value.pairingToken;
  if (!nonEmpty(authorizationToken, 8192)) {
    return { ok: false, error: "Development pairing payload is missing a token." };
  }
  if (value.desktopName !== undefined && !nonEmpty(value.desktopName, 200)) {
    return { ok: false, error: "Desktop name is invalid." };
  }
  if (value.desktopPublicKey !== undefined && !nonEmpty(value.desktopPublicKey, 8192)) {
    return { ok: false, error: "Desktop public key is invalid." };
  }

  return {
    ok: true,
    value: {
      v: PROTOCOL_VERSION,
      relayUrl,
      desktopId: value.desktopId.trim(),
      authorizationToken: authorizationToken.trim(),
      ...(typeof value.desktopName === "string"
        ? { desktopName: value.desktopName.trim() }
        : {}),
      ...(typeof value.desktopPublicKey === "string"
        ? { desktopPublicKey: value.desktopPublicKey }
        : {}),
    },
  };
}
