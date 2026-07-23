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
  isUserSessionFresh,
  refreshUserSession,
} from "../services/authService";
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
  signOut: () => Promise<void>;
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
        let effectiveUserSession = storedUserSession;
        if (effectiveUserSession && !isUserSessionFresh(effectiveUserSession)) {
          try {
            effectiveUserSession = await refreshUserSession(effectiveUserSession);
            await saveUserSession(effectiveUserSession);
          } catch {
            effectiveUserSession = null;
            await clearUserSession();
          }
        }
        let effectivePairing = storedPairing;
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
        allowInsecureDevelopment: __DEV__,
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
          deviceName: Platform.OS === "ios" ? "iPhone" : "Android device",
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
      if (!pairedDesktop) throw new Error("Pair this phone with a desktop first.");
      if (!userSession) throw new Error("Sign in before approving a Steam Deck.");
      let activeSession = userSession;
      if (!isUserSessionFresh(activeSession)) {
        activeSession = await refreshUserSession(activeSession);
        await saveUserSession(activeSession);
        setUserSession(activeSession);
      }
      const parsed = parseDeckPairingApproval(rawPayload);
      if (parsed.relayUrl.replace(/\/+$/, "") !== pairedDesktop.relayUrl.replace(/\/+$/, "")) {
        throw new Error("This Deck uses a different Pass relay.");
      }
      await approveDeckPairingRequest(parsed, {
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

  const revokeCurrentPairing = useCallback(async () => {
    if (!pairedDesktop || pairedDesktop.authenticationMode !== "device") return;
    if (!userSession) throw new Error("Sign in again to revoke this phone.");
    let activeSession = userSession;
    if (!isUserSessionFresh(activeSession)) {
      activeSession = await refreshUserSession(activeSession);
      await saveUserSession(activeSession);
      setUserSession(activeSession);
    }
    await revokeDevice(pairedDesktop, activeSession.accessToken);
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
    await Promise.all([clearPairedDesktop(), clearUserSession()]);
    setPairedDesktop(null);
    setUserSession(null);
    setPairingError(null);
    dispatch({ type: "RESET", configured: false });
  }, [revokeCurrentPairing]);

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
      signOut,
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
      completeSignIn,
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
