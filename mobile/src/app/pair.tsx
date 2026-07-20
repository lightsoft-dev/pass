import { CameraView, useCameraPermissions } from "expo-camera";
import { Redirect, useRouter } from "expo-router";
import { useState } from "react";
import {
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";

import { AppButton } from "../components/AppButton";
import { Screen } from "../components/Screen";
import { publicOIDCConfiguration } from "../services/authService";
import { useRemote } from "../state/RemoteProvider";
import { colors, radius, spacing } from "../theme/theme";

const sampleRelay = process.env.EXPO_PUBLIC_PASS_RELAY_URL ?? "https://relay.example.com";

export default function PairScreen() {
  const router = useRouter();
  const { pair, pairingBusy, pairingError, userSession } = useRemote();
  const publicMode = publicOIDCConfiguration() !== null;
  const [permission, requestPermission] = useCameraPermissions();
  const [showScanner, setShowScanner] = useState(false);
  const [scanned, setScanned] = useState(false);
  const [rawPayload, setRawPayload] = useState("");

  const submit = async (payload = rawPayload) => {
    if (!payload.trim()) return;
    setScanned(true);
    setRawPayload(payload);
    const result = await pair(payload);
    if (result.ok) router.replace("/(tabs)");
    else setScanned(false);
  };

  const openScanner = () => {
    if (!permission?.granted) {
      void requestPermission().then((result) => {
        if (result.granted) setShowScanner(true);
      });
      return;
    }
    setScanned(false);
    setShowScanner(true);
  };

  if (publicMode && !userSession) return <Redirect href="/login" />;

  return (
    <Screen edges={["top", "bottom", "left", "right"]}>
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        style={styles.flex}
      >
        <ScrollView
          contentContainerStyle={styles.content}
          keyboardShouldPersistTaps="handled"
        >
          <View style={styles.hero}>
            <View style={styles.mark}><Text style={styles.markText}>P</Text></View>
            <Text style={styles.eyebrow}>PASS REMOTE</Text>
            <Text style={styles.title}>Pair your Mac</Text>
            <Text style={styles.subtitle}>
              {publicMode
                ? "Open Pass settings on your Mac and scan its one-time code."
                : "Scan a development pairing code from Pass on your Mac."}
            </Text>
          </View>

          {!publicMode ? (
            <View style={styles.warning}>
              <Text style={styles.warningTitle}>Development mode</Text>
              <Text style={styles.warningText}>
                This build accepts the reusable relay token from a v1 pairing code.
              </Text>
            </View>
          ) : null}

          {showScanner ? (
            <View style={styles.scannerShell}>
              <CameraView
                style={styles.scanner}
                facing="back"
                barcodeScannerSettings={{ barcodeTypes: ["qr"] }}
                onBarcodeScanned={
                  scanned
                    ? undefined
                    : ({ data }) => {
                        void submit(data);
                      }
                }
              />
              <View style={styles.scannerFooter}>
                <Text style={styles.scannerHint}>
                  Align the Pass pairing code inside the frame
                </Text>
                <AppButton
                  compact
                  variant="ghost"
                  label="Close scanner"
                  onPress={() => setShowScanner(false)}
                />
              </View>
            </View>
          ) : (
            <AppButton label="Scan pairing code" onPress={openScanner} />
          )}

          <View style={styles.dividerRow}>
            <View style={styles.divider} />
            <Text style={styles.or}>OR ENTER CODE</Text>
            <View style={styles.divider} />
          </View>

          <TextInput
            accessibilityLabel="Pairing JSON"
            autoCapitalize="none"
            autoCorrect={false}
            multiline
            numberOfLines={7}
            onChangeText={setRawPayload}
            placeholder={
              publicMode
                ? `{"v":2,"relayUrl":"${sampleRelay}","desktopId":"desk_...","pairingId":"pair_...","pairingSecret":"...","expiresAt":"..."}`
                : `{"v":1,"relayUrl":"${sampleRelay}","desktopId":"desk_...","authorizationToken":"..."}`
            }
            placeholderTextColor={colors.subtle}
            style={styles.input}
            value={rawPayload}
          />
          {pairingError ? <Text style={styles.error}>{pairingError}</Text> : null}
          <AppButton
            label="Pair and connect"
            loading={pairingBusy}
            disabled={!rawPayload.trim()}
            onPress={() => void submit()}
          />

          <Text style={styles.footnote}>
            {publicMode
              ? "The code expires after five minutes and can be claimed only once."
              : "HTTP relay URLs are accepted only in development builds."}
          </Text>
        </ScrollView>
      </KeyboardAvoidingView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
  content: { padding: spacing.lg, gap: spacing.md, maxWidth: 640, width: "100%", alignSelf: "center" },
  hero: { alignItems: "center", paddingVertical: spacing.md, gap: spacing.sm },
  mark: {
    width: 58,
    height: 58,
    borderRadius: 18,
    backgroundColor: colors.accent,
    alignItems: "center",
    justifyContent: "center",
  },
  markText: { color: colors.white, fontSize: 29, fontWeight: "900" },
  eyebrow: { color: colors.accent, fontSize: 11, fontWeight: "900", letterSpacing: 1.7 },
  title: { color: colors.text, fontSize: 28, fontWeight: "800" },
  subtitle: { color: colors.muted, fontSize: 15, lineHeight: 22, textAlign: "center" },
  warning: {
    backgroundColor: "#2a2216",
    borderColor: "#55401f",
    borderWidth: 1,
    borderRadius: radius.md,
    padding: spacing.md,
    gap: spacing.xs,
  },
  warningTitle: { color: colors.warning, fontSize: 13, fontWeight: "800" },
  warningText: { color: "#c9b998", fontSize: 13, lineHeight: 19 },
  scannerShell: { borderRadius: radius.lg, overflow: "hidden", borderWidth: 1, borderColor: colors.border },
  scanner: { width: "100%", aspectRatio: 1 },
  scannerFooter: { backgroundColor: colors.surface, padding: spacing.sm, gap: spacing.sm },
  scannerHint: { color: colors.muted, textAlign: "center", fontSize: 13 },
  dividerRow: { flexDirection: "row", alignItems: "center", gap: spacing.sm, marginVertical: 4 },
  divider: { flex: 1, height: 1, backgroundColor: colors.border },
  or: { color: colors.subtle, fontSize: 10, fontWeight: "800", letterSpacing: 1 },
  input: {
    minHeight: 150,
    color: colors.text,
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.md,
    padding: spacing.md,
    fontSize: 13,
    lineHeight: 19,
    textAlignVertical: "top",
  },
  error: { color: colors.danger, fontSize: 13, lineHeight: 19 },
  footnote: { color: colors.subtle, fontSize: 12, lineHeight: 18, textAlign: "center" },
});
