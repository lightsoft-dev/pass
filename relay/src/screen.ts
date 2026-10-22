import { isRecord } from "./protocol";

export const SCREEN_PENDING_MS = 60_000;
export const SCREEN_ACTIVE_MS = 15 * 60_000;

export type IceServer = {
  urls: string | string[];
  username?: string;
  credential?: string;
};

export type ScreenTurnEnv = {
  TURN_KEY_ID?: string;
  TURN_KEY_API_TOKEN?: string;
};

function validIceServer(value: unknown): value is IceServer {
  if (!isRecord(value)) return false;
  const urls = typeof value.urls === "string" ? [value.urls] : value.urls;
  if (
    !Array.isArray(urls) || urls.length === 0 || urls.length > 16 ||
    !urls.every((url) => typeof url === "string" &&
      url.length < 256 && /^(?:stun|turn|turns):[^\s]+$/.test(url))
  ) return false;
  if (value.username !== undefined &&
    (typeof value.username !== "string" || value.username.length > 512)) return false;
  if (value.credential !== undefined &&
    (typeof value.credential !== "string" || value.credential.length > 512)) return false;
  if (urls.some((url) => url.startsWith("turn")) &&
    (typeof value.username !== "string" || typeof value.credential !== "string")) return false;
  return true;
}

/** Create per-peer, short-lived TURN credentials only after the host approves a screen session. */
export async function generateScreenIceServers(
  env: ScreenTurnEnv,
  request: typeof fetch = fetch,
): Promise<IceServer[]> {
  const keyId = env.TURN_KEY_ID;
  const apiToken = env.TURN_KEY_API_TOKEN;
  if (!keyId && !apiToken) {
    return [{ urls: "stun:stun.cloudflare.com:3478" }];
  }
  if (!keyId || !apiToken || !/^[A-Za-z0-9_-]{1,128}$/.test(keyId)) {
    throw new Error("Incomplete TURN configuration.");
  }

  const response = await request(
    `https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/generate-ice-servers`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ ttl: Math.ceil(SCREEN_ACTIVE_MS / 1_000) + 60 }),
      signal: AbortSignal.timeout(8_000),
    },
  );
  if (response.status !== 201) throw new Error("TURN credential generation failed.");
  const value: unknown = await response.json();
  if (!isRecord(value) || !Array.isArray(value.iceServers) ||
    value.iceServers.length === 0 || value.iceServers.length > 8 ||
    !value.iceServers.every(validIceServer)) {
    throw new Error("TURN provider returned invalid ICE servers.");
  }
  return value.iceServers;
}

export function validScreenSdp(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 256 * 1_024;
}

export function validScreenCandidate(value: unknown): value is Record<string, unknown> {
  if (!isRecord(value)) return false;
  return typeof value.candidate === "string" && value.candidate.length <= 4_096 &&
    (value.sdpMid === null || value.sdpMid === undefined ||
      (typeof value.sdpMid === "string" && value.sdpMid.length <= 256)) &&
    (value.sdpMLineIndex === null || value.sdpMLineIndex === undefined ||
      (Number.isSafeInteger(value.sdpMLineIndex) &&
        (value.sdpMLineIndex as number) >= 0 && (value.sdpMLineIndex as number) <= 65_535)) &&
    (value.usernameFragment === undefined ||
      (typeof value.usernameFragment === "string" && value.usernameFragment.length <= 256));
}
