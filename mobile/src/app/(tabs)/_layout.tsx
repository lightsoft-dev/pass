import { Tabs } from "expo-router";
import { Text, type ColorValue } from "react-native";

import { colors } from "../../theme/theme";

function TabGlyph({ glyph, color }: { glyph: string; color: ColorValue }) {
  return <Text style={{ color, fontSize: 19, fontWeight: "800" }}>{glyph}</Text>;
}

export default function TabLayout() {
  return (
    <Tabs
      screenOptions={{
        headerShown: false,
        tabBarActiveTintColor: colors.accent,
        tabBarInactiveTintColor: colors.subtle,
        tabBarStyle: { backgroundColor: colors.surface, borderTopColor: colors.border },
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
