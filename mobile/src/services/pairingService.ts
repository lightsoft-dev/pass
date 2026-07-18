import * as Crypto from "expo-crypto";

import {
  PROTOCOL_VERSION,
  type PairedDesktop,
  type PairingQrPayload,
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
  qr: PairingQrPayload,
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
    scopes: [
      "sessions:read",
      "sessions:write",
      "projects:read",
      "decisions:answer",
    ],
    pairedAt: (options.now ?? (() => new Date()))().toISOString(),
  };
}
