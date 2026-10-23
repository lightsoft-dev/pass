import { Stack, useFocusEffect, useLocalSearchParams, useRouter } from "expo-router";
import { useCallback, useEffect, useRef, useState } from "react";
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

import { Screen } from "../components/Screen";
import { useAdaptiveLayout } from "../hooks/useAdaptiveLayout";
import { utf8ByteLength } from "../protocol/commands";
import type { RemoteSession } from "../protocol/types";
import { useRemote } from "../state/RemoteProvider";
import { selectProjectSessionGroups } from "../state/selectors";
import { colors, radius, spacing } from "../theme/theme";

const MAX_PA_MESSAGE_BYTES = 8 * 1_024;
const PA_REFRESH_MS = 5_000;

function workerState(session: RemoteSession): string {
  if (session.unacknowledged) return "Needs review";
  switch (session.attention.status) {
    case "decision": return "Decision needed";
    case "input": return "Input needed";
    case "working": return "Working";
    case "finished": return "Finished";
    case "idle": return "Idle";
  }
}

export default function ProjectScreen() {
  const params = useLocalSearchParams<{ root?: string | string[] }>();
  const projectRoot = typeof params.root === "string" ? params.root : undefined;
  const { isRegular } = useAdaptiveLayout();
  const router = useRouter();
  const { state, getProjectAgent, sendProjectAgent } = useRemote();
  const getProjectAgentRef = useRef(getProjectAgent);
  getProjectAgentRef.current = getProjectAgent;
  const pollingBlockedRef = useRef(false);
  const lastSentDraftRef = useRef("");
  const sendInFlightRef = useRef(false);
  const messageScrollRef = useRef<ScrollView>(null);
  const nearLatestMessageRef = useRef(true);
  const positionedHistoryRef = useRef(false);
  const [message, setMessage] = useState("");
  const [sendInFlight, setSendInFlight] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [lastGetCommandId, setLastGetCommandId] = useState<string | null>(null);
  const [lastSendCommandId, setLastSendCommandId] = useState<string | null>(null);

  // Treat the route parameter as an opaque project key. Only a registered snapshot root can
  // trigger Pa commands; no manual path decoding or substring matching is needed.
  const project = projectRoot ? state.projectsByRoot[projectRoot] : undefined;
  const group = projectRoot
    ? selectProjectSessionGroups(state).find((item) => item.rootPath === projectRoot)
    : undefined;
  const workers = group?.sessions ?? [];
  const agent = projectRoot ? state.projectAgentsByRoot[projectRoot] : undefined;
  const online = state.connection.phase === "online";
  const canReadPa = online && state.capabilities.includes("sessions:read");
  const getCommandError = lastGetCommandId
    ? state.pendingCommands[lastGetCommandId]?.error : undefined;
  const sendCommandError = lastSendCommandId
    ? state.pendingCommands[lastSendCommandId]?.error : undefined;

  useEffect(() => {
    nearLatestMessageRef.current = true;
    positionedHistoryRef.current = false;
    sendInFlightRef.current = false;
    setSendInFlight(false);
    setLastSendCommandId(null);
  }, [projectRoot]);

  useEffect(() => {
    if (!positionedHistoryRef.current || !nearLatestMessageRef.current) return;
    const frame = requestAnimationFrame(() => {
      messageScrollRef.current?.scrollToEnd({ animated: true });
    });
    return () => cancelAnimationFrame(frame);
  }, [agent?.messages]);

  useEffect(() => {
    if (!getCommandError) return;
    pollingBlockedRef.current = true;
    setActionError(getCommandError);
  }, [getCommandError]);

  useEffect(() => {
    if (!sendCommandError) return;
    sendInFlightRef.current = false;
    setSendInFlight(false);
    setActionError(sendCommandError);
    setMessage((current) => current || lastSentDraftRef.current);
    lastSentDraftRef.current = "";
  }, [sendCommandError]);

  useEffect(() => {
    if (!projectRoot || !lastSendCommandId ||
        state.projectAgentReplyToByRoot[projectRoot] !== lastSendCommandId) return;
    sendInFlightRef.current = false;
    setSendInFlight(false);
    setLastSendCommandId(null);
    lastSentDraftRef.current = "";
  }, [projectRoot, lastSendCommandId, state.projectAgentReplyToByRoot]);

  useEffect(() => {
    if (online) return;
    sendInFlightRef.current = false;
    setSendInFlight(false);
  }, [online]);

  useFocusEffect(useCallback(() => {
    if (!projectRoot || !project || !canReadPa) return;
    pollingBlockedRef.current = false;
    const poll = () => {
      if (pollingBlockedRef.current) return;
      const result = getProjectAgentRef.current(projectRoot);
      if (result.ok) setLastGetCommandId(result.commandId);
      else {
        pollingBlockedRef.current = true;
        setActionError(result.error);
      }
    };
    poll();
    const timer = setInterval(poll, PA_REFRESH_MS);
    return () => clearInterval(timer);
  }, [projectRoot, Boolean(project), canReadPa]));

  if (!projectRoot || !project) {
    return (
      <Screen edges={["left", "right", "bottom"]} style={styles.missing}>
        <Stack.Screen options={{ title: "Project" }} />
        <Text style={styles.missingTitle}>Project unavailable</Text>
        <Text style={styles.muted}>It may have been removed from the paired desktop.</Text>
      </Screen>
    );
  }

  const draft = message.trim();
  const tooLong = utf8ByteLength(draft) > MAX_PA_MESSAGE_BYTES;
  const canSend = canReadPa && state.capabilities.includes("sessions:write") &&
    agent?.isReady === true && !sendInFlight &&
    draft.length > 0 && !tooLong;

  const send = () => {
    if (!canSend || sendInFlightRef.current) return;
    const result = sendProjectAgent(projectRoot, draft);
    if (result.ok) {
      sendInFlightRef.current = true;
      setSendInFlight(true);
      lastSentDraftRef.current = draft;
      setLastSendCommandId(result.commandId);
      setMessage("");
      setActionError(null);
    } else {
      setActionError(result.error);
    }
  };

  return (
    <Screen edges={["left", "right", "bottom"]}>
      <Stack.Screen options={{ title: project.name }} />
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        keyboardVerticalOffset={90}
        style={styles.flex}
      >
        <View style={styles.projectHeader}>
          <View style={[styles.projectHeaderContent, isRegular && styles.projectHeaderRegular]}>
            <Text style={styles.projectEmoji}>{project.emoji || "▣"}</Text>
            <View style={styles.projectIdentity}>
              <Text numberOfLines={1} style={styles.projectName}>{project.name}</Text>
              <Text numberOfLines={1} style={styles.projectPath}>{project.rootPath}</Text>
            </View>
            {group && group.attentionCount > 0 ? (
              <View style={styles.attentionBadge}>
                <Text style={styles.attentionText}>{group.attentionCount} need you</Text>
              </View>
            ) : null}
          </View>
        </View>

        <View style={[styles.body, isRegular && styles.bodyRegular]}>
          <View style={isRegular ? styles.workersPaneRegular : styles.workersPane}>
            <View style={styles.paneHeader}>
              <Text style={styles.paneTitle}>Workers</Text>
              <Text style={styles.paneCount}>{workers.length}</Text>
            </View>
            <ScrollView
              contentContainerStyle={styles.workersContent}
              keyboardShouldPersistTaps="handled"
            >
              {workers.length === 0 ? (
                <Text style={styles.emptyText}>No workers yet. Give Pa a task to get started.</Text>
              ) : (
                workers.map((worker) => (
                  <Pressable
                    key={worker.name}
                    accessibilityRole="button"
                    accessibilityLabel={`Open ${worker.displayName} worker`}
                    onPress={() => router.push({ pathname: "/session/[name]", params: { name: worker.name } })}
                    style={({ pressed }) => [styles.workerRow, pressed && styles.pressed]}
                  >
                    <View style={styles.workerIdentity}>
                      <Text numberOfLines={1} style={styles.workerName}>{worker.displayName}</Text>
                      <Text style={styles.workerMeta}>{worker.agent} · {workerState(worker)}</Text>
                    </View>
                    <Text style={styles.workerArrow}>›</Text>
                  </Pressable>
                ))
              )}
            </ScrollView>
          </View>

          <View style={styles.chatPane}>
            <View style={styles.paneHeader}>
              <View style={styles.paMark}><Text style={styles.paMarkText}>Pa</Text></View>
              <View style={styles.paIdentity}>
                <Text style={styles.paneTitle}>Project agent</Text>
                <Text numberOfLines={1} style={styles.paMeta}>
                  {agent?.modelLabel || "Pa"} · {!online ? "Desktop offline" : !canReadPa ?
                    "Read access unavailable" : (agent?.status || "Connecting…")}
                </Text>
              </View>
              {agent?.isResponding ? <Text style={styles.thinking}>Working…</Text> : null}
            </View>
            <ScrollView
              contentContainerStyle={styles.messagesContent}
              keyboardShouldPersistTaps="handled"
              onContentSizeChange={() => {
                if (!positionedHistoryRef.current && agent?.messages.length) {
                  messageScrollRef.current?.scrollToEnd({ animated: false });
                  positionedHistoryRef.current = true;
                  return;
                }
                if (nearLatestMessageRef.current) {
                  messageScrollRef.current?.scrollToEnd({ animated: true });
                }
              }}
              onScroll={({ nativeEvent }) => {
                if (!positionedHistoryRef.current) return;
                const distanceFromBottom = nativeEvent.contentSize.height -
                  nativeEvent.layoutMeasurement.height - nativeEvent.contentOffset.y;
                nearLatestMessageRef.current = distanceFromBottom < 96;
              }}
              ref={messageScrollRef}
              scrollEventThrottle={32}
            >
              {agent?.truncated ? (
                <Text style={styles.emptyText}>Earlier messages were omitted from this view.</Text>
              ) : null}
              {agent?.messages.length ? (
                agent.messages.map((entry) => (
                  <View
                    key={entry.id}
                    style={[
                      styles.message,
                      entry.role === "user" && styles.userMessage,
                      entry.role === "activity" && styles.activityMessage,
                      entry.role === "notice" && styles.noticeMessage,
                      entry.role === "error" && styles.errorMessage,
                    ]}
                  >
                    <Text style={[
                      styles.messageRole,
                      entry.role === "notice" && styles.noticeText,
                      entry.role === "error" && styles.errorText,
                    ]}>
                      {entry.role === "assistant" ? "Pa" :
                        entry.role === "user" ? "You" :
                        entry.role === "activity" ? "Activity" :
                          entry.role === "notice" ? "Notice" : "Error"}
                    </Text>
                    <Text style={[styles.messageText, entry.role === "notice" && styles.noticeText]}>
                      {entry.text}{entry.truncated ? "\n… message truncated" : ""}
                    </Text>
                  </View>
                ))
              ) : (
                <View style={styles.emptyChat}>
                  <Text style={styles.emptyChatTitle}>Work with Pa</Text>
                  <Text style={styles.emptyText}>
                    Ask the project agent to coordinate your workers and follow their progress.
                  </Text>
                </View>
              )}
            </ScrollView>
            <View style={styles.composer}>
              {actionError ? <Text style={styles.actionError}>{actionError}</Text> : null}
              {tooLong ? (
                <Text style={styles.actionError}>Message must be 8 KB or less.</Text>
              ) : null}
              <View style={styles.composerRow}>
                <TextInput
                  accessibilityLabel="Message to Pa"
                  multiline
                  onChangeText={setMessage}
                  placeholder="Ask Pa to work on this project…"
                  placeholderTextColor={colors.subtle}
                  style={styles.composerInput}
                  value={message}
                />
                <Pressable
                  accessibilityRole="button"
                  accessibilityLabel="Send message to Pa"
                  disabled={!canSend}
                  onPress={send}
                  style={({ pressed }) => [
                    styles.sendButton,
                    !canSend && styles.sendDisabled,
                    pressed && canSend && styles.pressed,
                  ]}
                >
                  <Text style={styles.sendIcon}>↑</Text>
                </Pressable>
              </View>
            </View>
          </View>
        </View>
      </KeyboardAvoidingView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
  missing: { alignItems: "center", justifyContent: "center", padding: spacing.lg, gap: spacing.sm },
  missingTitle: { color: colors.text, fontSize: 18, fontWeight: "800" },
  muted: { color: colors.muted, fontSize: 13, lineHeight: 19, textAlign: "center" },
  projectHeader: { backgroundColor: colors.surface, borderBottomWidth: 1, borderBottomColor: colors.border },
  projectHeaderContent: { minHeight: 78, paddingHorizontal: spacing.md, paddingVertical: spacing.sm, flexDirection: "row", alignItems: "center", gap: spacing.sm },
  projectHeaderRegular: { width: "100%", maxWidth: 1_040, alignSelf: "center", paddingHorizontal: spacing.lg },
  projectEmoji: { fontSize: 26, width: 36, textAlign: "center" },
  projectIdentity: { flex: 1, minWidth: 0, gap: 3 },
  projectName: { color: colors.text, fontSize: 19, fontWeight: "800" },
  projectPath: { color: colors.subtle, fontSize: 11 },
  attentionBadge: { backgroundColor: "#624221", borderRadius: radius.pill, paddingHorizontal: 9, paddingVertical: 6 },
  attentionText: { color: colors.warning, fontSize: 11, fontWeight: "800" },
  body: { flex: 1, width: "100%", alignSelf: "center" },
  bodyRegular: { maxWidth: 1_040, flexDirection: "row", padding: spacing.lg, gap: spacing.md },
  workersPane: { maxHeight: 190, borderBottomWidth: 1, borderBottomColor: colors.border },
  workersPaneRegular: { width: 300, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, backgroundColor: colors.surface },
  paneHeader: { minHeight: 49, paddingHorizontal: spacing.md, paddingVertical: spacing.sm, flexDirection: "row", alignItems: "center", gap: spacing.sm, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.border },
  paneTitle: { color: colors.text, fontSize: 14, fontWeight: "800" },
  paneCount: { color: colors.muted, fontSize: 12 },
  workersContent: { gap: 6, padding: spacing.sm },
  emptyText: { color: colors.muted, fontSize: 13, lineHeight: 19 },
  workerRow: { minHeight: 52, flexDirection: "row", alignItems: "center", gap: spacing.sm, backgroundColor: colors.raised, borderRadius: radius.sm, paddingHorizontal: spacing.sm, paddingVertical: 7 },
  workerIdentity: { flex: 1, minWidth: 0, gap: 3 },
  workerName: { color: colors.text, fontSize: 13, fontWeight: "700" },
  workerMeta: { color: colors.muted, fontSize: 10, textTransform: "capitalize" },
  workerArrow: { color: colors.subtle, fontSize: 21 },
  chatPane: { flex: 1, minHeight: 0, backgroundColor: colors.background },
  paMark: { width: 28, height: 28, borderRadius: radius.sm, backgroundColor: colors.accentSoft, alignItems: "center", justifyContent: "center" },
  paMarkText: { color: colors.accent, fontSize: 11, fontWeight: "900" },
  paIdentity: { flex: 1, minWidth: 0, gap: 2 },
  paMeta: { color: colors.muted, fontSize: 10 },
  thinking: { color: colors.info, fontSize: 10, fontWeight: "700" },
  messagesContent: { flexGrow: 1, gap: spacing.sm, padding: spacing.md },
  message: { maxWidth: "90%", alignSelf: "flex-start", backgroundColor: colors.surface, borderColor: colors.border, borderWidth: 1, borderRadius: radius.md, padding: spacing.sm, gap: 5 },
  userMessage: { alignSelf: "flex-end", backgroundColor: colors.accentSoft, borderColor: colors.accent },
  activityMessage: { maxWidth: "100%", backgroundColor: colors.raised },
  noticeMessage: { maxWidth: "100%", alignSelf: "center", backgroundColor: "transparent", borderWidth: 0 },
  noticeText: { color: colors.muted, textAlign: "center" },
  errorMessage: { maxWidth: "100%", borderColor: colors.danger },
  messageRole: { color: colors.muted, fontSize: 10, fontWeight: "800" },
  errorText: { color: colors.danger },
  messageText: { color: colors.text, fontSize: 13, lineHeight: 20 },
  emptyChat: { flex: 1, justifyContent: "center", alignItems: "center", gap: spacing.sm, padding: spacing.xl },
  emptyChatTitle: { color: colors.text, fontSize: 17, fontWeight: "800" },
  composer: { borderTopWidth: 1, borderTopColor: colors.border, backgroundColor: colors.surface, padding: spacing.sm, gap: spacing.xs },
  composerRow: { flexDirection: "row", alignItems: "flex-end", gap: spacing.sm },
  composerInput: { flex: 1, minHeight: 44, maxHeight: 120, color: colors.text, backgroundColor: colors.raised, borderColor: colors.border, borderWidth: 1, borderRadius: radius.sm, paddingHorizontal: 12, paddingVertical: 10, fontSize: 14, lineHeight: 20, textAlignVertical: "top" },
  sendButton: { width: 44, height: 44, backgroundColor: colors.accent, borderRadius: radius.sm, alignItems: "center", justifyContent: "center" },
  sendDisabled: { backgroundColor: colors.raised, opacity: 0.6 },
  sendIcon: { color: colors.white, fontSize: 22, fontWeight: "900" },
  actionError: { color: colors.danger, fontSize: 11, lineHeight: 15 },
  pressed: { opacity: 0.7 },
});
