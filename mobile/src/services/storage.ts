import * as SecureStore from "expo-secure-store";

import {
  DEFAULT_PREFERENCES,
  PROTOCOL_VERSION,
  type Capability,
  type PairedDesktop,
  type UserPreferences,
} from "../protocol/types";

const PAIRING_KEY = "pass.remote.pairing.v1";
const PREFERENCES_KEY = "pass.remote.preferences.v1";

const CAPABILITIES = new Set<Capability>([
  "sessions:read",
  "sessions:write",
  "projects:read",
  "voice:use",
  "decisions:answer",
]);

const secureOptions: SecureStore.SecureStoreOptions = {
  keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
};

function isString(value: unknown, max = 8192): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= max;
}

function parseStoredPairing(raw: string | null): PairedDesktop | null {
  if (!raw) return null;
  try {
    const value = JSON.parse(raw) as Record<string, unknown>;
    if (
      value.protocolVersion !== PROTOCOL_VERSION ||
      !isString(value.relayUrl, 2048) ||
      !isString(value.desktopId, 200) ||
      !isString(value.desktopName, 200) ||
      !isString(value.deviceId, 200) ||
      !isString(value.credential) ||
      !isString(value.pairedAt, 100) ||
      !Array.isArray(value.scopes) ||
      value.scopes.some((scope) => !CAPABILITIES.has(scope as Capability))
    ) {
      return null;
    }
    return value as unknown as PairedDesktop;
  } catch {
    return null;
  }
}

function parseStoredPreferences(raw: string | null): UserPreferences {
  if (!raw) return DEFAULT_PREFERENCES;
  try {
    const value = JSON.parse(raw) as Partial<UserPreferences>;
    return {
      notificationsEnabled:
        typeof value.notificationsEnabled === "boolean"
          ? value.notificationsEnabled
          : DEFAULT_PREFERENCES.notificationsEnabled,
      decisionAlerts:
        typeof value.decisionAlerts === "boolean"
          ? value.decisionAlerts
          : DEFAULT_PREFERENCES.decisionAlerts,
      voiceMode:
        value.voiceMode === "hands-free" || value.voiceMode === "push-to-talk"
          ? value.voiceMode
          : DEFAULT_PREFERENCES.voiceMode,
    };
  } catch {
    return DEFAULT_PREFERENCES;
  }
}

export async function loadPairedDesktop(): Promise<PairedDesktop | null> {
  return parseStoredPairing(await SecureStore.getItemAsync(PAIRING_KEY));
}

export async function savePairedDesktop(pairing: PairedDesktop): Promise<void> {
  await SecureStore.setItemAsync(PAIRING_KEY, JSON.stringify(pairing), secureOptions);
}

export async function clearPairedDesktop(): Promise<void> {
  await SecureStore.deleteItemAsync(PAIRING_KEY);
}

export async function loadPreferences(): Promise<UserPreferences> {
  return parseStoredPreferences(await SecureStore.getItemAsync(PREFERENCES_KEY));
}

export async function savePreferences(preferences: UserPreferences): Promise<void> {
  await SecureStore.setItemAsync(
    PREFERENCES_KEY,
    JSON.stringify(preferences),
    secureOptions,
  );
}
