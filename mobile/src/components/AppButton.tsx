import { ActivityIndicator, Pressable, StyleSheet, Text, type ViewStyle } from "react-native";

import { colors, radius, spacing } from "../theme/theme";

type Props = {
  label: string;
  onPress: () => void;
  variant?: "primary" | "secondary" | "danger" | "ghost";
  disabled?: boolean;
  loading?: boolean;
  compact?: boolean;
  style?: ViewStyle;
};

export function AppButton({
  label,
  onPress,
  variant = "primary",
  disabled = false,
  loading = false,
  compact = false,
  style,
}: Props) {
  const blocked = disabled || loading;
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      disabled={blocked}
      onPress={onPress}
      style={({ pressed }) => [
        styles.base,
        compact && styles.compact,
        styles[variant],
        blocked && styles.disabled,
        pressed && !blocked && styles.pressed,
        style,
      ]}
    >
      {loading ? (
        <ActivityIndicator color={variant === "primary" ? colors.white : colors.text} />
      ) : (
        <Text style={[styles.label, variant === "primary" && styles.primaryLabel]}>
          {label}
        </Text>
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  base: {
    minHeight: 48,
    alignItems: "center",
    justifyContent: "center",
    borderRadius: radius.md,
    paddingHorizontal: spacing.md,
    borderWidth: 1,
    borderColor: "transparent",
  },
  compact: { minHeight: 38, paddingHorizontal: 13 },
  primary: { backgroundColor: colors.accent },
  secondary: { backgroundColor: colors.raised, borderColor: colors.border },
  danger: { backgroundColor: "#422126", borderColor: "#6d3038" },
  ghost: { backgroundColor: "transparent", borderColor: colors.border },
  disabled: { opacity: 0.42 },
  pressed: { opacity: 0.78, transform: [{ scale: 0.99 }] },
  label: { color: colors.text, fontSize: 15, fontWeight: "700" },
  primaryLabel: { color: colors.white },
});
