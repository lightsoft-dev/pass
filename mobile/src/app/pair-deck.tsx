import { CameraView, useCameraPermissions } from "expo-camera";
import { useRouter } from "expo-router";
import { useState } from "react";
import { StyleSheet, Text, View } from "react-native";

import { AppButton } from "../components/AppButton";
import { Screen } from "../components/Screen";
import { useRemote } from "../state/RemoteProvider";
import { colors, radius, spacing } from "../theme/theme";

export default function PairDeckScreen() {
  const router = useRouter();
  const [permission, requestPermission] = useCameraPermissions();
  const { approveDeckPairing, pairingBusy, pairingError } = useRemote();
  const [scanned, setScanned] = useState(false);
  const [approved, setApproved] = useState(false);

  const scan = async (payload: string) => {
    if (scanned) return;
    setScanned(true);
    const result = await approveDeckPairing(payload);
    if (result.ok) setApproved(true);
    else setScanned(false);
  };

  if (!permission?.granted) {
    return (
      <Screen style={styles.center}>
        <Text style={styles.title}>Connect a Steam Deck</Text>
        <Text style={styles.copy}>Allow camera access, then scan the one-time QR shown on your Deck.</Text>
        <AppButton label="Allow camera" onPress={() => void requestPermission()} />
      </Screen>
    );
  }

  if (approved) {
    return (
      <Screen style={styles.center}>
        <View style={styles.success}><Text style={styles.successGlyph}>✓</Text></View>
        <Text style={styles.title}>Steam Deck connected</Text>
        <Text style={styles.copy}>The Deck received its own revocable device credential. You can close this screen.</Text>
        <AppButton label="Done" onPress={() => router.back()} />
      </Screen>
    );
  }

  return (
    <Screen style={styles.screen}>
      <Text style={styles.eyebrow}>ONE-TIME DEVICE LINK</Text>
      <Text style={styles.title}>Scan the Deck</Text>
      <Text style={styles.copy}>Confirm that the device name on the Deck matches before approving.</Text>
      <View style={styles.scannerShell}>
        <CameraView
          style={styles.scanner}
          facing="back"
          barcodeScannerSettings={{ barcodeTypes: ["qr"] }}
          onBarcodeScanned={scanned ? undefined : ({ data }) => void scan(data)}
        />
        <View style={styles.scanFrame} pointerEvents="none" />
      </View>
      {pairingBusy ? <Text style={styles.status}>Approving encrypted handoff…</Text> : null}
      {pairingError ? <Text style={styles.error}>{pairingError}</Text> : null}
      <AppButton compact variant="ghost" label="Cancel" onPress={() => router.back()} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  screen: { padding: spacing.lg, gap: spacing.md, alignItems: "center" },
  center: { padding: spacing.xl, gap: spacing.md, alignItems: "center", justifyContent: "center" },
  eyebrow: { color: colors.accent, fontSize: 10, fontWeight: "900", letterSpacing: 1.8 },
  title: { color: colors.text, fontSize: 27, fontWeight: "900", textAlign: "center" },
  copy: { maxWidth: 440, color: colors.muted, fontSize: 14, lineHeight: 21, textAlign: "center" },
  scannerShell: { width: "100%", maxWidth: 480, aspectRatio: 1, borderRadius: radius.lg, overflow: "hidden", borderWidth: 1, borderColor: colors.border },
  scanner: { flex: 1 },
  scanFrame: { position: "absolute", inset: "12%", borderWidth: 2, borderColor: colors.accent, borderRadius: radius.md },
  status: { color: colors.accent, fontSize: 13, fontWeight: "700" },
  error: { color: colors.danger, fontSize: 13, textAlign: "center" },
  success: { width: 82, height: 82, borderRadius: 41, backgroundColor: colors.accentSoft, alignItems: "center", justifyContent: "center" },
  successGlyph: { color: colors.accent, fontSize: 40, fontWeight: "900" },
});
