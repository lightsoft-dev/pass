import {
  ResponseType,
  exchangeCodeAsync,
  makeRedirectUri,
  useAuthRequest,
  useAutoDiscovery,
} from "expo-auth-session";
import { useRouter } from "expo-router";
import * as WebBrowser from "expo-web-browser";
import { useEffect, useRef, useState } from "react";
import { ActivityIndicator, StyleSheet, Text, View } from "react-native";

import { AppButton } from "../components/AppButton";
import { Screen } from "../components/Screen";
import {
  publicOIDCConfiguration,
  type PublicOIDCConfiguration,
  userSessionFromTokenResponse,
} from "../services/authService";
import { useRemote } from "../state/RemoteProvider";
import { colors, radius, spacing } from "../theme/theme";

WebBrowser.maybeCompleteAuthSession();

const redirectUri = makeRedirectUri({ scheme: "passremote", path: "oauth" });

export default function LoginScreen() {
  const configuration = publicOIDCConfiguration();
  if (!configuration) return <MissingConfiguration />;
  return <ConfiguredLogin configuration={configuration} />;
}

function ConfiguredLogin({
  configuration,
}: {
  configuration: PublicOIDCConfiguration;
}) {
  const router = useRouter();
  const { completeSignIn } = useRemote();
  const discovery = useAutoDiscovery(configuration.issuer);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const handledCode = useRef<string | null>(null);
  const [request, response, promptAsync] = useAuthRequest(
    {
      clientId: configuration.clientId,
      redirectUri,
      responseType: ResponseType.Code,
      scopes: ["openid", "profile", "email", "offline_access"],
      usePKCE: true,
      ...(configuration.audience
        ? { extraParams: { audience: configuration.audience } }
        : {}),
    },
    discovery,
  );

  useEffect(() => {
    if (!response) return;
    if (response.type === "error") {
      setBusy(false);
      setError(response.error?.message ?? "Sign in was not completed.");
      return;
    }
    if (response.type === "cancel" || response.type === "dismiss") {
      setBusy(false);
      return;
    }
    if (response.type !== "success") return;

    const code = response.params.code;
    if (!code || handledCode.current === code || !request?.codeVerifier || !discovery) {
      if (!code || !request?.codeVerifier) {
        setBusy(false);
        setError("The identity provider returned an incomplete authorization response.");
      }
      return;
    }
    handledCode.current = code;
    setBusy(true);
    void exchangeCodeAsync(
      {
        clientId: configuration.clientId,
        code,
        redirectUri,
        extraParams: { code_verifier: request.codeVerifier },
      },
      discovery,
    )
      .then((tokenResponse) =>
        completeSignIn(userSessionFromTokenResponse(configuration, tokenResponse)),
      )
      .then(() => router.replace("/pair"))
      .catch((exchangeError: unknown) => {
        handledCode.current = null;
        setBusy(false);
        setError(
          exchangeError instanceof Error
            ? exchangeError.message
            : "Could not complete sign in.",
        );
      });
  }, [completeSignIn, configuration, discovery, request, response, router]);

  const startSignIn = () => {
    setError(null);
    setBusy(true);
    void promptAsync().catch((promptError: unknown) => {
      setBusy(false);
      setError(
        promptError instanceof Error ? promptError.message : "Could not open sign in.",
      );
    });
  };

  return (
    <Screen style={styles.screen} edges={["top", "bottom", "left", "right"]}>
      <View style={styles.content}>
        <View style={styles.mark}><Text style={styles.markText}>P</Text></View>
        <Text style={styles.title}>Sign in to Pass</Text>
        <Text style={styles.subtitle}>
          Use the same account on this phone and your Mac.
        </Text>
        {!discovery ? (
          <View style={styles.discovery}>
            <ActivityIndicator color={colors.accent} />
            <Text style={styles.discoveryText}>Connecting to sign in...</Text>
          </View>
        ) : null}
        {error ? <Text style={styles.error}>{error}</Text> : null}
        <AppButton
          label="Continue"
          disabled={!request || !discovery}
          loading={busy}
          onPress={startSignIn}
          style={styles.button}
        />
      </View>
    </Screen>
  );
}

function MissingConfiguration() {
  const router = useRouter();
  return (
    <Screen style={styles.screen} edges={["top", "bottom", "left", "right"]}>
      <View style={styles.content}>
        <Text style={styles.title}>Sign in is unavailable</Text>
        <Text style={styles.subtitle}>This build has no public identity provider.</Text>
        <AppButton label="Use development pairing" onPress={() => router.replace("/pair")} />
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
  discovery: { flexDirection: "row", alignItems: "center", gap: spacing.sm },
  discoveryText: { color: colors.muted, fontSize: 13 },
  error: { color: colors.danger, fontSize: 13, lineHeight: 19, textAlign: "center" },
  button: { width: "100%", marginTop: spacing.sm },
});
