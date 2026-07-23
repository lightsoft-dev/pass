import { useRouter } from "expo-router";
import { Alert, ScrollView, StyleSheet, Switch, Text, View } from "react-native";

import { AppButton } from "../../components/AppButton";
import { ConnectionPill } from "../../components/ConnectionPill";
import { Screen } from "../../components/Screen";
import { useRemote } from "../../state/RemoteProvider";
import { colors, radius, spacing } from "../../theme/theme";

function SettingSwitch({
  title,
  detail,
  value,
  onValueChange,
}: {
  title: string;
  detail: string;
  value: boolean;
  onValueChange: (value: boolean) => void;
}) {
  return (
    <View style={styles.settingRow}>
      <View style={styles.settingText}>
        <Text style={styles.settingTitle}>{title}</Text>
        <Text style={styles.settingDetail}>{detail}</Text>
      </View>
      <Switch
        value={value}
        onValueChange={onValueChange}
        trackColor={{ false: colors.border, true: colors.accentSoft }}
        thumbColor={value ? colors.accent : colors.muted}
      />
    </View>
  );
}

export default function SettingsScreen() {
  const router = useRouter();
  const {
    state,
    pairedDesktop,
    userSession,
    preferences,
    reconnect,
    updatePreferences,
    forgetPairing,
    signOut,
  } = useRemote();

  const deviceCredential = pairedDesktop?.authenticationMode === "device";

  const unpair = () => {
    Alert.alert(
      "Forget paired desktop?",
      deviceCredential
        ? "This removes this phone's credentials from local secure storage."
        : "This removes the shared relay token from SecureStore on this device.",
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Forget",
          style: "destructive",
          onPress: () => {
            void forgetPairing()
              .then(() => router.replace("/pair"))
              .catch((error: unknown) => {
                Alert.alert(
                  "Could not forget desktop",
                  error instanceof Error ? error.message : "Device revocation failed.",
                );
              });
          },
        },
      ],
    );
  };

  return (
    <Screen>
      <ScrollView contentContainerStyle={styles.content}>
        <View style={styles.header}>
          <Text style={styles.eyebrow}>PASS REMOTE</Text>
          <Text style={styles.title}>Settings</Text>
          <ConnectionPill phase={state.connection.phase} />
        </View>

        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Paired desktop</Text>
          <View style={styles.card}>
            <View style={styles.valueRow}>
              <Text style={styles.valueLabel}>Name</Text>
              <Text style={styles.value} numberOfLines={1}>{pairedDesktop?.desktopName}</Text>
            </View>
            <View style={styles.valueRow}>
              <Text style={styles.valueLabel}>Desktop id</Text>
              <Text style={styles.value} numberOfLines={1}>{pairedDesktop?.desktopId}</Text>
            </View>
            <View style={styles.valueRow}>
              <Text style={styles.valueLabel}>Relay</Text>
              <Text style={styles.value} numberOfLines={2}>{pairedDesktop?.relayUrl}</Text>
            </View>
            <View style={styles.valueRow}>
              <Text style={styles.valueLabel}>Credential</Text>
              <Text style={styles.secureValue}>
                {deviceCredential ? "Device-scoped" : "Shared development token"}
              </Text>
            </View>
          </View>
          <View style={styles.buttonRow}>
            <AppButton compact variant="secondary" label="Reconnect" onPress={reconnect} />
            <AppButton compact variant="danger" label="Forget desktop" onPress={unpair} />
          </View>
          {deviceCredential && userSession ? (
            <AppButton
              variant="secondary"
              label="Pair a Steam Deck"
              onPress={() => router.push("/pair-deck")}
            />
          ) : null}
        </View>

        {!deviceCredential ? (
          <View style={styles.devWarning}>
            <Text style={styles.devTitle}>Shared-token development mode</Text>
            <Text style={styles.devText}>
              This connection uses one reusable relay credential. Rotate it if exposed.
            </Text>
          </View>
        ) : null}

        {userSession ? (
          <View style={styles.section}>
            <Text style={styles.sectionTitle}>Account</Text>
            <AppButton
              variant="danger"
              label="Sign out"
              onPress={() => {
                void signOut()
                  .then(() => router.replace("/login"))
                  .catch((error: unknown) => {
                    Alert.alert(
                      "Could not sign out",
                      error instanceof Error ? error.message : "Device revocation failed.",
                    );
                  });
              }}
            />
          </View>
        ) : null}

        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Notification preferences</Text>
          <View style={styles.card}>
            <SettingSwitch
              title="Session notifications"
              detail="Persist the preference for relay push integration."
              value={preferences.notificationsEnabled}
              onValueChange={(value) => void updatePreferences({ notificationsEnabled: value })}
            />
            <View style={styles.separator} />
            <SettingSwitch
              title="Decision alerts"
              detail="Prioritize permission and decision requests."
              value={preferences.decisionAlerts}
              onValueChange={(value) => void updatePreferences({ decisionAlerts: value })}
            />
          </View>
          <Text style={styles.note}>Push registration is not included in this control-plane MVP.</Text>
        </View>

        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Granted desktop capabilities</Text>
          <View style={styles.scopeWrap}>
            {(state.capabilities.length ? state.capabilities : pairedDesktop?.scopes ?? []).map((scope) => (
              <View key={scope} style={styles.scope}><Text style={styles.scopeText}>{scope}</Text></View>
            ))}
          </View>
        </View>

        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Diagnostics</Text>
          <View style={styles.card}>
            <View style={styles.valueRow}>
              <Text style={styles.valueLabel}>Protocol</Text>
              <Text style={styles.value}>v{pairedDesktop?.protocolVersion ?? 1}</Text>
            </View>
            <View style={styles.valueRow}>
              <Text style={styles.valueLabel}>Relay sequence</Text>
              <Text style={styles.value}>{state.latestSequence}</Text>
            </View>
            <View style={styles.valueRow}>
              <Text style={styles.valueLabel}>Rejected frames</Text>
              <Text style={styles.value}>{state.protocolErrors}</Text>
            </View>
          </View>
        </View>
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: spacing.md, paddingBottom: spacing.xl, gap: spacing.lg, maxWidth: 680, width: "100%", alignSelf: "center" },
  header: { gap: spacing.sm },
  eyebrow: { color: colors.accent, fontSize: 11, fontWeight: "900", letterSpacing: 1.6 },
  title: { color: colors.text, fontSize: 28, fontWeight: "800" },
  section: { gap: spacing.sm },
  sectionTitle: { color: colors.text, fontSize: 15, fontWeight: "800" },
  card: { backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, padding: spacing.md, gap: spacing.md },
  valueRow: { flexDirection: "row", alignItems: "flex-start", gap: spacing.md },
  valueLabel: { width: 90, color: colors.subtle, fontSize: 12 },
  value: { flex: 1, color: colors.text, fontSize: 13, textAlign: "right" },
  secureValue: { flex: 1, color: colors.success, fontSize: 13, textAlign: "right" },
  buttonRow: { flexDirection: "row", gap: spacing.sm },
  devWarning: { backgroundColor: "#2a2216", borderWidth: 1, borderColor: "#55401f", borderRadius: radius.md, padding: spacing.md, gap: spacing.xs },
  devTitle: { color: colors.warning, fontSize: 13, fontWeight: "800" },
  devText: { color: "#c9b998", fontSize: 13, lineHeight: 19 },
  settingRow: { flexDirection: "row", alignItems: "center", gap: spacing.md },
  settingText: { flex: 1, gap: 3 },
  settingTitle: { color: colors.text, fontSize: 14, fontWeight: "700" },
  settingDetail: { color: colors.muted, fontSize: 12, lineHeight: 17 },
  separator: { height: StyleSheet.hairlineWidth, backgroundColor: colors.border },
  note: { color: colors.subtle, fontSize: 11 },
  scopeWrap: { flexDirection: "row", flexWrap: "wrap", gap: spacing.sm },
  scope: { backgroundColor: colors.accentSoft, borderRadius: radius.pill, paddingHorizontal: 10, paddingVertical: 7 },
  scopeText: { color: colors.accent, fontSize: 11, fontWeight: "700" },
});
