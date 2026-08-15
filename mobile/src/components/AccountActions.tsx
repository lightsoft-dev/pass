import { useRouter } from "expo-router";
import { useState } from "react";
import { Alert, StyleSheet, Text, View } from "react-native";

import {
  isAppleRevocationFallbackRequiredError,
} from "../services/appleDeletionFallback";
import { isAppleRequestCanceled } from "../services/identitySession";
import { useRemote } from "../state/RemoteProvider";
import { colors, radius, spacing } from "../theme/theme";
import { AppButton } from "./AppButton";

const APPLE_MANUAL_REVOCATION_INSTRUCTIONS =
  "Open Settings > [your name] > Sign-In & Security > Sign in with Apple, select Pass, and choose Stop Using Apple ID. Return to Pass only after completing that step.";

export function AccountActions() {
  const router = useRouter();
  const { signOut, deleteAccount } = useRemote();
  const [deletingAccount, setDeletingAccount] = useState(false);

  const showDeletionError = (error: unknown) => {
    Alert.alert(
      "Could not delete account",
      error instanceof Error ? error.message : "Account deletion failed.",
    );
  };

  const runManualDeletion = () => {
    setDeletingAccount(true);
    void deleteAccount({ appleRevocationFallback: "manual" })
      .then(() => {
        setDeletingAccount(false);
        Alert.alert(
          "Pass data deleted",
          `${APPLE_MANUAL_REVOCATION_INSTRUCTIONS}\n\nPass data has been deleted. Confirm that Pass no longer appears there before signing in again.`,
          [
            {
              text: "Continue to sign in",
              onPress: () => router.replace("/login"),
            },
          ],
        );
      })
      .catch((error: unknown) => {
        setDeletingAccount(false);
        showDeletionError(error);
      });
  };

  const confirmManualDeletion = () => {
    Alert.alert(
      "Stop using Sign in with Apple first",
      `${APPLE_MANUAL_REVOCATION_INSTRUCTIONS}\n\nPass cannot verify this Apple Settings step automatically. Continue only after you have stopped using Apple ID for Pass.`,
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Delete Pass data",
          style: "destructive",
          onPress: runManualDeletion,
        },
      ],
    );
  };

  const offerAppleFallback = (error: unknown) => {
    if (!isAppleRevocationFallbackRequiredError(error)) return false;
    Alert.alert(
      "Apple revocation needs attention",
      `${error.message}\n\nBefore choosing Delete Pass data: ${APPLE_MANUAL_REVOCATION_INSTRUCTIONS}\n\nAutomatic attempt: ${error.originalMessage}`,
      [
        { text: "Cancel", style: "cancel" },
        { text: "Retry", onPress: runAutomaticDeletion },
        {
          text: "Delete Pass data",
          style: "destructive",
          onPress: confirmManualDeletion,
        },
      ],
    );
    return true;
  };

  const runAutomaticDeletion = () => {
    setDeletingAccount(true);
    void deleteAccount()
      .then(() => router.replace("/login"))
      .catch((error: unknown) => {
        setDeletingAccount(false);
        if (isAppleRequestCanceled(error)) return;
        if (offerAppleFallback(error)) return;
        showDeletionError(error);
      });
  };

  const confirmAccountDeletion = () => {
    Alert.alert(
      "Delete Pass account?",
      "This permanently deletes your Pass account, registered desktops, paired-device credentials, and relay data. This cannot be undone.",
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Delete account",
          style: "destructive",
          onPress: runAutomaticDeletion,
        },
      ],
    );
  };

  return (
    <View style={styles.section}>
      <Text style={styles.sectionTitle}>Account</Text>
      <AppButton
        variant="secondary"
        label="Sign out"
        disabled={deletingAccount}
        onPress={() => {
          void signOut()
            .then(() => router.replace("/login"))
            .catch((error: unknown) => {
              Alert.alert(
                "Could not sign out",
                error instanceof Error ? error.message : "Device revocation failed.",
              );
            });
        }}
      />
      <View style={styles.dangerZone}>
        <Text style={styles.dangerTitle}>Delete account and relay data</Text>
        <Text style={styles.dangerText}>
          Permanently removes this account and disconnects every registered desktop and paired device.
        </Text>
        <AppButton
          variant="danger"
          label="Delete account"
          loading={deletingAccount}
          onPress={confirmAccountDeletion}
        />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  section: { gap: spacing.sm },
  sectionTitle: { color: colors.text, fontSize: 15, fontWeight: "800" },
  dangerZone: {
    backgroundColor: "#25191c",
    borderWidth: 1,
    borderColor: "#6d3038",
    borderRadius: radius.md,
    padding: spacing.md,
    gap: spacing.sm,
  },
  dangerTitle: { color: colors.danger, fontSize: 13, fontWeight: "800" },
  dangerText: { color: colors.muted, fontSize: 12, lineHeight: 18 },
});
