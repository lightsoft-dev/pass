const googlePluginName = "@react-native-google-signin/google-signin";

function reversedGoogleClientId(clientId) {
  if (!clientId.endsWith(".apps.googleusercontent.com")) {
    throw new Error("EXPO_PUBLIC_PASS_GOOGLE_IOS_CLIENT_ID is not a Google OAuth client id.");
  }
  return clientId.split(".").reverse().join(".");
}

export default ({ config }) => {
  const relayUrl = process.env.EXPO_PUBLIC_PASS_RELAY_URL?.trim();
  const webClientId = process.env.EXPO_PUBLIC_PASS_GOOGLE_WEB_CLIENT_ID?.trim();
  const iosClientId = process.env.EXPO_PUBLIC_PASS_GOOGLE_IOS_CLIENT_ID?.trim();

  if (
    process.env.PASS_BUILD_ENV === "production"
    || process.env.EAS_BUILD_PROFILE === "production"
  ) {
    const missing = [
      ["EXPO_PUBLIC_PASS_RELAY_URL", relayUrl],
      ["EXPO_PUBLIC_PASS_GOOGLE_WEB_CLIENT_ID", webClientId],
      ["EXPO_PUBLIC_PASS_GOOGLE_IOS_CLIENT_ID", iosClientId],
    ].filter(([, value]) => !value).map(([name]) => name);
    if (missing.length > 0) {
      throw new Error(`Production build is missing required EAS variables: ${missing.join(", ")}`);
    }
    let parsedRelay;
    try {
      parsedRelay = new URL(relayUrl);
    } catch {
      throw new Error("EXPO_PUBLIC_PASS_RELAY_URL must be a valid production HTTPS URL.");
    }
    if (
      parsedRelay.protocol !== "https:"
      || !parsedRelay.hostname
      || parsedRelay.username
      || parsedRelay.password
    ) {
      throw new Error("EXPO_PUBLIC_PASS_RELAY_URL must be a valid production HTTPS URL.");
    }
  }

  const googlePlugin = iosClientId
    ? [googlePluginName, { iosUrlScheme: reversedGoogleClientId(iosClientId) }]
    : googlePluginName;
  const plugins = (config.plugins ?? []).map((plugin) => {
    const name = Array.isArray(plugin) ? plugin[0] : plugin;
    return name === googlePluginName ? googlePlugin : plugin;
  });

  return { ...config, plugins };
};
