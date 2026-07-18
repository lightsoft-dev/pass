import { Pressable, StyleSheet, Text, View } from "react-native";

import type { RemoteSession } from "../protocol/types";
import { colors, radius, spacing } from "../theme/theme";

const agentGlyph: Record<RemoteSession["agent"], string> = {
  claude: "✳",
  codex: "⬢",
  pi: "π",
  shell: "$",
  generic: "•",
};

function statusMeta(session: RemoteSession) {
  if (
    session.unacknowledged &&
    session.attention.status !== "decision" &&
    session.attention.status !== "input"
  ) {
    return { label: "NEEDS REVIEW", color: colors.warning };
  }
  switch (session.attention.status) {
    case "decision":
      return { label: "DECISION", color: colors.danger };
    case "input":
      return { label: "NEEDS INPUT", color: colors.warning };
    case "working":
      return { label: "WORKING", color: colors.success };
    case "finished":
      return { label: "FINISHED", color: colors.info };
    case "idle":
      return { label: "IDLE", color: colors.muted };
  }
}

export function SessionCard({
  session,
  projectEmoji,
  onPress,
}: {
  session: RemoteSession;
  projectEmoji?: string | null;
  onPress: () => void;
}) {
  const status = statusMeta(session);
  const preview =
    session.attention.preview || session.lastMessage || "No completed response yet.";
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`Open ${session.displayName}`}
      onPress={onPress}
      style={({ pressed }) => [
        styles.card,
        (session.unacknowledged ||
          session.attention.status === "decision" ||
          session.attention.status === "input") &&
          styles.needsAttention,
        pressed && styles.pressed,
      ]}
    >
      <View style={styles.topRow}>
        <Text style={styles.title} numberOfLines={1}>
          {projectEmoji ? `${projectEmoji} ` : ""}
          {session.displayName}
        </Text>
        <Text style={[styles.status, { color: status.color }]}>{status.label}</Text>
      </View>
      <View style={styles.metaRow}>
        <Text style={styles.agent}>{agentGlyph[session.agent]} {session.agent}</Text>
        {session.gitBranch ? <Text style={styles.meta}>⌥ {session.gitBranch}</Text> : null}
        {session.launching ? <Text style={styles.meta}>Launching…</Text> : null}
      </View>
      <Text style={styles.preview} numberOfLines={3}>{preview}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: colors.surface,
    borderColor: colors.border,
    borderWidth: 1,
    borderRadius: radius.lg,
    padding: spacing.md,
    gap: spacing.sm,
  },
  needsAttention: { borderColor: colors.warning, backgroundColor: "#211d17" },
  pressed: { opacity: 0.8 },
  topRow: { flexDirection: "row", alignItems: "center", gap: spacing.sm },
  title: { flex: 1, color: colors.text, fontSize: 17, fontWeight: "700" },
  status: { fontSize: 10, fontWeight: "900", letterSpacing: 0.7 },
  metaRow: { flexDirection: "row", alignItems: "center", flexWrap: "wrap", gap: 10 },
  agent: { color: colors.muted, fontSize: 12, textTransform: "capitalize" },
  meta: { color: colors.subtle, fontSize: 12 },
  preview: { color: colors.muted, fontSize: 14, lineHeight: 20 },
});
