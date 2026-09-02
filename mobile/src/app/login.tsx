import {
  GoogleSignin,
  isSuccessResponse,
} from "@react-native-google-signin/google-signin";
import * as AppleAuthentication from "expo-apple-authentication";
import { useRouter } from "expo-router";
import { useEffect, useState } from "react";
import { ActivityIndicator, Platform, StyleSheet, Text, View } from "react-native";

import { AppButton } from "../components/AppButton";
import { Screen } from "../components/Screen";
import {
  configureGoogleSignIn,
  publicOIDCConfiguration,
  requestInitialAppleAuthorization,
  type PublicOIDCConfiguration,
  userSessionFromGoogleUser,
} from "../services/authService";
import {
  isAppleRequestCanceled,
  shouldShowAppleSignIn,
} from "../services/identitySession";
import { useRemote } from "../state/RemoteProvider";
import { colors, radius, spacing } from "../theme/theme";

export default function LoginScreen() {
  const googleConfiguration = publicOIDCConfiguration();
  const appleAvailable = useAppleSignInAvailability();
  if (!googleConfiguration && appleAvailable === null) return <CheckingAvailability />;
  const showApple = shouldShowAppleSignIn(Platform.OS, appleAvailable === true);
  if (!googleConfiguration && !showApple) return <MissingConfiguration />;
  return (
    <ConfiguredLogin
      googleConfiguration={googleConfiguration}
      showApple={showApple}
    />
  );
}

function ConfiguredLogin({
  googleConfiguration,
  showApple,
}: {
  googleConfiguration: PublicOIDCConfiguration | null;
  showApple: boolean;
}) {
  const router = useRouter();
  const { completeAppleSignIn, completeSignIn } = useRemote();
  const [busyProvider, setBusyProvider] = useState<"google" | "apple" | null>(null);
  const [error, setError] = useState<string | null>(null);

  const startGoogleSignIn = () => {
    if (!googleConfiguration) return;
    setError(null);
    setBusyProvider("google");
    configureGoogleSignIn(googleConfiguration);
    void (async () => {
      if (Platform.OS === "android") {
        await GoogleSignin.hasPlayServices({ showPlayServicesUpdateDialog: true });
      }
      const response = await GoogleSignin.signIn();
      if (!isSuccessResponse(response)) return;
      await completeSignIn(userSessionFromGoogleUser(googleConfiguration, response.data));
      router.replace("/pair");
    })()
      .catch((signInError: unknown) => {
        setError(
          signInError instanceof Error ? signInError.message : "Could not complete sign in.",
        );
      })
      .finally(() => setBusyProvider(null));
  };

  const startAppleSignIn = () => {
    setError(null);
    setBusyProvider("apple");
    void (async () => {
      const authorization = await requestInitialAppleAuthorization();
      await completeAppleSignIn(authorization);
      router.replace("/pair");
    })()
      .catch((signInError: unknown) => {
        if (isAppleRequestCanceled(signInError)) return;
        setError(
          signInError instanceof Error ? signInError.message : "Could not complete sign in.",
        );
      })
      .finally(() => setBusyProvider(null));
  };

  const busy = busyProvider !== null;

  return (
    <Screen style={styles.screen} edges={["top", "bottom", "left", "right"]}>
      <View style={styles.content}>
        <View style={styles.mark}><Text style={styles.markText}>P</Text></View>
        <Text style={styles.title}>Sign in to Pass</Text>
        <Text style={styles.subtitle}>
          Sign in, then securely link this device to your Mac with a QR code.
        </Text>
        {error ? <Text style={styles.error}>{error}</Text> : null}
        {showApple ? (
          <View
            pointerEvents={busy ? "none" : "auto"}
            style={[styles.appleButtonWrapper, busy && styles.disabled]}
          >
            <AppleAuthentication.AppleAuthenticationButton
              buttonType={AppleAuthentication.AppleAuthenticationButtonType.CONTINUE}
              buttonStyle={AppleAuthentication.AppleAuthenticationButtonStyle.WHITE}
              cornerRadius={radius.md}
              onPress={startAppleSignIn}
              style={styles.appleButton}
            />
          </View>
        ) : null}
        {showApple && googleConfiguration ? <Text style={styles.divider}>or</Text> : null}
        {googleConfiguration ? (
          <AppButton
            label="Continue with Google"
            disabled={busy}
            loading={busyProvider === "google"}
            onPress={startGoogleSignIn}
            style={styles.button}
          />
        ) : null}
        <View style={styles.demoEntry}>
          <Text style={styles.demoHint}>Review the complete interface with safe sample data.</Text>
          <AppButton
            label="Explore demo"
            disabled={busy}
            onPress={() => router.replace("./demo")}
            style={styles.button}
            variant="ghost"
          />
        </View>
      </View>
    </Screen>
  );
}

function useAppleSignInAvailability(): boolean | null {
  const [available, setAvailable] = useState<boolean | null>(
    Platform.OS === "ios" ? null : false,
  );
  useEffect(() => {
    if (Platform.OS !== "ios") return;
    let active = true;
    void AppleAuthentication.isAvailableAsync()
      .then((result) => {
        if (active) setAvailable(result);
      })
      .catch(() => {
        if (active) setAvailable(false);
      });
    return () => {
      active = false;
    };
  }, []);
  return available;
}

function CheckingAvailability() {
  return (
    <Screen style={styles.screen} edges={["top", "bottom", "left", "right"]}>
      <ActivityIndicator color={colors.accent} />
    </Screen>
  );
}

function MissingConfiguration() {
  const router = useRouter();
  return (
    <Screen style={styles.screen} edges={["top", "bottom", "left", "right"]}>
      <View style={styles.content}>
        <Text style={styles.title}>Sign in is unavailable</Text>
        <Text style={styles.subtitle}>This build has no Google OAuth client.</Text>
        <AppButton label="Use development pairing" onPress={() => router.replace("/pair")} />
        <AppButton label="Explore demo" onPress={() => router.replace("./demo")} variant="ghost" />
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  screen: { alignItems: "center", justifyContent: "center", padding: spacing.lg },
  content: { width: "100%", maxWidth: 440, gap: spacing.md, alignItems: "center" },
  mark: {
    width: 64,
    height: 64,
    borderRadius: radius.md,
    backgroundColor: colors.accent,
    alignItems: "center",
    justifyContent: "center",
    marginBottom: spacing.sm,
  },
  markText: { color: colors.white, fontSize: 32, fontWeight: "900" },
  title: { color: colors.text, fontSize: 28, fontWeight: "800", textAlign: "center" },
  subtitle: { color: colors.muted, fontSize: 15, lineHeight: 22, textAlign: "center" },
  error: { color: colors.danger, fontSize: 13, lineHeight: 19, textAlign: "center" },
  button: { width: "100%", marginTop: spacing.sm },
  appleButtonWrapper: { width: "100%", height: 50, marginTop: spacing.sm },
  appleButton: { width: "100%", height: 50 },
  disabled: { opacity: 0.42 },
  divider: { color: colors.muted, fontSize: 13, lineHeight: 18 },
  demoEntry: {
    width: "100%",
    marginTop: spacing.sm,
    paddingTop: spacing.md,
    borderTopColor: colors.border,
    borderTopWidth: StyleSheet.hairlineWidth,
    gap: spacing.sm,
  },
  demoHint: { color: colors.subtle, fontSize: 11, lineHeight: 16, textAlign: "center" },
});
