import {
  GoogleSignin,
  type User,
} from "@react-native-google-signin/google-signin";
import * as AppleAuthentication from "expo-apple-authentication";
import * as Crypto from "expo-crypto";
import { Platform } from "react-native";

import type { UserSession } from "../protocol/types";
import {
  appleAuthorizationFromCredential,
  type AppleAuthorization,
} from "./appleAuthorizationService";
import {
  APPLE_NATIVE_CLIENT_ID,
  GOOGLE_ISSUER,
  assertMatchingAppleState,
  identityProviderForSession,
  identityTokenExpiry,
  identityTokenSubject,
  userSessionFromAppleCredential,
} from "./identitySession";

export type PublicOIDCConfiguration = {
  issuer: string;
  clientId: string;
  iosClientId?: string;
};

export function publicOIDCConfiguration(): PublicOIDCConfiguration | null {
  const clientId = (
    process.env.EXPO_PUBLIC_PASS_GOOGLE_WEB_CLIENT_ID
      ?? process.env.EXPO_PUBLIC_PASS_OIDC_CLIENT_ID
  )?.trim();
  const iosClientId = process.env.EXPO_PUBLIC_PASS_GOOGLE_IOS_CLIENT_ID?.trim();
  if (!clientId) return null;
  return {
    issuer: GOOGLE_ISSUER,
    clientId,
    ...(iosClientId ? { iosClientId } : {}),
  };
}

export function configureGoogleSignIn(configuration: PublicOIDCConfiguration): void {
  GoogleSignin.configure({
    webClientId: configuration.clientId,
    offlineAccess: false,
    ...(configuration.iosClientId ? { iosClientId: configuration.iosClientId } : {}),
  });
}

export function userSessionFromGoogleUser(
  configuration: PublicOIDCConfiguration,
  user: User,
): UserSession {
  if (!user.idToken) throw new Error("Google did not return an identity token.");
  return {
    issuer: configuration.issuer,
    clientId: configuration.clientId,
    // The relay verifies a signed OIDC JWT. Google's API access token is opaque, so this
    // existing storage/wire field intentionally contains the Google ID token instead.
    accessToken: user.idToken,
    accessExpiresAt: identityTokenExpiry(user.idToken).toISOString(),
    identityProvider: "google",
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

export async function requestInitialAppleAuthorization(): Promise<AppleAuthorization> {
  return requestAppleAuthorization({
    clientId: APPLE_NATIVE_CLIENT_ID,
    requestProfile: true,
  });
}

export async function requestAppleDeletionAuthorization(
  session: UserSession,
): Promise<AppleAuthorization> {
  if (identityProviderForSession(session) !== "apple") {
    throw new Error("This account is not signed in with Apple.");
  }
  const expectedUserId =
    session.providerUserId ?? identityTokenSubject(session.accessToken);
  // TN3194 deletion preparation needs a new authorization code tied to a fresh nonce. Use a
  // user-initiated LOGIN request with no profile scopes; refreshAsync is reserved for ordinary
  // session refresh and does not participate in this deletion flow.
  return requestAppleAuthorization({
    clientId: session.clientId,
    expectedUserId,
    requestProfile: false,
  });
}

export async function refreshUserSession(
  session: UserSession,
  options: { allowUserInteraction?: boolean } = {},
): Promise<UserSession> {
  if (identityProviderForSession(session) === "apple") {
    if (options.allowUserInteraction === false) {
      throw new Error("Sign in with Apple again to continue.");
    }
    if (Platform.OS !== "ios") {
      throw new Error("Sign in with Apple is only available on iOS.");
    }
    const state = Crypto.randomUUID();
    const credential = await AppleAuthentication.refreshAsync({
      user: session.providerUserId ?? identityTokenSubject(session.accessToken),
      state,
    });
    assertMatchingAppleState(state, credential.state);
    return userSessionFromAppleCredential(credential, session.clientId);
  }

  const iosClientId = process.env.EXPO_PUBLIC_PASS_GOOGLE_IOS_CLIENT_ID?.trim();
  const configuration: PublicOIDCConfiguration = {
    issuer: session.issuer,
    clientId: session.clientId,
    ...(iosClientId ? { iosClientId } : {}),
  };
  configureGoogleSignIn(configuration);
  const response = await GoogleSignin.signInSilently();
  if (response.type !== "success") throw new Error("Sign in again to continue.");
  return userSessionFromGoogleUser(configuration, response.data);
}

export async function signOutGoogle(): Promise<void> {
  await GoogleSignin.signOut();
}

export async function clearIdentityProviderSession(
  session: UserSession | null,
): Promise<void> {
  // Expo recommends clearing local Apple session data instead of calling signOutAsync, which
  // presents a counterintuitive authentication modal. Google maintains a native session that
  // should be explicitly cleared.
  if (session && identityProviderForSession(session) === "google") {
    await signOutGoogle();
  }
}

async function requestAppleAuthorization(options: {
  clientId: string;
  expectedUserId?: string;
  requestProfile: boolean;
}): Promise<AppleAuthorization> {
  if (Platform.OS !== "ios") {
    throw new Error("Sign in with Apple is only available on iOS.");
  }
  const state = Crypto.randomUUID();
  const nonce = Crypto.randomUUID();
  const credential = await AppleAuthentication.signInAsync({
    state,
    nonce,
    ...(options.requestProfile
      ? {
          requestedScopes: [
            AppleAuthentication.AppleAuthenticationScope.FULL_NAME,
            AppleAuthentication.AppleAuthenticationScope.EMAIL,
          ],
        }
      : {}),
  });
  // Parse the one-time code immediately; it is deliberately kept outside the persistable session.
  const authorization = appleAuthorizationFromCredential(credential, nonce, {
    clientId: options.clientId,
    ...(options.expectedUserId ? { expectedUserId: options.expectedUserId } : {}),
  });
  assertMatchingAppleState(state, credential.state);
  return authorization;
}

export { APPLE_NATIVE_CLIENT_ID, userSessionFromAppleCredential };
