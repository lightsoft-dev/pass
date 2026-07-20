import type { PairedDesktop } from "../protocol/types";

export function shouldRefreshDeviceCredential(
  pairing: PairedDesktop,
  now = Date.now(),
  marginMilliseconds = 60_000,
): boolean {
  if (pairing.authenticationMode !== "device") return false;
  const expiresAt = new Date(pairing.credentialExpiresAt ?? "").getTime();
  return !Number.isFinite(expiresAt) || expiresAt <= now + marginMilliseconds;
}

export async function refreshDeviceCredential(
  pairing: PairedDesktop,
  fetchImpl: typeof fetch = fetch,
): Promise<PairedDesktop> {
  if (pairing.authenticationMode !== "device" || !pairing.refreshCredential) {
    throw new Error("This desktop does not have a renewable device credential.");
  }
  const response = await fetchImpl(`${pairing.relayUrl}/v2/token/refresh`, {
    method: "POST",
    headers: { Authorization: `Bearer ${pairing.refreshCredential}` },
  });
  const payload: unknown = await response.json().catch(() => null);
  if (!response.ok) {
    throw new Error(apiErrorMessage(payload) ?? `Credential refresh failed with HTTP ${response.status}.`);
  }
  if (!isRecord(payload) || !isRecord(payload.credentials)) {
    throw new Error("Credential server returned an invalid response.");
  }
  const credentials = payload.credentials;
  if (
    !isString(credentials.accessToken) ||
    !isString(credentials.accessExpiresAt, 100) ||
    !isString(credentials.refreshToken) ||
    !isString(credentials.refreshExpiresAt, 100)
  ) {
    throw new Error("Credential server returned incomplete credentials.");
  }
  return {
    ...pairing,
    credential: credentials.accessToken,
    credentialExpiresAt: credentials.accessExpiresAt,
    refreshCredential: credentials.refreshToken,
    refreshExpiresAt: credentials.refreshExpiresAt,
  };
}

export async function revokeDevice(
  pairing: PairedDesktop,
  userAccessToken: string,
  fetchImpl: typeof fetch = fetch,
): Promise<void> {
  if (pairing.authenticationMode !== "device") return;
  const response = await fetchImpl(
    `${pairing.relayUrl}/v2/devices/${encodeURIComponent(pairing.deviceId)}`,
    {
      method: "DELETE",
      headers: { Authorization: `Bearer ${userAccessToken}` },
    },
  );
  if (response.ok || response.status === 404) return;
  const payload: unknown = await response.json().catch(() => null);
  throw new Error(apiErrorMessage(payload) ?? `Device revocation failed with HTTP ${response.status}.`);
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
