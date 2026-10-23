import { Redirect } from "expo-router";
import { ActivityIndicator, Image, StyleSheet, Text, View } from "react-native";

import { Screen } from "../components/Screen";
import { useRemote } from "../state/RemoteProvider";
import { colors, spacing } from "../theme/theme";

export default function EntryRoute() {
  const { hydrated, pairedDesktop, userSession } = useRemote();
  if (!hydrated) {
    return (
      <Screen style={styles.loading} edges={["top", "bottom", "left", "right"]}>
        <Image source={require("../../assets/icon.png")} style={styles.mark} />
        <Text style={styles.title}>Pass Remote</Text>
        <ActivityIndicator color={colors.accent} />
      </Screen>
    );
  }
  if (pairedDesktop) return <Redirect href="/(tabs)" />;
  if (!__DEV__ && !userSession) {
    return <Redirect href="/login" />;
  }
  return <Redirect href="/pair" />;
}

const styles = StyleSheet.create({
  loading: { alignItems: "center", justifyContent: "center", gap: spacing.md },
  mark: {
    width: 64,
    height: 64,
    borderRadius: 20,
  },
  title: { color: colors.text, fontSize: 22, fontWeight: "800" },
});
