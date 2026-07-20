import * as Crypto from "expo-crypto";
import { Stack, useLocalSearchParams } from "expo-router";
import { useEffect, useMemo, useRef, useState } from "react";
import {
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";

import { AppButton } from "../../components/AppButton";
import { Screen } from "../../components/Screen";
import { TerminalSurface } from "../../components/TerminalSurface";
import {
  COMMAND_LIMITS,
  splitUTF8ByBytes,
  utf8ByteLength,
} from "../../protocol/commands";
import { useRemote } from "../../state/RemoteProvider";
import { colors, radius, spacing } from "../../theme/theme";

type DetailMode = "terminal" | "activity";

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

  const [mode, setMode] = useState<DetailMode>("terminal");
  const [message, setMessage] = useState("");
  const [resultText, setResultText] = useState<string | null>(null);
  const [terminalError, setTerminalError] = useState<string | null>(null);
  const timeline = useMemo(
    () =>
      state.activities
        .filter((item) => item.session === sessionName)
        .slice()
        .sort((a, b) => b.at.localeCompare(a.at)),
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
      setResultText("Sent to relay. Delivery confirmation will appear below.");
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
            {(["terminal", "activity"] as const).map((item) => (
              <Pressable
                key={item}
                accessibilityRole="tab"
                accessibilityState={{ selected: mode === item }}
                onPress={() => setMode(item)}
                style={[styles.segment, mode === item && styles.segmentSelected]}
              >
                <Text style={[styles.segmentText, mode === item && styles.segmentTextSelected]}>
                  {item === "terminal" ? "Terminal" : "Activity"}
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
                {session.attention.preview || "Open the terminal for the full prompt."}
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

        {mode === "terminal" ? (
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
        ) : (
          <>
            <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
              <View style={styles.section}>
                <View style={styles.responseHeading}>
                  <Text style={styles.sectionTitle}>Agent response</Text>
                  {responseStreaming ? <Text style={styles.liveText}>LIVE</Text> : null}
                </View>
                <View style={[styles.responseCard, responseStreaming && styles.streamingResponseCard]}>
                  <Text selectable style={responseText ? styles.response : styles.muted}>
                    {responseText || "No completed response has been published yet."}
                  </Text>
                  {responseTruncated ? (
                    <Text style={styles.streamNotice}>Showing the first 64 KiB.</Text>
                  ) : null}
                </View>
              </View>

              <View style={styles.section}>
                <Text style={styles.sectionTitle}>Mobile activity</Text>
                {timeline.length === 0 ? (
                  <Text style={styles.muted}>Messages and attention changes appear here.</Text>
                ) : timeline.map((item) => (
                  <View key={item.id} style={styles.timelineItem}>
                    <View style={styles.timelineDot} />
                    <View style={styles.timelineText}>
                      <View style={styles.timelineTop}>
                        <Text style={styles.timelineTitle}>{item.title}</Text>
                        <Text style={styles.timelineTime}>
                          {new Date(item.at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
                        </Text>
                      </View>
                      {item.detail ? <Text style={styles.timelineDetail}>{item.detail}</Text> : null}
                    </View>
                  </View>
                ))}
              </View>
            </ScrollView>

            <View style={styles.composer}>
              {resultText ? <Text numberOfLines={2} style={styles.result}>{resultText}</Text> : null}
              <TextInput
                accessibilityLabel="Message to coding session"
                maxLength={COMMAND_LIMITS.messageCharacters}
                multiline
                onChangeText={setMessage}
                placeholder="Send an instruction…"
                placeholderTextColor={colors.subtle}
                style={styles.composerInput}
                value={message}
              />
              <AppButton label="Send message" disabled={!canWrite || !message.trim()} onPress={send} />
            </View>
          </>
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
  content: { padding: spacing.md, paddingBottom: spacing.lg, gap: spacing.lg, maxWidth: 760, width: "100%", alignSelf: "center" },
  section: { gap: spacing.sm },
  sectionTitle: { color: colors.text, fontSize: 14, fontWeight: "800" },
  responseHeading: { flexDirection: "row", alignItems: "center", justifyContent: "space-between" },
  liveText: { color: colors.info, fontSize: 10, fontWeight: "900" },
  responseCard: { backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, padding: spacing.md, gap: spacing.sm },
  streamingResponseCard: { borderLeftColor: colors.info, borderLeftWidth: 3 },
  response: { color: colors.text, fontSize: 14, lineHeight: 22 },
  streamNotice: { color: colors.subtle, fontSize: 11 },
  timelineItem: { flexDirection: "row", gap: spacing.sm },
  timelineDot: { width: 7, height: 7, borderRadius: 4, backgroundColor: colors.accent, marginTop: 6 },
  timelineText: { flex: 1, paddingBottom: spacing.sm, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.border, gap: 4 },
  timelineTop: { flexDirection: "row", gap: spacing.sm },
  timelineTitle: { flex: 1, color: colors.text, fontSize: 13, fontWeight: "700" },
  timelineTime: { color: colors.subtle, fontSize: 11 },
  timelineDetail: { color: colors.muted, fontSize: 13, lineHeight: 18 },
  composer: { backgroundColor: colors.surface, borderTopWidth: 1, borderTopColor: colors.border, padding: spacing.md, gap: spacing.sm },
  composerInput: { minHeight: 58, maxHeight: 130, color: colors.text, backgroundColor: colors.background, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, padding: 11, fontSize: 14, textAlignVertical: "top" },
  result: { color: colors.muted, fontSize: 11 },
});
