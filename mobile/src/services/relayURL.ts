import type { PairedDesktop } from "../protocol/types.ts";

export type RelayURLPolicy = {
  allowInsecureDevelopment?: boolean;
};

export function normalizeRelayBaseURL(
  raw: string | undefined,
  policy: RelayURLPolicy = {},
): string | null {
  if (!raw?.trim()) return null;
  try {
    const url = new URL(raw.trim());
    const validProtocol =
      url.protocol === "https:"
      || (policy.allowInsecureDevelopment === true && url.protocol === "http:");
    if (!validProtocol || !url.hostname || url.username || url.password) return null;

    url.search = "";
    url.hash = "";
    url.pathname = url.pathname.replace(/\/+$/, "");
    return url.toString().replace(/\/$/, "");
  } catch {
    return null;
  }
}

export function requireConfiguredRelayURL(
  configuredRelayURL: string | undefined,
  policy: RelayURLPolicy = {},
): string {
  const normalized = normalizeRelayBaseURL(configuredRelayURL, policy);
  if (!normalized) {
    throw new Error(
      policy.allowInsecureDevelopment
        ? "This build has no valid Pass Relay configured."
        : "This production build has no valid HTTPS Pass Relay configured.",
    );
  }
  return normalized;
}

export function requirePinnedRelayURL(
  candidateRelayURL: string,
  configuredRelayURL: string | undefined,
  policy: RelayURLPolicy = {},
): string {
  const configured = requireConfiguredRelayURL(configuredRelayURL, policy);
  const candidate = normalizeRelayBaseURL(candidateRelayURL, policy);
  if (!candidate || candidate !== configured) {
    throw new Error("This pairing code uses an untrusted Pass Relay.");
  }
  return configured;
}

/** Account and provider-authorization requests never derive their origin from paired device data. */
export function resolveAccountRelayURL(
  configuredRelayURL: string | undefined,
  policy: RelayURLPolicy = {},
): string {
  return requireConfiguredRelayURL(configuredRelayURL, policy);
}

export function pinStoredPairingForProduction(
  pairing: PairedDesktop,
  configuredRelayURL: string | undefined,
): PairedDesktop {
  return {
    ...pairing,
    relayUrl: requirePinnedRelayURL(pairing.relayUrl, configuredRelayURL),
  };
}
