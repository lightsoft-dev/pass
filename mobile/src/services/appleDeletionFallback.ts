import type { UserSession } from "../protocol/types.ts";
import { AccountDeletionError } from "./accountService.ts";
import type { AppleAuthorization } from "./appleAuthorizationService.ts";
import {
  identityProviderForSession,
  isAppleRequestCanceled,
} from "./identitySession.ts";

export class AppleRevocationFallbackRequiredError extends Error {
  readonly originalMessage: string;

  constructor(originalMessage: string) {
    super(
      "Pass could not automatically revoke Sign in with Apple. Retry, cancel, or delete Pass data after manually stopping Apple sign-in.",
    );
    this.name = "AppleRevocationFallbackRequiredError";
    this.originalMessage = originalMessage;
  }
}

export function fallbackForApplePreparationFailure(
  error: unknown,
): AppleRevocationFallbackRequiredError | null {
  if (isAppleRequestCanceled(error)) return null;
  return new AppleRevocationFallbackRequiredError(errorMessage(error));
}

export function fallbackForAppleDeletionResponse(
  error: unknown,
): AppleRevocationFallbackRequiredError | null {
  return error instanceof AccountDeletionError && error.manualRevocationAvailable
    ? new AppleRevocationFallbackRequiredError(error.message)
    : null;
}

export function isAppleRevocationFallbackRequiredError(
  error: unknown,
): error is AppleRevocationFallbackRequiredError {
  return error instanceof AppleRevocationFallbackRequiredError;
}

export type ManualDeletionSessionStrategy =
  | "use_saved"
  | "refresh_google"
  | "reject_expired_apple";

export function manualDeletionSessionStrategy(
  session: UserSession,
  now = Date.now(),
  marginMilliseconds = 60_000,
): ManualDeletionSessionStrategy {
  const expiresAt = new Date(session.accessExpiresAt).getTime();
  const fresh = Number.isFinite(expiresAt) && expiresAt > now + marginMilliseconds;
  if (identityProviderForSession(session) === "apple") {
    return fresh ? "use_saved" : "reject_expired_apple";
  }
  return fresh ? "use_saved" : "refresh_google";
}

export async function persistFreshAppleSessionAfterRegistrationAttempt(
  authorization: AppleAuthorization,
  register: () => Promise<void>,
  persist: (session: UserSession) => Promise<void>,
): Promise<unknown | null> {
  try {
    await register();
  } catch (error) {
    // The code and nonce remain ephemeral, but the newly authenticated ID token can authorize a
    // user-approved manual DELETE if Relay-side code exchange was the part that failed.
    await persist(authorization.session);
    return error;
  }
  await persist(authorization.session);
  return null;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Apple authorization failed.";
}
