import * as Crypto from "expo-crypto";
import { Stack, useLocalSearchParams } from "expo-router";
import { useEffect, useMemo, useRef, useState } from "react";
import {
  KeyboardAvoidingView,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";

import { AppButton } from "../../components/AppButton";
import { ConversationSurface } from "../../components/ConversationSurface";
import { Screen } from "../../components/Screen";
import { TerminalSurface } from "../../components/TerminalSurface";
import { buildConversation } from "../../conversation/terminalConversation";
import {
  COMMAND_LIMITS,
  splitUTF8ByBytes,
  utf8ByteLength,
} from "../../protocol/commands";
import { useRemote } from "../../state/RemoteProvider";
import { colors, spacing } from "../../theme/theme";

type DetailMode = "conversation" | "terminal";

function labelForStatus(status: string) {
  switch (status) {
    case "decision": return "Waiting for a decision";
    case "input": return "Waiting for your input";
    case "working": return "Agent is working";
    case "finished": return "Agent finished";
    default: return "Idle";
  }
}

export default function SessionDetailScreen() {
  const params = useLocalSearchParams<{ name: string | string[] }>();
  const sessionName = Array.isArray(params.name) ? params.name[0] : params.name;
  const {
    state,
    sendMessage,
    answerDecision,
    openTerminal,
    sendTerminalInput,
    closeTerminal,
  } = useRemote();
  const session = sessionName ? state.sessionsByName[sessionName] : undefined;
  const stream = sessionName ? state.messageStreamsBySession[sessionName] : undefined;
  const subscriptionId = useMemo(
    () => `term_${Crypto.randomUUID().replaceAll("-", "")}`,
    [sessionName],
  );
  const terminal = state.terminalsBySubscription[subscriptionId];
  const terminalRevision = useRef<string | undefined>(undefined);
  const inputBuffer = useRef("");
  const inputTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const terminalActions = useRef({ openTerminal, sendTerminalInput, closeTerminal });
  terminalActions.current = { openTerminal, sendTerminalInput, closeTerminal };

  const [mode, setMode] = useState<DetailMode>("conversation");
  const [message, setMessage] = useState("");
  const [resultText, setResultText] = useState<string | null>(null);
  const [terminalError, setTerminalError] = useState<string | null>(null);
  const fallbackUser = useMemo(
    () =>
      state.activities
        .filter((item) => item.session === sessionName)
        .slice()
        .sort((a, b) => b.at.localeCompare(a.at))
        .find((item) => item.kind === "message" && item.detail)?.detail,
    [sessionName, state.activities],
  );
  const canWrite =
    state.connection.phase === "online" && state.capabilities.includes("sessions:write");
  const canDecide = canWrite && state.capabilities.includes("decisions:answer");
  const canUseTerminal =
    state.connection.phase === "online" && state.capabilities.includes("sessions:terminal");
  const responseText = stream?.text || session?.liveMessage || session?.lastMessage;
  const responseStreaming = stream?.phase === "streaming" || Boolean(session?.liveMessage);
  const responseTruncated = stream?.truncated === true || session?.liveMessageTruncated === true;
  const conversation = useMemo(
    () => buildConversation({
      pane: terminal?.content,
      agent: session?.agent ?? "generic",
      latestAssistant: responseText,
      latestAssistantStreaming: responseStreaming,
      fallbackUser,
    }),
    [fallbackUser, responseStreaming, responseText, session?.agent, terminal?.content],
  );

  useEffect(() => {
    if (terminal?.revision) terminalRevision.current = terminal.revision;
  }, [terminal?.revision]);

  const flushTerminalInput = () => {
    inputTimer.current = null;
    if (!sessionName || !inputBuffer.current) return;
    const input = inputBuffer.current;
    inputBuffer.current = "";
    for (const chunk of splitUTF8ByBytes(input, 4_096)) {
      const result = terminalActions.current.sendTerminalInput(
        sessionName,
        subscriptionId,
        chunk,
      );
      if (!result.ok) {
        setTerminalError(result.error);
        break;
      }
      setTerminalError(null);
    }
  };

  const queueTerminalInput = (input: string) => {
    if (!canUseTerminal || !input) return;
    inputBuffer.current += input;
    if (utf8ByteLength(inputBuffer.current) >= 4_096) {
      if (inputTimer.current) clearTimeout(inputTimer.current);
      flushTerminalInput();
      return;
    }
    if (!inputTimer.current) inputTimer.current = setTimeout(flushTerminalInput, 12);
  };

  useEffect(() => {
    if (!sessionName || !canUseTerminal) return;
    const renew = () => {
      const result = terminalActions.current.openTerminal(
        sessionName,
        subscriptionId,
        terminalRevision.current,
      );
      if (result.ok) setTerminalError(null);
      else setTerminalError(result.error);
    };
    renew();
    const interval = setInterval(renew, 10_000);
    return () => {
      clearInterval(interval);
      if (inputTimer.current) clearTimeout(inputTimer.current);
      flushTerminalInput();
      terminalActions.current.closeTerminal(sessionName, subscriptionId);
    };
  }, [canUseTerminal, sessionName, subscriptionId]);

  if (!session) {
    return (
      <Screen style={styles.missing}>
        <Text style={styles.title}>Session unavailable</Text>
        <Text style={styles.muted}>It may have ended since the last desktop snapshot.</Text>
      </Screen>
    );
  }

  const send = () => {
    const text = message.trim();
    if (!text) return;
    const result = sendMessage(session.name, text);
    if (result.ok) {
      setMessage("");
      setResultText("Sent.");
    } else setResultText(result.error);
  };

  const decide = (decision: "allowOnce" | "allowAll" | "deny") => {
    const result = answerDecision(session.name, decision);
    setResultText(result.ok ? "Decision sent." : result.error);
  };

  const attentionVisible =
    session.attention.status === "decision" || session.attention.status === "input";

  return (
    <Screen edges={["left", "right", "bottom"]}>
      <Stack.Screen options={{ title: session.displayName }} />
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        keyboardVerticalOffset={90}
        style={styles.flex}
      >
        <View style={styles.header}>
          <View style={styles.identity}>
            <Text numberOfLines={1} style={styles.headerTitle}>{session.displayName}</Text>
            <Text numberOfLines={1} style={styles.headerMeta}>
              {session.agent}{session.gitBranch ? ` · ${session.gitBranch}` : ""} · {labelForStatus(session.attention.status)}
            </Text>
          </View>
          <View accessibilityRole="tablist" style={styles.segmented}>
            {(["conversation", "terminal"] as const).map((item) => (
              <Pressable
                key={item}
                accessibilityRole="tab"
                accessibilityState={{ selected: mode === item }}
                onPress={() => setMode(item)}
                style={[styles.segment, mode === item && styles.segmentSelected]}
              >
                <Text style={[styles.segmentText, mode === item && styles.segmentTextSelected]}>
                  {item === "conversation" ? "Chat" : "Terminal"}
                </Text>
              </Pressable>
            ))}
          </View>
        </View>

        {attentionVisible ? (
          <View style={styles.attentionBand}>
            <View style={styles.attentionCopy}>
              <Text style={styles.attentionTitle}>{labelForStatus(session.attention.status)}</Text>
              <Text numberOfLines={2} style={styles.attentionText}>
                {session.attention.preview || "Review the pending request below."}
              </Text>
            </View>
            {session.attention.status === "decision" ? (
              <View style={styles.decisionActions}>
                <AppButton compact label="Once" disabled={!canDecide} onPress={() => decide("allowOnce")} />
                <AppButton compact variant="secondary" label="All" disabled={!canDecide} onPress={() => decide("allowAll")} />
                <AppButton compact variant="danger" label="Deny" disabled={!canDecide} onPress={() => decide("deny")} />
              </View>
            ) : null}
          </View>
        ) : null}

        {mode === "conversation" ? (
          <>
            <ConversationSurface
              blocks={conversation}
              truncated={responseTruncated}
            />
            <View style={styles.composer}>
              {resultText ? <Text numberOfLines={2} style={styles.result}>{resultText}</Text> : null}
              <View style={styles.composerRow}>
                <TextInput
                  accessibilityLabel="Message to coding session"
                  maxLength={COMMAND_LIMITS.messageCharacters}
                  multiline
                  onChangeText={setMessage}
                  placeholder={`Message ${session.agent}…`}
                  placeholderTextColor={colors.subtle}
                  style={styles.composerInput}
                  value={message}
                />
                <Pressable
                  accessibilityLabel="Send message"
                  accessibilityRole="button"
                  disabled={!canWrite || !message.trim()}
                  onPress={send}
                  style={({ pressed }) => [
                    styles.sendButton,
                    (!canWrite || !message.trim()) && styles.sendButtonDisabled,
                    pressed && canWrite && message.trim() && styles.sendButtonPressed,
                  ]}
                >
                  <Text style={styles.sendIcon}>↑</Text>
                </Pressable>
              </View>
            </View>
          </>
        ) : (
          canUseTerminal || terminal ? (
            <TerminalSurface
              enabled={canUseTerminal}
              error={terminalError}
              onError={setTerminalError}
              onInput={queueTerminalInput}
              snapshot={terminal}
            />
          ) : (
            <View style={styles.terminalUnavailable}>
              <Text style={styles.title}>Terminal unavailable</Text>
              <Text style={styles.muted}>
                {state.connection.phase === "online"
                  ? "The connected desktop does not advertise terminal access."
                  : "Reconnect the desktop to open this tmux pane."}
              </Text>
            </View>
          )
        )}
      </KeyboardAvoidingView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
  missing: { alignItems: "center", justifyContent: "center", padding: spacing.lg, gap: spacing.sm },
  title: { color: colors.text, fontSize: 18, fontWeight: "800" },
  muted: { color: colors.muted, fontSize: 13, lineHeight: 19 },
  header: {
    minHeight: 58,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    flexDirection: "row",
    alignItems: "center",
    gap: spacing.sm,
    backgroundColor: colors.surface,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.border,
  },
  identity: { flex: 1, minWidth: 0, gap: 3 },
  headerTitle: { color: colors.text, fontSize: 15, fontWeight: "800" },
  headerMeta: { color: colors.subtle, fontSize: 10, textTransform: "capitalize" },
  segmented: {
    width: 156,
    height: 32,
    padding: 2,
    flexDirection: "row",
    backgroundColor: colors.background,
    borderRadius: 6,
    borderWidth: 1,
    borderColor: colors.border,
  },
  segment: { flex: 1, alignItems: "center", justifyContent: "center", borderRadius: 4 },
  segmentSelected: { backgroundColor: "#2a313b" },
  segmentText: { color: colors.subtle, fontSize: 11, fontWeight: "700" },
  segmentTextSelected: { color: colors.text },
  attentionBand: {
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    flexDirection: "row",
    alignItems: "center",
    gap: spacing.sm,
    backgroundColor: "#2a2216",
    borderBottomWidth: 1,
    borderBottomColor: "#60481f",
  },
  attentionCopy: { flex: 1, minWidth: 0, gap: 2 },
  attentionTitle: { color: colors.warning, fontSize: 12, fontWeight: "800" },
  attentionText: { color: colors.text, fontSize: 11, lineHeight: 15 },
  decisionActions: { flexDirection: "row", gap: 5 },
  terminalUnavailable: { flex: 1, alignItems: "center", justifyContent: "center", padding: spacing.xl, gap: spacing.sm },
  composer: { backgroundColor: "#121519", borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: colors.border, paddingHorizontal: spacing.md, paddingVertical: spacing.sm, gap: 6 },
  composerRow: { flexDirection: "row", alignItems: "flex-end", gap: 8 },
  composerInput: { flex: 1, minHeight: 44, maxHeight: 120, color: colors.text, backgroundColor: "#1b1f24", borderWidth: 1, borderColor: "#303741", borderRadius: 8, paddingHorizontal: 12, paddingVertical: 11, fontSize: 14, lineHeight: 20, textAlignVertical: "top" },
  sendButton: { width: 44, height: 44, borderRadius: 8, alignItems: "center", justifyContent: "center", backgroundColor: "#61bd8e" },
  sendButtonDisabled: { backgroundColor: "#252b32", opacity: 0.55 },
  sendButtonPressed: { opacity: 0.72 },
  sendIcon: { color: "#07130d", fontSize: 22, fontWeight: "900", lineHeight: 24 },
  result: { color: colors.muted, fontSize: 11 },
});
