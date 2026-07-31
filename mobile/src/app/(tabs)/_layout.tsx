import { Tabs } from "expo-router";
import { Text, type ColorValue } from "react-native";

import { useAdaptiveLayout } from "../../hooks/useAdaptiveLayout";
import { colors } from "../../theme/theme";

function TabGlyph({ glyph, color }: { glyph: string; color: ColorValue }) {
  return <Text style={{ color, fontSize: 19, fontWeight: "800" }}>{glyph}</Text>;
}

export default function TabLayout() {
  const { isRegular } = useAdaptiveLayout();

  return (
    <Tabs
      screenOptions={{
        headerShown: false,
        tabBarActiveTintColor: colors.accent,
        tabBarInactiveTintColor: colors.subtle,
        tabBarPosition: isRegular ? "left" : "bottom",
        tabBarVariant: isRegular ? "material" : "uikit",
        tabBarLabelPosition: isRegular ? "beside-icon" : "below-icon",
        tabBarLabelStyle: isRegular
          ? { fontSize: 14, fontWeight: "700" }
          : { fontSize: 10, fontWeight: "700" },
        tabBarItemStyle: isRegular
          ? {
              flex: 0,
              height: 52,
              marginHorizontal: 10,
              marginVertical: 3,
              borderRadius: 12,
            }
          : undefined,
        tabBarStyle: isRegular
          ? {
              width: 212,
              paddingTop: 18,
              backgroundColor: colors.surface,
              borderTopWidth: 0,
              borderRightWidth: 1,
              borderRightColor: colors.border,
            }
          : {
              backgroundColor: colors.surface,
              borderTopColor: colors.border,
            },
        sceneStyle: { backgroundColor: colors.background },
      }}
    >
      <Tabs.Screen
        name="index"
        options={{
          title: "Inbox",
          tabBarIcon: ({ color }) => <TabGlyph glyph="▤" color={color} />,
        }}
      />
      <Tabs.Screen
        name="voice"
        options={{
          title: "Voice",
          tabBarIcon: ({ color }) => <TabGlyph glyph="◉" color={color} />,
        }}
      />
      <Tabs.Screen
        name="settings"
        options={{
          title: "Settings",
          tabBarIcon: ({ color }) => <TabGlyph glyph="⚙" color={color} />,
        }}
      />
    </Tabs>
  );
}
