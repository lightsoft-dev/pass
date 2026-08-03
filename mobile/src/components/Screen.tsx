import { type PropsWithChildren } from "react";
import { SafeAreaView } from "react-native-safe-area-context";
import { StyleSheet, type StyleProp, type ViewStyle } from "react-native";

import { colors } from "../theme/theme";

export function Screen({
  children,
  style,
  edges = ["top", "left", "right"],
}: PropsWithChildren<{ style?: StyleProp<ViewStyle>; edges?: ("top" | "bottom" | "left" | "right")[] }>) {
  return (
    <SafeAreaView edges={edges} style={[styles.screen, style]}>
      {children}
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
});
