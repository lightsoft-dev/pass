import { ScrollView, StyleSheet, Text, View } from "react-native";

import { AppButton } from "../../components/AppButton";
import { Screen } from "../../components/Screen";
import { useRemote } from "../../state/RemoteProvider";
import { colors, radius, spacing } from "../../theme/theme";

const voiceStates = ["connecting", "listening", "thinking", "speaking", "interrupted"];
const VOICE_TRANSPORT_IMPLEMENTED = false;

export default function VoiceScreen() {
  const { state, preferences, updatePreferences } = useRemote();
  const voiceAvailable =
    state.capabilities.includes("voice:use") && VOICE_TRANSPORT_IMPLEMENTED;

  return (
    <Screen>
      <ScrollView contentContainerStyle={styles.content}>
        <View style={styles.header}>
          <Text style={styles.eyebrow}>MANAGEMENT AGENT</Text>
          <Text style={styles.title}>Voice control</Text>
          <Text style={styles.subtitle}>
            A separate management conversation that can summarize and route structured actions.
          </Text>
        </View>

        <View style={styles.comingSoon}>
          <Text style={styles.comingSoonLabel}>FOLLOW-UP PHASE</Text>
          <Text style={styles.comingSoonTitle}>VoiceAgentCoordinator is not on the v1 wire</Text>
          <Text style={styles.comingSoonText}>
            Controls stay capability-gated until the desktop advertises voice:use and WebRTC
            credentials. No microphone audio is currently recorded or uploaded.
          </Text>
        </View>

        <View style={styles.orbArea}>
          <View style={styles.orbOuter}>
            <View style={styles.orb}><Text style={styles.orbGlyph}>◉</Text></View>
          </View>
          <Text style={styles.voiceState}>IDLE · UNAVAILABLE</Text>
          <View style={styles.stateRail}>
            {voiceStates.map((state) => <Text key={state} style={styles.stateLabel}>{state}</Text>)}
          </View>
        </View>

        <View style={styles.modeRow}>
          <AppButton
            compact
            variant={preferences.voiceMode === "push-to-talk" ? "primary" : "secondary"}
            label="Push to talk"
            onPress={() => void updatePreferences({ voiceMode: "push-to-talk" })}
            style={styles.modeButton}
          />
          <AppButton
            compact
            variant={preferences.voiceMode === "hands-free" ? "primary" : "secondary"}
            label="Hands free"
            onPress={() => void updatePreferences({ voiceMode: "hands-free" })}
            style={styles.modeButton}
          />
        </View>

        <AppButton label="Start management agent" disabled={!voiceAvailable} onPress={() => undefined} />
        <AppButton
          label="Interrupt speech"
          variant="danger"
          disabled={!voiceAvailable}
          onPress={() => undefined}
          style={styles.interrupt}
        />

        <View style={styles.auditCard}>
          <Text style={styles.auditTitle}>Shared audit trail</Text>
          <Text style={styles.auditText}>
            When enabled, voice-routed session commands will use the same command ids,
            relay receipts, and message.delivered confirmations as typed messages.
          </Text>
        </View>
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: spacing.md, paddingBottom: spacing.xl, gap: spacing.lg, maxWidth: 680, width: "100%", alignSelf: "center" },
  header: { gap: spacing.xs },
  eyebrow: { color: colors.accent, fontSize: 11, fontWeight: "900", letterSpacing: 1.6 },
  title: { color: colors.text, fontSize: 28, fontWeight: "800" },
  subtitle: { color: colors.muted, fontSize: 14, lineHeight: 21 },
  comingSoon: { backgroundColor: colors.accentSoft, borderColor: "#4a4384", borderWidth: 1, borderRadius: radius.lg, padding: spacing.md, gap: spacing.xs },
  comingSoonLabel: { color: colors.accent, fontSize: 10, fontWeight: "900", letterSpacing: 1.2 },
  comingSoonTitle: { color: colors.text, fontSize: 15, fontWeight: "800" },
  comingSoonText: { color: colors.muted, fontSize: 13, lineHeight: 19 },
  orbArea: { alignItems: "center", gap: spacing.md, paddingVertical: spacing.md },
  orbOuter: { width: 150, height: 150, borderRadius: 75, borderWidth: 1, borderColor: colors.border, alignItems: "center", justifyContent: "center" },
  orb: { width: 110, height: 110, borderRadius: 55, backgroundColor: colors.raised, alignItems: "center", justifyContent: "center" },
  orbGlyph: { color: colors.subtle, fontSize: 42 },
  voiceState: { color: colors.muted, fontSize: 11, fontWeight: "900", letterSpacing: 1.3 },
  stateRail: { flexDirection: "row", flexWrap: "wrap", justifyContent: "center", gap: spacing.sm },
  stateLabel: { color: colors.subtle, fontSize: 10 },
  modeRow: { flexDirection: "row", gap: spacing.sm },
  modeButton: { flex: 1 },
  interrupt: { minHeight: 64 },
  auditCard: { backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, padding: spacing.md, gap: spacing.xs },
  auditTitle: { color: colors.text, fontSize: 14, fontWeight: "800" },
  auditText: { color: colors.muted, fontSize: 13, lineHeight: 19 },
});
