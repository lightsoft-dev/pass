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
import { AppState } from "react-native";

import { parsePairingPayload } from "../protocol/pairing";
import type {
  AgentKind,
  ClientCommandPayloadMap,
  ClientCommandType,
  PairedDesktop,
  UserPreferences,
} from "../protocol/types";
import { createDevelopmentPairing } from "../services/pairingService";
import { RemoteClient } from "../services/remoteClient";
import {
  clearPairedDesktop,
  loadPairedDesktop,
  loadPreferences,
  savePairedDesktop,
  savePreferences,
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
  preferences: UserPreferences;
  hydrated: boolean;
  pairingBusy: boolean;
  pairingError: string | null;
  pair: (rawPayload: string) => Promise<CommandResult>;
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
}

const RemoteContext = createContext<RemoteContextValue | null>(null);

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Something went wrong.";
}

export function RemoteProvider({ children }: PropsWithChildren) {
  const [state, dispatch] = useReducer(remoteReducer, initialRemoteState);
  const [pairedDesktop, setPairedDesktop] = useState<PairedDesktop | null>(null);
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
    Promise.all([loadPairedDesktop(), loadPreferences()])
      .then(([storedPairing, storedPreferences]) => {
        if (!active) return;
        setPairedDesktop(storedPairing);
        setPreferences(storedPreferences);
        dispatch({ type: "RESET", configured: storedPairing !== null });
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
      const pairing = createDevelopmentPairing(parsed.value);
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
  }, []);

  const forgetPairing = useCallback(async () => {
    clientRef.current?.stop(false);
    clientRef.current = null;
    await clearPairedDesktop();
    setPairedDesktop(null);
    setPairingError(null);
    dispatch({ type: "RESET", configured: false });
  }, []);

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
      preferences,
      hydrated,
      pairingBusy,
      pairingError,
      pair,
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
    }),
    [
      forgetPairing,
      hydrated,
      pair,
      pairedDesktop,
      pairingBusy,
      pairingError,
      preferences,
      send,
      state,
      updatePreferences,
    ],
  );

  return <RemoteContext.Provider value={value}>{children}</RemoteContext.Provider>;
}

export function useRemote(): RemoteContextValue {
  const value = useContext(RemoteContext);
  if (!value) throw new Error("useRemote must be used inside RemoteProvider.");
  return value;
}
