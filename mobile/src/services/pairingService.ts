import * as Crypto from "expo-crypto";

import {
  PROTOCOL_VERSION,
  type Capability,
  type DevelopmentPairingQrPayload,
  type DevicePairingQrPayload,
  type PairedDesktop,
} from "../protocol/types";

type PairingOptions = {
  deviceId?: string;
  now?: () => Date;
};

/**
 * MVP bootstrap for the relay's shared RELAY_AUTH_TOKEN mode. There is deliberately no
 * network-side registration call here: the QR/manual JSON bearer is stored in SecureStore and
 * used only in the WebSocket Authorization header. Device-key registration replaces this path
 * when the relay gains a one-time pairing API.
 */
export function createDevelopmentPairing(
  qr: DevelopmentPairingQrPayload,
  options: PairingOptions = {},
): PairedDesktop {
  return {
    protocolVersion: PROTOCOL_VERSION,
    relayUrl: qr.relayUrl,
    desktopId: qr.desktopId,
    desktopName: qr.desktopName ?? "Pass Desktop",
    ...(qr.desktopPublicKey
      ? { desktopPublicKey: qr.desktopPublicKey }
      : {}),
    deviceId: options.deviceId ?? `mobile_${Crypto.randomUUID()}`,
    credential: qr.authorizationToken,
    authenticationMode: "development",
    scopes: [
      "sessions:read",
      "sessions:write",
      "sessions:stream",
      "projects:read",
      "decisions:answer",
    ],
    pairedAt: (options.now ?? (() => new Date()))().toISOString(),
  };
}

type ClaimOptions = {
  userAccessToken: string;
  deviceName: string;
  platform: "ios" | "android";
  fetchImpl?: typeof fetch;
  now?: () => Date;
};

const CAPABILITIES = new Set<Capability>([
  "sessions:read",
  "sessions:write",
  "sessions:stream",
  "projects:read",
  "voice:use",
  "decisions:answer",
]);

export async function claimDevicePairing(
  qr: DevicePairingQrPayload,
  options: ClaimOptions,
): Promise<PairedDesktop> {
  const fetchImpl = options.fetchImpl ?? fetch;
  const response = await fetchImpl(
    `${qr.relayUrl}/v2/pairings/${encodeURIComponent(qr.pairingId)}/claim`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${options.userAccessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        pairingSecret: qr.pairingSecret,
        deviceName: options.deviceName,
        platform: options.platform,
      }),
    },
  );
  const payload: unknown = await response.json().catch(() => null);
  if (!response.ok) {
    throw new Error(apiErrorMessage(payload) ?? `Pairing failed with HTTP ${response.status}.`);
  }
  if (!isRecord(payload)) throw new Error("Pairing server returned an invalid response.");
  const device = payload.device;
  const desktop = payload.desktop;
  const credentials = payload.credentials;
  const scopes = payload.scopes;
  if (
    !isRecord(device) ||
    !isRecord(desktop) ||
    !isRecord(credentials) ||
    !isString(device.id, 200) ||
    !isString(desktop.id, 200) ||
    desktop.id !== qr.desktopId ||
    !isString(desktop.name, 200) ||
    !isString(payload.relayUrl, 2048) ||
    payload.relayUrl.replace(/\/+$/, "") !== qr.relayUrl.replace(/\/+$/, "") ||
    !isString(credentials.accessToken) ||
    !isString(credentials.accessExpiresAt, 100) ||
    !isString(credentials.refreshToken) ||
    !isString(credentials.refreshExpiresAt, 100) ||
    !Array.isArray(scopes) ||
    scopes.some((scope) => !CAPABILITIES.has(scope as Capability))
  ) {
    throw new Error("Pairing server returned incomplete device credentials.");
  }
  return {
    protocolVersion: PROTOCOL_VERSION,
    relayUrl: payload.relayUrl,
    desktopId: desktop.id,
    desktopName: desktop.name,
    deviceId: device.id,
    credential: credentials.accessToken,
    authenticationMode: "device",
    credentialExpiresAt: credentials.accessExpiresAt,
    refreshCredential: credentials.refreshToken,
    refreshExpiresAt: credentials.refreshExpiresAt,
    scopes: scopes as Capability[],
    pairedAt: (options.now ?? (() => new Date()))().toISOString(),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isString(value: unknown, maxLength = 8192): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= maxLength;
}

function apiErrorMessage(payload: unknown): string | null {
  if (!isRecord(payload) || !isRecord(payload.error)) return null;
  return isString(payload.error.message, 500) ? payload.error.message : null;
}
