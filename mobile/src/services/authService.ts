import {
  fetchDiscoveryAsync,
  refreshAsync,
  type TokenResponse,
} from "expo-auth-session";

import type { UserSession } from "../protocol/types";

export type PublicOIDCConfiguration = {
  issuer: string;
  clientId: string;
  audience?: string;
};

export function publicOIDCConfiguration(): PublicOIDCConfiguration | null {
  const issuer = process.env.EXPO_PUBLIC_PASS_OIDC_ISSUER?.replace(/\/+$/, "");
  const clientId = process.env.EXPO_PUBLIC_PASS_OIDC_CLIENT_ID?.trim();
  const audience = process.env.EXPO_PUBLIC_PASS_OIDC_AUDIENCE?.trim();
  if (!issuer || !clientId) return null;
  return { issuer, clientId, ...(audience ? { audience } : {}) };
}

export function userSessionFromTokenResponse(
  configuration: PublicOIDCConfiguration,
  response: TokenResponse,
): UserSession {
  const issuedAt = response.issuedAt * 1_000;
  const expiresAt = issuedAt + (response.expiresIn ?? 300) * 1_000;
  return {
    issuer: configuration.issuer,
    clientId: configuration.clientId,
    accessToken: response.accessToken,
    accessExpiresAt: new Date(expiresAt).toISOString(),
    ...(response.refreshToken ? { refreshToken: response.refreshToken } : {}),
  };
}

export function isUserSessionFresh(
  session: UserSession,
  now = Date.now(),
  marginMilliseconds = 60_000,
): boolean {
  const expiresAt = new Date(session.accessExpiresAt).getTime();
  return Number.isFinite(expiresAt) && expiresAt > now + marginMilliseconds;
}

export async function refreshUserSession(session: UserSession): Promise<UserSession> {
  if (!session.refreshToken) throw new Error("Sign in again to continue.");
  const discovery = await fetchDiscoveryAsync(session.issuer);
  const response = await refreshAsync(
    {
      clientId: session.clientId,
      refreshToken: session.refreshToken,
      scopes: ["openid", "profile", "email", "offline_access"],
    },
    discovery,
  );
  const refreshed = userSessionFromTokenResponse(
    { issuer: session.issuer, clientId: session.clientId },
    response,
  );
  return {
    ...refreshed,
    refreshToken: response.refreshToken ?? session.refreshToken,
  };
}
