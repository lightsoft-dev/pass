import { Redirect } from "expo-router";
import { ActivityIndicator, StyleSheet, Text, View } from "react-native";

import { Screen } from "../components/Screen";
import { useRemote } from "../state/RemoteProvider";
import { colors, spacing } from "../theme/theme";

export default function EntryRoute() {
  const { hydrated, pairedDesktop } = useRemote();
  if (!hydrated) {
    return (
      <Screen style={styles.loading} edges={["top", "bottom", "left", "right"]}>
        <View style={styles.mark}><Text style={styles.markText}>P</Text></View>
        <Text style={styles.title}>Pass Remote</Text>
        <ActivityIndicator color={colors.accent} />
      </Screen>
    );
  }
  return <Redirect href={pairedDesktop ? "/(tabs)" : "/pair"} />;
}

const styles = StyleSheet.create({
  loading: { alignItems: "center", justifyContent: "center", gap: spacing.md },
  mark: {
    width: 64,
    height: 64,
    alignItems: "center",
    justifyContent: "center",
    borderRadius: 20,
    backgroundColor: colors.accent,
  },
  markText: { color: colors.white, fontSize: 32, fontWeight: "900" },
  title: { color: colors.text, fontSize: 22, fontWeight: "800" },
});
