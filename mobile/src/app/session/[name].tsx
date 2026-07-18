import { Stack, useLocalSearchParams } from "expo-router";
import { useMemo, useState } from "react";
import {
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";

import { AppButton } from "../../components/AppButton";
import { Screen } from "../../components/Screen";
import { COMMAND_LIMITS } from "../../protocol/commands";
import { useRemote } from "../../state/RemoteProvider";
import { colors, radius, spacing } from "../../theme/theme";

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
  const { state, sendMessage, answerDecision } = useRemote();
  const session = sessionName ? state.sessionsByName[sessionName] : undefined;
  const [message, setMessage] = useState("");
  const [resultText, setResultText] = useState<string | null>(null);
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
  const canDecide =
    canWrite && state.capabilities.includes("decisions:answer");

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
    setResultText(
      result.ok ? "Decision sent. Waiting for the desktop acknowledgement." : result.error,
    );
  };

  return (
    <Screen edges={["left", "right", "bottom"]}>
      <Stack.Screen options={{ title: session.displayName }} />
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        keyboardVerticalOffset={90}
        style={styles.flex}
      >
        <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
          <View style={styles.heading}>
            <Text style={styles.title}>{session.displayName}</Text>
            {session.displayName !== session.defaultDisplayName ? (
              <Text style={styles.muted}>{session.defaultDisplayName}</Text>
            ) : null}
            <View style={styles.metaRow}>
              <Text style={styles.meta}>{session.agent}</Text>
              {session.gitBranch ? <Text style={styles.meta}>⌥ {session.gitBranch}</Text> : null}
              <Text style={styles.meta}>{labelForStatus(session.attention.status)}</Text>
            </View>
          </View>

          {(session.attention.status === "decision" || session.attention.status === "input") ? (
            <View style={styles.attentionCard}>
              <Text style={styles.attentionTitle}>{labelForStatus(session.attention.status)}</Text>
              <Text style={styles.attentionText}>
                {session.attention.preview || "Open the desktop for the full prompt."}
              </Text>
              {session.attention.status === "decision" ? (
                <View style={styles.decisionActions}>
                  <AppButton
                    compact
                    label="Allow once"
                    disabled={!canDecide}
                    onPress={() => decide("allowOnce")}
                  />
                  <AppButton
                    compact
                    variant="secondary"
                    label="Allow all"
                    disabled={!canDecide}
                    onPress={() => decide("allowAll")}
                  />
                  <AppButton
                    compact
                    variant="danger"
                    label="Deny"
                    disabled={!canDecide}
                    onPress={() => decide("deny")}
                  />
                </View>
              ) : null}
            </View>
          ) : null}

          <View style={styles.section}>
            <Text style={styles.sectionTitle}>Last assistant response</Text>
            <View style={styles.responseCard}>
              <Text style={session.lastMessage ? styles.response : styles.muted}>
                {session.lastMessage || "No completed response has been published yet."}
              </Text>
            </View>
          </View>

          <View style={styles.section}>
            <Text style={styles.sectionTitle}>Mobile activity</Text>
            {timeline.length === 0 ? (
              <Text style={styles.muted}>Messages and attention changes from this app appear here.</Text>
            ) : (
              timeline.map((item) => (
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
                    {item.status ? <Text style={styles.timelineStatus}>{item.status}</Text> : null}
                  </View>
                </View>
              ))
            )}
          </View>
        </ScrollView>

        <View style={styles.composer}>
          {resultText ? <Text style={styles.result}>{resultText}</Text> : null}
          <TextInput
            accessibilityLabel="Message to coding session"
            maxLength={COMMAND_LIMITS.messageCharacters}
            multiline
            onChangeText={setMessage}
            placeholder="Send an instruction to this coding session…"
            placeholderTextColor={colors.subtle}
            style={styles.composerInput}
            value={message}
          />
          <AppButton label="Send message" disabled={!canWrite || !message.trim()} onPress={send} />
        </View>
      </KeyboardAvoidingView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
  missing: { alignItems: "center", justifyContent: "center", padding: spacing.lg, gap: spacing.sm },
  content: { padding: spacing.md, paddingBottom: spacing.lg, gap: spacing.lg, maxWidth: 760, width: "100%", alignSelf: "center" },
  heading: { gap: spacing.xs },
  title: { color: colors.text, fontSize: 24, fontWeight: "800" },
  muted: { color: colors.muted, fontSize: 14, lineHeight: 20 },
  metaRow: { flexDirection: "row", flexWrap: "wrap", gap: spacing.sm },
  meta: { color: colors.subtle, fontSize: 12, textTransform: "capitalize" },
  attentionCard: { backgroundColor: "#2a2216", borderWidth: 1, borderColor: "#60481f", borderRadius: radius.lg, padding: spacing.md, gap: spacing.sm },
  attentionTitle: { color: colors.warning, fontSize: 15, fontWeight: "800" },
  attentionText: { color: colors.text, fontSize: 14, lineHeight: 21 },
  decisionActions: { flexDirection: "row", flexWrap: "wrap", gap: spacing.sm },
  section: { gap: spacing.sm },
  sectionTitle: { color: colors.text, fontSize: 15, fontWeight: "800" },
  responseCard: { backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, padding: spacing.md },
  response: { color: colors.text, fontSize: 14, lineHeight: 22 },
  timelineItem: { flexDirection: "row", gap: spacing.sm },
  timelineDot: { width: 8, height: 8, borderRadius: 4, backgroundColor: colors.accent, marginTop: 6 },
  timelineText: { flex: 1, paddingBottom: spacing.sm, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.border, gap: 4 },
  timelineTop: { flexDirection: "row", gap: spacing.sm },
  timelineTitle: { flex: 1, color: colors.text, fontSize: 13, fontWeight: "700" },
  timelineTime: { color: colors.subtle, fontSize: 11 },
  timelineDetail: { color: colors.muted, fontSize: 13, lineHeight: 18 },
  timelineStatus: { color: colors.accent, fontSize: 10, textTransform: "uppercase", fontWeight: "800" },
  composer: { backgroundColor: colors.surface, borderTopWidth: 1, borderTopColor: colors.border, padding: spacing.md, gap: spacing.sm },
  composerInput: { minHeight: 70, maxHeight: 150, color: colors.text, backgroundColor: colors.background, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, padding: 12, fontSize: 14, textAlignVertical: "top" },
  result: { color: colors.muted, fontSize: 12 },
});
