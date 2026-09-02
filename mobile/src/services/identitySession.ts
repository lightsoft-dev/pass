import type { UserSession } from "../protocol/types";

export const GOOGLE_ISSUER = "https://accounts.google.com";
export const APPLE_ISSUER = "https://appleid.apple.com";
// Sign in with Apple uses the native app's bundle identifier as the ID-token audience.
// Keep this synchronized with expo.ios.bundleIdentifier in app.json.
export const APPLE_NATIVE_CLIENT_ID = "dev.lightsoft.passmobile";

export type IdentityProvider = "google" | "apple";

export type AppleCredentialLike = {
  user: string;
  identityToken: string | null;
};

type IdentityTokenClaims = {
  iss?: unknown;
  aud?: unknown;
  sub?: unknown;
  exp?: unknown;
};

export function identityProviderForSession(session: UserSession): IdentityProvider {
  const issuer = session.issuer.replace(/\/+$/, "");
  if (issuer === APPLE_ISSUER) return "apple";
  if (issuer === GOOGLE_ISSUER) return "google";
  throw new Error("This sign-in provider is no longer supported.");
}

export function userSessionFromAppleCredential(
  credential: AppleCredentialLike,
  clientId = APPLE_NATIVE_CLIENT_ID,
  now = Date.now(),
): UserSession {
  const token = credential.identityToken;
  if (!token) throw new Error("Apple did not return an identity token.");
  const claims = decodeIdentityToken(token);
  if (claims.iss !== APPLE_ISSUER) {
    throw new Error("Apple returned an identity token with an unexpected issuer.");
  }
  const audiences = typeof claims.aud === "string"
    ? [claims.aud]
    : Array.isArray(claims.aud) && claims.aud.every((value) => typeof value === "string")
      ? claims.aud
      : [];
  if (!audiences.includes(clientId)) {
    throw new Error("Apple returned an identity token for a different app.");
  }
  if (claims.sub !== credential.user || !boundedSubject(claims.sub)) {
    throw new Error("Apple returned an identity token for a different user.");
  }
  if (typeof claims.exp !== "number" || !Number.isFinite(claims.exp) || claims.exp * 1_000 <= now) {
    throw new Error("Apple returned an expired identity token.");
  }
  return {
    issuer: APPLE_ISSUER,
    clientId,
    accessToken: token,
    accessExpiresAt: new Date(claims.exp * 1_000).toISOString(),
    identityProvider: "apple",
    providerUserId: credential.user,
  };
}

export function identityTokenExpiry(
  token: string,
  fallbackNow = Date.now(),
): Date {
  try {
    const claims = decodeIdentityToken(token);
    if (typeof claims.exp === "number" && Number.isFinite(claims.exp)) {
      return new Date(claims.exp * 1_000);
    }
  } catch {
    // The relay performs cryptographic verification. This conservative client fallback merely
    // ensures an unparseable token is refreshed quickly instead of being treated as long-lived.
  }
  return new Date(fallbackNow + 5 * 60_000);
}

export function identityTokenSubject(token: string): string {
  const subject = decodeIdentityToken(token).sub;
  if (!boundedSubject(subject)) throw new Error("The saved identity token has no valid user id.");
  return subject;
}

export function shouldShowAppleSignIn(platform: string, available: boolean): boolean {
  return platform === "ios" && available;
}

export function assertMatchingAppleState(expected: string, received: string | null): void {
  if (!received || received !== expected) {
    throw new Error("Apple sign-in response state did not match the request.");
  }
}

export function isAppleRequestCanceled(error: unknown): boolean {
  return (
    typeof error === "object"
    && error !== null
    && "code" in error
    && (error as { code?: unknown }).code === "ERR_REQUEST_CANCELED"
  );
}

function decodeIdentityToken(token: string): IdentityTokenClaims {
  const payload = token.split(".")[1];
  if (!payload) throw new Error("Identity token is missing its JWT payload.");
  const normalized = payload.replaceAll("-", "+").replaceAll("_", "/");
  const decoded = globalThis.atob(
    normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "="),
  );
  const value: unknown = JSON.parse(decoded);
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("Identity token payload is invalid.");
  }
  return value as IdentityTokenClaims;
}

function boundedSubject(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 512;
}
