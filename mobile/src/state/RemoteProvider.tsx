import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
  type PropsWithChildren,
} from "react";
import * as Crypto from "expo-crypto";
import { AppState, Platform } from "react-native";

import { parsePairingPayload } from "../protocol/pairing";
import { parseDeckPairingApproval } from "../protocol/pairing";
import type {
  AgentKind,
  ClientCommandPayloadMap,
  ClientCommandType,
  PairedDesktop,
  UserSession,
  UserPreferences,
} from "../protocol/types";
import {
  claimDevicePairing,
  createDevelopmentPairing,
  approveDeckPairing as approveDeckPairingRequest,
} from "../services/pairingService";
import {
  clearIdentityProviderSession,
  isUserSessionFresh,
  refreshUserSession,
  requestAppleDeletionAuthorization,
} from "../services/authService";
import {
  deleteAccount as deleteAccountRequest,
  type AccountDeletionResult,
} from "../services/accountService";
import {
  fallbackForAppleDeletionResponse,
  fallbackForApplePreparationFailure,
  manualDeletionSessionStrategy,
  persistAppleSignInBeforeBackgroundRegistration,
  persistFreshAppleSessionAfterRegistrationAttempt,
} from "../services/appleDeletionFallback";
import {
  registerAppleAuthorization,
  type AppleAuthorization,
} from "../services/appleAuthorizationService";
import { identityProviderForSession } from "../services/identitySession";
import {
  pinStoredPairingForProduction,
  requirePinnedRelayURL,
  resolveAccountRelayURL,
} from "../services/relayURL";
import {
  refreshDeviceCredential,
  revokeDevice,
  shouldRefreshDeviceCredential,
} from "../services/deviceCredentialService";
import { RemoteClient } from "../services/remoteClient";
import {
  clearPairedDesktop,
  clearUserSession,
  loadPairedDesktop,
  loadPreferences,
  loadUserSession,
  savePairedDesktop,
  savePreferences,
  saveUserSession,
} from "../services/storage";
import { initialRemoteState, remoteReducer } from "./reducer";

type CommandResult =
  | { ok: true; commandId: string }
  | { ok: false; error: string };

type Decision = "allowOnce" | "allowAll" | "deny";
type LaunchableAgent = Extract<AgentKind, "claude" | "codex" | "pi">;
type DeleteAccountOptions = { appleRevocationFallback?: "manual" };

interface RemoteContextValue {
  state: ReturnType<typeof remoteReducer>;
  pairedDesktop: PairedDesktop | null;
  userSession: UserSession | null;
  preferences: UserPreferences;
  hydrated: boolean;
  pairingBusy: boolean;
  pairingError: string | null;
  pair: (rawPayload: string) => Promise<CommandResult>;
  approveDeckPairing: (rawPayload: string) => Promise<CommandResult>;
  completeSignIn: (session: UserSession) => Promise<void>;
  completeAppleSignIn: (authorization: AppleAuthorization) => Promise<void>;
  signOut: () => Promise<void>;
  deleteAccount: (options?: DeleteAccountOptions) => Promise<AccountDeletionResult>;
  forgetPairing: () => Promise<void>;
  updatePreferences: (patch: Partial<UserPreferences>) => Promise<void>;
  reconnect: () => void;
  refresh: () => CommandResult;
  sendMessage: (session: string, text: string) => CommandResult;
  createSession: (
    projectRoot: string,
    agent: LaunchableAgent,
    initialPrompt?: string,
  ) => CommandResult;
  answerDecision: (session: string, decision: Decision) => CommandResult;
  openTerminal: (
    session: string,
    subscriptionId: string,
    previousRevision?: string,
  ) => CommandResult;
  sendTerminalInput: (
    session: string,
    subscriptionId: string,
    input: string,
  ) => CommandResult;
  closeTerminal: (session: string, subscriptionId: string) => CommandResult;
}

const RemoteContext = createContext<RemoteContextValue | null>(null);

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Something went wrong.";
}

export function RemoteProvider({ children }: PropsWithChildren) {
  const [state, dispatch] = useReducer(remoteReducer, initialRemoteState);
  const [pairedDesktop, setPairedDesktop] = useState<PairedDesktop | null>(null);
  const [userSession, setUserSession] = useState<UserSession | null>(null);
  const [preferences, setPreferences] = useState<UserPreferences>({
    notificationsEnabled: true,
    decisionAlerts: true,
    voiceMode: "push-to-talk",
  });
  const [hydrated, setHydrated] = useState(false);
  const [pairingBusy, setPairingBusy] = useState(false);
  const [pairingError, setPairingError] = useState<string | null>(null);
  const clientRef = useRef<RemoteClient | null>(null);

  useEffect(() => {
    let active = true;
    Promise.all([loadPairedDesktop(), loadPreferences(), loadUserSession()])
      .then(async ([storedPairing, storedPreferences, storedUserSession]) => {
        if (!active) return;
        let effectivePairing = storedPairing;
        let storedPairingError: string | null = null;
        if (!__DEV__ && effectivePairing) {
          try {
            effectivePairing = pinStoredPairingForProduction(
              effectivePairing,
              process.env.EXPO_PUBLIC_PASS_RELAY_URL,
            );
          } catch (error) {
            // Validate legacy storage before any credential refresh or WebSocket can use its URL.
            effectivePairing = null;
            storedPairingError = `Saved pairing was removed: ${errorMessage(error)}`;
            await clearPairedDesktop();
          }
        }
        let effectiveUserSession = storedUserSession;
        if (effectiveUserSession && !isUserSessionFresh(effectiveUserSession)) {
          try {
            effectiveUserSession = await refreshUserSession(effectiveUserSession, {
              allowUserInteraction: false,
            });
            await saveUserSession(effectiveUserSession);
          } catch {
            // Apple cannot silently mint a new ID token: refreshAsync intentionally presents
            // system UI. Retain the expired credential metadata so a later user-initiated account
            // action can refresh it interactively. Google refresh failures require a fresh login.
            let retainForInteractiveAppleRefresh = false;
            try {
              retainForInteractiveAppleRefresh =
                identityProviderForSession(effectiveUserSession) === "apple";
            } catch {
              // Unsupported legacy providers are cleared below.
            }
            if (!retainForInteractiveAppleRefresh) {
              effectiveUserSession = null;
              await clearUserSession();
            }
          }
        }
        if (effectivePairing && shouldRefreshDeviceCredential(effectivePairing)) {
          try {
            effectivePairing = await refreshDeviceCredential(effectivePairing);
            await savePairedDesktop(effectivePairing);
          } catch (error) {
            dispatch({
              type: "CONNECTION_PHASE",
              phase: "error",
              error: errorMessage(error),
            });
          }
        }
        if (!active) return;
        setUserSession(effectiveUserSession);
        setPairedDesktop(effectivePairing);
        setPreferences(storedPreferences);
        dispatch({ type: "RESET", configured: effectivePairing !== null });
        if (storedPairingError) {
          setPairingError(storedPairingError);
          dispatch({
            type: "CONNECTION_PHASE",
            phase: "error",
            error: storedPairingError,
          });
        }
      })
      .catch((error) => {
        if (!active) return;
        dispatch({
          type: "CONNECTION_PHASE",
          phase: "error",
          error: `Could not load secure settings: ${errorMessage(error)}`,
        });
      })
      .finally(() => {
        if (active) setHydrated(true);
      });
    return () => {
      active = false;
    };
  }, []);

  useEffect(() => {
    if (!pairedDesktop || pairedDesktop.authenticationMode !== "device") return;
    const expiresAt = new Date(pairedDesktop.credentialExpiresAt ?? "").getTime();
    if (!Number.isFinite(expiresAt)) return;
    const delay = Math.max(0, expiresAt - Date.now() - 60_000);
    const timer = setTimeout(() => {
      void refreshDeviceCredential(pairedDesktop)
        .then(async (refreshed) => {
          await savePairedDesktop(refreshed);
          setPairedDesktop(refreshed);
        })
        .catch((error) => {
          dispatch({
            type: "CONNECTION_PHASE",
            phase: "error",
            error: errorMessage(error),
          });
        });
    }, delay);
    return () => clearTimeout(timer);
  }, [pairedDesktop]);

  useEffect(() => {
    if (!hydrated || !pairedDesktop) return;
    const client = new RemoteClient({
      pairing: pairedDesktop,
      onEvent: (event) => dispatch({ type: "EVENT_RECEIVED", event }),
      onCommand: (command) => dispatch({ type: "COMMAND_SENT", command }),
      onStatus: ({ phase, attempt, error }) =>
        dispatch({ type: "CONNECTION_PHASE", phase, attempt, ...(error ? { error } : {}) }),
      onProtocolError: (message) => dispatch({ type: "PROTOCOL_ERROR", message }),
      uuidFactory: Crypto.randomUUID,
    });
    clientRef.current = client;
    client.connect();

    const appState = AppState.addEventListener("change", (nextState) => {
      if (nextState === "active") client.connect();
      else client.stop();
    });
    return () => {
      appState.remove();
      client.stop(false);
      if (clientRef.current === client) clientRef.current = null;
    };
  }, [hydrated, pairedDesktop]);

  const pair = useCallback(async (rawPayload: string): Promise<CommandResult> => {
    setPairingBusy(true);
    setPairingError(null);
    try {
      const parsed = parsePairingPayload(rawPayload, {
        allowDevelopmentPairing: __DEV__,
        allowInsecureDevelopment: __DEV__,
        enforceTrustedRelay: !__DEV__,
        trustedRelayUrl: process.env.EXPO_PUBLIC_PASS_RELAY_URL,
      });
      if (!parsed.ok) {
        setPairingError(parsed.error);
        return { ok: false, error: parsed.error };
      }
      let pairing: PairedDesktop;
      if (parsed.value.v === 2) {
        if (!userSession) {
          throw new Error("Sign in before claiming a one-time pairing code.");
        }
        let activeSession = userSession;
        if (!isUserSessionFresh(activeSession)) {
          activeSession = await refreshUserSession(activeSession);
          await saveUserSession(activeSession);
          setUserSession(activeSession);
        }
        pairing = await claimDevicePairing(parsed.value, {
          userAccessToken: activeSession.accessToken,
          deviceName:
            Platform.OS === "ios"
              ? Platform.isPad
                ? "iPad"
                : "iPhone"
              : "Android device",
          platform: Platform.OS === "ios" ? "ios" : "android",
        });
      } else {
        pairing = createDevelopmentPairing(parsed.value);
      }
      await savePairedDesktop(pairing);
      setPairedDesktop(pairing);
      dispatch({ type: "RESET", configured: true });
      return { ok: true, commandId: pairing.deviceId };
    } catch (error) {
      const message = errorMessage(error);
      setPairingError(message);
      return { ok: false, error: message };
    } finally {
      setPairingBusy(false);
    }
  }, [userSession]);

  const approveDeckPairing = useCallback(async (rawPayload: string): Promise<CommandResult> => {
    setPairingBusy(true);
    setPairingError(null);
    try {
      if (!pairedDesktop) throw new Error("Pair this device with a desktop first.");
      if (!userSession) throw new Error("Sign in before approving a Steam Deck.");
      let activeSession = userSession;
      if (!isUserSessionFresh(activeSession)) {
        activeSession = await refreshUserSession(activeSession);
        await saveUserSession(activeSession);
        setUserSession(activeSession);
      }
      const parsed = parseDeckPairingApproval(rawPayload);
      const requestRelayUrl = __DEV__
        ? parsed.relayUrl
        : requirePinnedRelayURL(
            parsed.relayUrl,
            process.env.EXPO_PUBLIC_PASS_RELAY_URL,
          );
      const pairedRelayUrl = __DEV__
        ? pairedDesktop.relayUrl
        : requirePinnedRelayURL(
            pairedDesktop.relayUrl,
            process.env.EXPO_PUBLIC_PASS_RELAY_URL,
          );
      if (requestRelayUrl !== pairedRelayUrl) {
        throw new Error("This Deck uses a different Pass relay.");
      }
      await approveDeckPairingRequest({ ...parsed, relayUrl: requestRelayUrl }, {
        userAccessToken: activeSession.accessToken,
        desktopId: pairedDesktop.desktopId,
      });
      return { ok: true, commandId: parsed.pairingId };
    } catch (error) {
      const message = errorMessage(error);
      setPairingError(message);
      return { ok: false, error: message };
    } finally { setPairingBusy(false); }
  }, [pairedDesktop, userSession]);

  const completeSignIn = useCallback(async (session: UserSession) => {
    await saveUserSession(session);
    setUserSession(session);
  }, []);

  const completeAppleSignIn = useCallback(async (
    authorization: AppleAuthorization,
  ) => {
    const relayUrl = resolveAccountRelayURL(
      process.env.EXPO_PUBLIC_PASS_RELAY_URL,
    );
    await persistAppleSignInBeforeBackgroundRegistration(
      authorization,
      async (session) => {
        await saveUserSession(session);
        setUserSession(session);
      },
      () => registerAppleAuthorization(relayUrl, authorization),
    );
  }, []);

  const revokeCurrentPairing = useCallback(async () => {
    if (!pairedDesktop || pairedDesktop.authenticationMode !== "device") return;
    if (!userSession) throw new Error("Sign in again to revoke this device.");
    const relayUrl = __DEV__
      ? pairedDesktop.relayUrl
      : requirePinnedRelayURL(
          pairedDesktop.relayUrl,
          process.env.EXPO_PUBLIC_PASS_RELAY_URL,
        );
    let activeSession = userSession;
    if (!isUserSessionFresh(activeSession)) {
      activeSession = await refreshUserSession(activeSession);
      await saveUserSession(activeSession);
      setUserSession(activeSession);
    }
    await revokeDevice(
      { ...pairedDesktop, relayUrl },
      activeSession.accessToken,
    );
  }, [pairedDesktop, userSession]);

  const forgetPairing = useCallback(async () => {
    await revokeCurrentPairing();
    clientRef.current?.stop(false);
    clientRef.current = null;
    await clearPairedDesktop();
    setPairedDesktop(null);
    setPairingError(null);
    dispatch({ type: "RESET", configured: false });
  }, [revokeCurrentPairing]);

  const signOut = useCallback(async () => {
    await revokeCurrentPairing();
    clientRef.current?.stop(false);
    clientRef.current = null;
    await Promise.all([
      clearPairedDesktop(),
      clearUserSession(),
      clearIdentityProviderSession(userSession),
    ]);
    setPairedDesktop(null);
    setUserSession(null);
    setPairingError(null);
    dispatch({ type: "RESET", configured: false });
  }, [revokeCurrentPairing, userSession]);

  const deleteAccount = useCallback(async (
    options: DeleteAccountOptions = {},
  ): Promise<AccountDeletionResult> => {
    const manualFallback = options.appleRevocationFallback === "manual";
    const storedSession = manualFallback ? await loadUserSession() : userSession;
    if (!storedSession) throw new Error("Sign in again to delete this account.");
    const relayUrl = resolveAccountRelayURL(
      process.env.EXPO_PUBLIC_PASS_RELAY_URL,
      { allowInsecureDevelopment: __DEV__ },
    );

    let activeSession = storedSession;
    const provider = identityProviderForSession(activeSession);
    if (manualFallback) {
      const strategy = manualDeletionSessionStrategy(activeSession);
      if (strategy === "reject_expired_apple") {
        throw new Error(
          "The saved Apple sign-in token is no longer fresh. Pass data was not deleted; retry automatic deletion.",
        );
      }
      if (strategy === "refresh_google") {
        activeSession = await refreshUserSession(activeSession);
        await saveUserSession(activeSession);
        setUserSession(activeSession);
      }
    } else if (provider === "apple") {
      // Account deletion is a user-initiated action. Always obtain a new one-time code, even when
      // the saved Apple ID token is fresh, so the Relay can revoke Apple's server-side grant.
      let authorization: AppleAuthorization;
      try {
        authorization = await requestAppleDeletionAuthorization(activeSession);
      } catch (error) {
        const fallback = fallbackForApplePreparationFailure(error);
        if (fallback) throw fallback;
        throw error;
      }
      const registrationError = await persistFreshAppleSessionAfterRegistrationAttempt(
        authorization,
        () => registerAppleAuthorization(relayUrl, authorization),
        async (session) => {
          await saveUserSession(session);
          setUserSession(session);
        },
      );
      activeSession = authorization.session;
      if (registrationError !== null) {
        const fallback = fallbackForApplePreparationFailure(registrationError);
        if (fallback) throw fallback;
        throw registrationError;
      }
    } else if (!isUserSessionFresh(activeSession)) {
      activeSession = await refreshUserSession(activeSession);
      await saveUserSession(activeSession);
      setUserSession(activeSession);
    }

    let result: AccountDeletionResult;
    try {
      result = await deleteAccountRequest(
        relayUrl,
        activeSession.accessToken,
        manualFallback ? { appleRevocationFallback: "manual" } : {},
      );
    } catch (error) {
      if (!manualFallback) {
        const fallback = fallbackForAppleDeletionResponse(error);
        if (fallback) throw fallback;
      }
      throw error;
    }

    clientRef.current?.stop(false);
    clientRef.current = null;
    try {
      await Promise.all([
        clearPairedDesktop(),
        clearUserSession(),
        clearIdentityProviderSession(activeSession).catch(() => undefined),
      ]);
    } finally {
      setPairedDesktop(null);
      setUserSession(null);
      setPairingError(null);
      dispatch({ type: "RESET", configured: false });
    }
    return result;
  }, [userSession]);

  const updatePreferences = useCallback(
    async (patch: Partial<UserPreferences>) => {
      const next = { ...preferences, ...patch };
      setPreferences(next);
      await savePreferences(next);
    },
    [preferences],
  );

  const send = useCallback(
    <K extends ClientCommandType,>(
      type: K,
      payload: ClientCommandPayloadMap[K],
    ): CommandResult => {
      try {
        const command = clientRef.current?.send(type, payload);
        if (!command) return { ok: false, error: "No relay connection is configured." };
        return { ok: true, commandId: command.id };
      } catch (error) {
        return { ok: false, error: errorMessage(error) };
      }
    },
    [],
  );

  const value = useMemo<RemoteContextValue>(
    () => ({
      state,
      pairedDesktop,
      userSession,
      preferences,
      hydrated,
      pairingBusy,
      pairingError,
      pair,
      approveDeckPairing,
      completeSignIn,
      completeAppleSignIn,
      signOut,
      deleteAccount,
      forgetPairing,
      updatePreferences,
      reconnect: () => clientRef.current?.reconnect(),
      refresh: () => {
        const first = send("session.list", {});
        if (!first.ok) return first;
        send("project.list", {});
        return first;
      },
      sendMessage: (session, text) =>
        send("session.sendMessage", { session, text }),
      createSession: (projectRoot, agent, initialPrompt) =>
        send("session.create", {
          projectRoot,
          agent,
          ...(initialPrompt?.trim() ? { initialPrompt: initialPrompt.trim() } : {}),
        }),
      answerDecision: (session, decision) =>
        send("session.answerDecision", { session, decision }),
      openTerminal: (session, subscriptionId, previousRevision) =>
        send("session.terminal.open", {
          session,
          subscriptionId,
          ...(previousRevision ? { previousRevision } : {}),
        }),
      sendTerminalInput: (session, subscriptionId, input) =>
        send("session.terminal.input", { session, subscriptionId, input }),
      closeTerminal: (session, subscriptionId) => {
        const result = send("session.terminal.close", { session, subscriptionId });
        dispatch({ type: "TERMINAL_CLOSED", subscriptionId });
        return result;
      },
    }),
    [
      forgetPairing,
      hydrated,
      pair,
      approveDeckPairing,
      pairedDesktop,
      pairingBusy,
      pairingError,
      completeAppleSignIn,
      completeSignIn,
      deleteAccount,
      preferences,
      send,
      state,
      signOut,
      updatePreferences,
      userSession,
    ],
  );

  return <RemoteContext.Provider value={value}>{children}</RemoteContext.Provider>;
}

export function useRemote(): RemoteContextValue {
  const value = useContext(RemoteContext);
  if (!value) throw new Error("useRemote must be used inside RemoteProvider.");
  return value;
}
