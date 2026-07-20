import { StyleSheet, Text, View } from "react-native";

import type { ConnectionPhase } from "../state/reducer";
import { colors, radius } from "../theme/theme";

const labels: Record<ConnectionPhase, string> = {
  unconfigured: "Not paired",
  disconnected: "Paused",
  connecting: "Connecting",
  authenticating: "Checking desktop",
  online: "Desktop online",
  "desktop-offline": "Desktop offline",
  reconnecting: "Reconnecting",
  error: "Connection error",
};

export function ConnectionPill({ phase }: { phase: ConnectionPhase }) {
  const color =
    phase === "online"
      ? colors.success
      : phase === "desktop-offline" || phase === "error"
        ? colors.danger
        : phase === "reconnecting" || phase === "authenticating"
          ? colors.warning
          : colors.muted;
  return (
    <View style={styles.pill}>
      <View style={[styles.dot, { backgroundColor: color }]} />
      <Text style={styles.text}>{labels[phase]}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  pill: {
    flexDirection: "row",
    alignItems: "center",
    alignSelf: "flex-start",
    gap: 7,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.pill,
    paddingVertical: 7,
    paddingHorizontal: 11,
    backgroundColor: colors.surface,
  },
  dot: { width: 8, height: 8, borderRadius: 4 },
  text: { color: colors.muted, fontSize: 12, fontWeight: "700" },
});
