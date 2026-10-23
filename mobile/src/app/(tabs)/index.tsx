import { useRouter } from "expo-router";
import { useMemo, useState } from "react";
import { Pressable, RefreshControl, ScrollView, StyleSheet, Text, View } from "react-native";

import { AppButton } from "../../components/AppButton";
import { ConnectionPill } from "../../components/ConnectionPill";
import { Screen } from "../../components/Screen";
import { SessionCard } from "../../components/SessionCard";
import { useAdaptiveLayout } from "../../hooks/useAdaptiveLayout";
import { useRemote } from "../../state/RemoteProvider";
import { selectProjectSessionGroups } from "../../state/selectors";
import { colors, spacing } from "../../theme/theme";

export default function InboxScreen() {
  const router = useRouter();
  const { isRegular, isWide } = useAdaptiveLayout();
  const { state, pairedDesktop, refresh } = useRemote();
  const [refreshing, setRefreshing] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [collapsedRoots, setCollapsedRoots] = useState<Set<string>>(() => new Set());
  const projectGroups = useMemo(() => selectProjectSessionGroups(state), [state]);
  const attentionCount = projectGroups.reduce((count, group) => count + group.attentionCount, 0);
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

  const openProject = (root: string) => {
    router.push({ pathname: "/project", params: { root } });
  };

  const toggleProject = (root: string) => {
    setCollapsedRoots((current) => {
      const next = new Set(current);
      if (next.has(root)) next.delete(root);
      else next.add(root);
      return next;
    });
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
            <Text style={[styles.title, isRegular && styles.titleRegular]}>Projects</Text>
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

        <View style={styles.section}>
          <View style={styles.sectionHeader}>
            <Text style={styles.sectionTitle}>Your projects</Text>
            <Text style={styles.count}>{projectGroups.length}</Text>
            {attentionCount > 0 ? (
              <Text style={styles.attentionTotal}>{attentionCount} need you</Text>
            ) : null}
          </View>
          {projectGroups.length === 0 ? (
            <View style={styles.empty}>
              <Text style={styles.emptyTitle}>
                {state.connection.phase === "online" ? "No projects yet" : "Waiting for desktop"}
              </Text>
              <Text style={styles.emptyText}>
                {state.connection.phase === "online"
                  ? "Register a project in Pass on your Mac to see it here."
                  : "Keep Pass open on the paired Mac; your projects update from snapshots."}
              </Text>
            </View>
          ) : (
            projectGroups.map((group) => {
              const collapsed = collapsedRoots.has(group.rootPath);
              return (
                <View key={group.rootPath} style={styles.projectGroup}>
                  <View style={styles.projectHeader}>
                    <Pressable
                      accessibilityRole="button"
                      accessibilityLabel={group.registered
                        ? `Open ${group.name} project`
                        : `${group.name} project is not registered`}
                      disabled={!group.registered}
                      onPress={() => openProject(group.rootPath)}
                      style={({ pressed }) => [styles.projectLink, pressed && styles.pressed]}
                    >
                      <Text style={styles.projectEmoji}>{group.emoji || "▣"}</Text>
                      <View style={styles.projectText}>
                        <Text numberOfLines={1} style={styles.projectName}>{group.name}</Text>
                        <Text numberOfLines={1} style={styles.projectMeta}>
                          {group.sessions.length} {group.sessions.length === 1 ? "worker" : "workers"}
                          {!group.registered ? " · Not registered" : " · Open Pa"}
                        </Text>
                      </View>
                      {group.attentionCount > 0 ? (
                        <View style={styles.attentionBadge}>
                          <Text style={styles.attentionBadgeText}>{group.attentionCount}</Text>
                        </View>
                      ) : null}
                    </Pressable>
                    <Pressable
                      accessibilityRole="button"
                      accessibilityLabel={`${collapsed ? "Expand" : "Collapse"} ${group.name} workers`}
                      accessibilityState={{ expanded: !collapsed }}
                      onPress={() => toggleProject(group.rootPath)}
                      style={({ pressed }) => [styles.collapseButton, pressed && styles.pressed]}
                    >
                      <Text style={styles.collapseIcon}>{collapsed ? "⌄" : "⌃"}</Text>
                    </Pressable>
                  </View>
                  {!collapsed ? (
                    <View style={styles.workerList}>
                      {group.sessions.length === 0 ? (
                        <Text style={styles.noWorkers}>No workers yet. Open Pa to start a task.</Text>
                      ) : (
                        group.sessions.map((session) => (
                          <SessionCard
                            key={session.name}
                            session={session}
                            stream={state.messageStreamsBySession[session.name]}
                            onPress={() => openSession(session.name)}
                          />
                        ))
                      )}
                    </View>
                  ) : null}
                </View>
              );
            })
          )}
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
  section: { gap: spacing.sm },
  sectionHeader: { flexDirection: "row", alignItems: "center", gap: spacing.sm },
  sectionTitle: { color: colors.text, fontSize: 15, fontWeight: "800" },
  count: { color: colors.muted, fontSize: 12 },
  attentionTotal: { marginLeft: "auto", color: colors.warning, fontSize: 12, fontWeight: "700" },
  projectGroup: { backgroundColor: colors.surface, borderColor: colors.border, borderWidth: 1, borderRadius: 18, overflow: "hidden" },
  projectHeader: { flexDirection: "row", alignItems: "stretch", minHeight: 70 },
  projectLink: { flex: 1, minWidth: 0, flexDirection: "row", alignItems: "center", gap: spacing.sm, paddingHorizontal: spacing.md, paddingVertical: spacing.sm },
  projectEmoji: { color: colors.accent, fontSize: 21, width: 28, textAlign: "center" },
  projectText: { flex: 1, minWidth: 0, gap: 3 },
  projectName: { color: colors.text, fontSize: 16, fontWeight: "800" },
  projectMeta: { color: colors.muted, fontSize: 11 },
  attentionBadge: { minWidth: 22, height: 22, paddingHorizontal: 5, alignItems: "center", justifyContent: "center", borderRadius: 11, backgroundColor: "#624221" },
  attentionBadgeText: { color: colors.warning, fontSize: 12, fontWeight: "800" },
  collapseButton: { width: 48, alignItems: "center", justifyContent: "center", borderLeftWidth: StyleSheet.hairlineWidth, borderLeftColor: colors.border },
  collapseIcon: { color: colors.muted, fontSize: 23, fontWeight: "600" },
  workerList: { gap: spacing.sm, padding: spacing.sm, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: colors.border },
  noWorkers: { color: colors.muted, fontSize: 12, lineHeight: 18, padding: spacing.sm },
  pressed: { opacity: 0.7 },
  empty: { backgroundColor: colors.surface, borderColor: colors.border, borderWidth: 1, borderRadius: 18, padding: spacing.lg, gap: spacing.sm },
  emptyTitle: { color: colors.text, fontSize: 16, fontWeight: "700" },
  emptyText: { color: colors.muted, fontSize: 14, lineHeight: 21 },
  synced: { color: colors.subtle, textAlign: "center", fontSize: 11 },
});
