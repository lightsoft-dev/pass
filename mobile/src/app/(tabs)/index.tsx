import { useRouter } from "expo-router";
import { useMemo, useState } from "react";
import { RefreshControl, ScrollView, StyleSheet, Text, View } from "react-native";

import { AppButton } from "../../components/AppButton";
import { ConnectionPill } from "../../components/ConnectionPill";
import { Screen } from "../../components/Screen";
import { SessionCard } from "../../components/SessionCard";
import { useAdaptiveLayout } from "../../hooks/useAdaptiveLayout";
import { useRemote } from "../../state/RemoteProvider";
import { selectNeedsAttention, selectOtherSessions } from "../../state/selectors";
import { colors, spacing } from "../../theme/theme";

export default function InboxScreen() {
  const router = useRouter();
  const { isRegular, isWide } = useAdaptiveLayout();
  const { state, pairedDesktop, refresh } = useRemote();
  const [refreshing, setRefreshing] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const needsAttention = useMemo(() => selectNeedsAttention(state), [state]);
  const otherSessions = useMemo(() => selectOtherSessions(state), [state]);
  const canCreate =
    state.connection.phase === "online" && state.capabilities.includes("sessions:write");

  const doRefresh = () => {
    setRefreshing(true);
    const result = refresh();
    setActionError(result.ok ? null : result.error);
    setTimeout(() => setRefreshing(false), 500);
  };

  const openSession = (name: string) => {
    router.push({ pathname: "/session/[name]", params: { name } });
  };

  return (
    <Screen>
      <ScrollView
        contentContainerStyle={[
          styles.content,
          isRegular && styles.contentRegular,
          isWide && styles.contentWide,
        ]}
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={doRefresh} tintColor={colors.accent} />
        }
      >
        <View style={[styles.header, isRegular && styles.headerRegular]}>
          <View style={styles.headerText}>
            <Text style={styles.eyebrow}>PASS REMOTE</Text>
            <Text style={[styles.title, isRegular && styles.titleRegular]}>Session inbox</Text>
            <Text style={styles.desktop}>{pairedDesktop?.desktopName ?? "Paired desktop"}</Text>
          </View>
          <View style={[styles.headerActions, isRegular && styles.headerActionsRegular]}>
            <ConnectionPill phase={state.connection.phase} />
            <View style={styles.actions}>
              <AppButton compact variant="secondary" label="Refresh" onPress={doRefresh} />
              <AppButton
                compact
                label="New session"
                disabled={!canCreate}
                onPress={() => router.push("/create")}
              />
            </View>
          </View>
        </View>

        {state.connection.lastError || actionError ? (
          <Text style={styles.error}>{actionError ?? state.connection.lastError}</Text>
        ) : null}

        {state.snapshotTruncation ? (
          <View style={styles.truncationWarning}>
            <Text style={styles.truncationTitle}>Partial desktop snapshot</Text>
            <Text style={styles.truncationText}>
              Showing {state.snapshotTruncation.shownSessionCount} of{" "}
              {state.snapshotTruncation.totalSessionCount} sessions and{" "}
              {state.snapshotTruncation.shownProjectCount} of{" "}
              {state.snapshotTruncation.totalProjectCount} projects. Needs-you and recent
              items are retained first.
            </Text>
          </View>
        ) : null}

        <View style={[styles.sections, isWide && styles.sectionsWide]}>
          {needsAttention.length > 0 ? (
            <View style={[styles.section, isWide && styles.sectionWide]}>
              <View style={styles.sectionHeader}>
                <Text style={styles.sectionTitle}>Needs you</Text>
                <Text style={styles.count}>{needsAttention.length}</Text>
              </View>
              {needsAttention.map((session) => (
                <SessionCard
                  key={session.name}
                  session={session}
                  stream={state.messageStreamsBySession[session.name]}
                  projectEmoji={state.projectsByRoot[session.projectRoot]?.emoji}
                  onPress={() => openSession(session.name)}
                />
              ))}
            </View>
          ) : null}

          <View style={[styles.section, isWide && styles.sectionWide]}>
            <View style={styles.sectionHeader}>
              <Text style={styles.sectionTitle}>
                {needsAttention.length > 0 ? "Other sessions" : "All sessions"}
              </Text>
              <Text style={styles.count}>{otherSessions.length}</Text>
            </View>
            {otherSessions.length === 0 && needsAttention.length === 0 ? (
              <View style={styles.empty}>
                <Text style={styles.emptyTitle}>
                  {state.connection.phase === "online" ? "No live sessions" : "Waiting for desktop"}
                </Text>
                <Text style={styles.emptyText}>
                  {state.connection.phase === "online"
                    ? "Start a session from a registered project."
                    : "Keep Pass open on the paired Mac; this inbox updates from snapshots."}
                </Text>
              </View>
            ) : (
              otherSessions.map((session) => (
                <SessionCard
                  key={session.name}
                  session={session}
                  stream={state.messageStreamsBySession[session.name]}
                  projectEmoji={state.projectsByRoot[session.projectRoot]?.emoji}
                  onPress={() => openSession(session.name)}
                />
              ))
            )}
          </View>
        </View>

        {state.lastSyncedAt ? (
          <Text style={styles.synced}>
            Snapshot {new Date(state.lastSyncedAt).toLocaleTimeString()}
          </Text>
        ) : null}
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: spacing.md, paddingBottom: spacing.xl, gap: spacing.lg, maxWidth: 760, width: "100%", alignSelf: "center" },
  contentRegular: { padding: spacing.lg, maxWidth: 940 },
  contentWide: { maxWidth: 1_180 },
  header: { gap: spacing.md },
  headerRegular: { flexDirection: "row", alignItems: "flex-end", justifyContent: "space-between" },
  headerText: { gap: 4 },
  headerActions: { gap: spacing.sm },
  headerActionsRegular: { alignItems: "flex-end" },
  eyebrow: { color: colors.accent, fontSize: 11, fontWeight: "900", letterSpacing: 1.6 },
  title: { color: colors.text, fontSize: 28, fontWeight: "800" },
  titleRegular: { fontSize: 34 },
  desktop: { color: colors.muted, fontSize: 14 },
  actions: { flexDirection: "row", gap: spacing.sm },
  error: { color: colors.danger, fontSize: 13, lineHeight: 19 },
  truncationWarning: {
    backgroundColor: "#2a2216",
    borderColor: "#55401f",
    borderWidth: 1,
    borderRadius: 14,
    padding: spacing.md,
    gap: 4,
  },
  truncationTitle: { color: colors.warning, fontSize: 13, fontWeight: "800" },
  truncationText: { color: "#c9b998", fontSize: 12, lineHeight: 18 },
  sections: { gap: spacing.lg },
  sectionsWide: { flexDirection: "row", alignItems: "flex-start" },
  section: { gap: spacing.sm },
  sectionWide: { flex: 1, minWidth: 0 },
  sectionHeader: { flexDirection: "row", alignItems: "center", gap: spacing.sm },
  sectionTitle: { color: colors.text, fontSize: 15, fontWeight: "800" },
  count: { color: colors.muted, fontSize: 12 },
  empty: { backgroundColor: colors.surface, borderColor: colors.border, borderWidth: 1, borderRadius: 18, padding: spacing.lg, gap: spacing.sm },
  emptyTitle: { color: colors.text, fontSize: 16, fontWeight: "700" },
  emptyText: { color: colors.muted, fontSize: 14, lineHeight: 21 },
  synced: { color: colors.subtle, textAlign: "center", fontSize: 11 },
});
