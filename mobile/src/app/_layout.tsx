import { Stack } from "expo-router";
import { StatusBar } from "expo-status-bar";
import { SafeAreaProvider } from "react-native-safe-area-context";

import { RemoteProvider } from "../state/RemoteProvider";
import { colors } from "../theme/theme";

export default function RootLayout() {
  return (
    <SafeAreaProvider>
      <RemoteProvider>
        <StatusBar style="light" />
        <Stack
          screenOptions={{
            contentStyle: { backgroundColor: colors.background },
            headerStyle: { backgroundColor: colors.surface },
            headerTintColor: colors.text,
            headerShadowVisible: false,
          }}
        >
          <Stack.Screen name="index" options={{ headerShown: false }} />
          <Stack.Screen name="login" options={{ headerShown: false }} />
          <Stack.Screen name="pair" options={{ headerShown: false }} />
          <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
          <Stack.Screen name="session/[name]" options={{ title: "Session" }} />
          <Stack.Screen
            name="create"
            options={{ title: "New session", presentation: "modal" }}
          />
        </Stack>
      </RemoteProvider>
    </SafeAreaProvider>
  );
}
