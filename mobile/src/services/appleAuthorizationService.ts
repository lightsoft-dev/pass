import type { UserSession } from "../protocol/types.ts";
import {
  APPLE_NATIVE_CLIENT_ID,
  type AppleCredentialLike,
  userSessionFromAppleCredential,
} from "./identitySession.ts";

export type AppleAuthorizationCredentialLike = AppleCredentialLike & {
  authorizationCode: string | null;
};

/**
 * Ephemeral proof sent directly to the Relay. Only `session` may be persisted; the one-time
 * authorization code and request nonce must never be written to SecureStore.
 */
export type AppleAuthorization = {
  session: UserSession;
  authorizationCode: string;
  nonce: string;
};

export function appleAuthorizationFromCredential(
  credential: AppleAuthorizationCredentialLike,
  nonce: string,
  options: {
    clientId?: string;
    expectedUserId?: string;
    now?: number;
  } = {},
): AppleAuthorization {
  const authorizationCode = credential.authorizationCode;
  if (!authorizationCode || authorizationCode.length > 4_096) {
    throw new Error(
      "Apple did not return a one-time authorization code. Please try Sign in with Apple again.",
    );
  }
  if (!nonce || nonce.length > 512) {
    throw new Error("Could not start secure Sign in with Apple. Please try again.");
  }

  const session = userSessionFromAppleCredential(
    credential,
    options.clientId ?? APPLE_NATIVE_CLIENT_ID,
    options.now,
  );
  if (
    options.expectedUserId !== undefined
    && session.providerUserId !== options.expectedUserId
  ) {
    throw new Error(
      "Apple returned a different account. Use the Apple ID currently signed in to Pass.",
    );
  }

  return { session, authorizationCode, nonce };
}

export function requireSecureAppleRelayURL(relayUrl: string | undefined): string {
  const normalized = relayUrl?.trim().replace(/\/+$/, "");
  if (!normalized) {
    throw new Error("This build has no production Pass Relay configured for Apple sign-in.");
  }
  let parsed: URL;
  try {
    parsed = new URL(normalized);
  } catch {
    throw new Error("This build has an invalid Pass Relay URL for Apple sign-in.");
  }
  if (parsed.protocol !== "https:") {
    throw new Error("Sign in with Apple requires a secure HTTPS Pass Relay.");
  }
  return normalized;
}

export async function registerAppleAuthorization(
  relayUrl: string,
  authorization: AppleAuthorization,
  fetchImpl: typeof fetch = fetch,
): Promise<void> {
  const secureRelayUrl = requireSecureAppleRelayURL(relayUrl);
  let response: Response;
  try {
    response = await fetchImpl(`${secureRelayUrl}/v2/apple/authorization`, {
      method: "POST",
      redirect: "error",
      headers: {
        Authorization: `Bearer ${authorization.session.accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        authorizationCode: authorization.authorizationCode,
        nonce: authorization.nonce,
      }),
    });
  } catch {
    throw new Error(
      "Could not reach the Pass Relay. Check your connection and try Sign in with Apple again.",
    );
  }

  const payload: unknown = await response.json().catch(() => null);
  if (!response.ok) {
    throw new Error(
      apiErrorMessage(payload)
        ?? `Apple authorization registration failed with HTTP ${response.status}. Sign in with Apple again.`,
    );
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function apiErrorMessage(payload: unknown): string | null {
  if (!isRecord(payload) || !isRecord(payload.error)) return null;
  const message = payload.error.message;
  return typeof message === "string" && message.length > 0 && message.length <= 500
    ? message
    : null;
}
