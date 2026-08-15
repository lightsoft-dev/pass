import { useEffect, useRef, useState } from "react";
import {
  KeyboardAvoidingView,
  Modal,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";

import {
  CONTENT_REPORT_LIMITS,
  CONTENT_REPORT_REASONS,
  CONTENT_REPORT_REASON_LABELS,
  submitContentReport,
  type ContentReportReason,
  type ContentReportResult,
} from "../services/feedbackService";
import { colors, radius, spacing } from "../theme/theme";
import { AppButton } from "./AppButton";

export type ContentReportTarget = {
  sourceMessageID: string;
  responseText: string;
};

type Props = {
  relayBaseURL: string | null;
  target: ContentReportTarget | null;
  onClose: () => void;
};

export function ContentReportModal({ relayBaseURL, target, onClose }: Props) {
  const mounted = useRef(false);
  const [reason, setReason] = useState<ContentReportReason | null>(null);
  const [excerpt, setExcerpt] = useState("");
  const [note, setNote] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [result, setResult] = useState<ContentReportResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  useEffect(() => {
    setReason(null);
    setExcerpt(target?.responseText.slice(0, CONTENT_REPORT_LIMITS.excerpt) ?? "");
    setNote("");
    setSubmitting(false);
    setResult(null);
    setError(null);
  }, [target?.responseText, target?.sourceMessageID]);

  const close = () => {
    if (!submitting) onClose();
  };

  const submit = () => {
    if (!target || !reason || !excerpt.trim() || submitting) return;
    if (!relayBaseURL) {
      setError("Content reporting is unavailable in this build.");
      return;
    }
    setSubmitting(true);
    setError(null);
    void submitContentReport(relayBaseURL, {
      sourceMessageID: target.sourceMessageID,
      reason,
      excerpt,
      ...(note.trim() ? { note } : {}),
    })
      .then((submissionResult) => {
        if (mounted.current) setResult(submissionResult);
      })
      .catch((submissionError: unknown) => {
        if (!mounted.current) return;
        setError(
          submissionError instanceof Error
            ? submissionError.message
            : "The report could not be submitted. Please try again.",
        );
      })
      .finally(() => {
        if (mounted.current) setSubmitting(false);
      });
  };

  return (
    <Modal
      animationType="fade"
      onRequestClose={close}
      presentationStyle="overFullScreen"
      statusBarTranslucent
      transparent
      visible={target !== null}
    >
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        style={styles.overlay}
      >
        <Pressable
          accessibilityLabel="Close report dialog"
          accessibilityRole="button"
          disabled={submitting}
          onPress={close}
          style={StyleSheet.absoluteFill}
        />
        <View accessibilityViewIsModal style={styles.sheet}>
          <View style={styles.header}>
            <View style={styles.headerCopy}>
              <Text style={styles.eyebrow}>AI CONTENT REPORT</Text>
              <Text style={styles.title}>Report this response</Text>
            </View>
            <Pressable
              accessibilityLabel="Close report dialog"
              accessibilityRole="button"
              disabled={submitting}
              hitSlop={10}
              onPress={close}
              style={({ pressed }) => [styles.closeButton, pressed && styles.pressed]}
            >
              <Text style={styles.closeText}>×</Text>
            </Pressable>
          </View>

          {result ? (
            <View style={styles.successPanel}>
              <View style={styles.successMark}><Text style={styles.successMarkText}>✓</Text></View>
              <Text style={styles.successTitle}>Report received</Text>
              <Text style={styles.successText}>
                Thanks for helping us improve Pass. Keep this report reference private; support
                may use it with other verification details if you later request removal.
              </Text>
              <Text selectable style={styles.reportID}>{result.reportId}</Text>
              <AppButton label="Close" onPress={onClose} style={styles.fullWidth} />
            </View>
          ) : (
            <ScrollView
              contentContainerStyle={styles.form}
              keyboardShouldPersistTaps="handled"
              showsVerticalScrollIndicator={false}
            >
              <View style={styles.fieldGroup}>
                <Text style={styles.label}>Why are you reporting it?</Text>
                <View accessibilityRole="radiogroup" style={styles.reasonGrid}>
                  {CONTENT_REPORT_REASONS.map((value) => {
                    const selected = reason === value;
                    return (
                      <Pressable
                        key={value}
                        accessibilityRole="radio"
                        accessibilityState={{ selected }}
                        onPress={() => setReason(value)}
                        style={({ pressed }) => [
                          styles.reason,
                          selected && styles.reasonSelected,
                          pressed && styles.pressed,
                        ]}
                      >
                        <View style={[styles.radio, selected && styles.radioSelected]}>
                          {selected ? <View style={styles.radioDot} /> : null}
                        </View>
                        <Text style={[styles.reasonText, selected && styles.reasonTextSelected]}>
                          {CONTENT_REPORT_REASON_LABELS[value]}
                        </Text>
                      </Pressable>
                    );
                  })}
                </View>
              </View>

              <View style={styles.fieldGroup}>
                <View style={styles.labelRow}>
                  <Text style={styles.label}>Response excerpt</Text>
                  <Text style={styles.counter}>{excerpt.length}/{CONTENT_REPORT_LIMITS.excerpt}</Text>
                </View>
                <Text style={styles.hint}>
                  Only this selected assistant response is prefilled. Edit it to remove anything
                  you do not want to send.
                </Text>
                <TextInput
                  accessibilityLabel="Reported response excerpt"
                  maxLength={CONTENT_REPORT_LIMITS.excerpt}
                  multiline
                  onChangeText={setExcerpt}
                  selectionColor={colors.accent}
                  style={[styles.input, styles.excerptInput]}
                  textAlignVertical="top"
                  value={excerpt}
                />
              </View>

              <View style={styles.fieldGroup}>
                <View style={styles.labelRow}>
                  <Text style={styles.label}>Additional note</Text>
                  <Text style={styles.optional}>OPTIONAL · {note.length}/{CONTENT_REPORT_LIMITS.note}</Text>
                </View>
                <TextInput
                  accessibilityLabel="Additional report note"
                  maxLength={CONTENT_REPORT_LIMITS.note}
                  multiline
                  onChangeText={setNote}
                  placeholder="What should we know?"
                  placeholderTextColor={colors.subtle}
                  selectionColor={colors.accent}
                  style={[styles.input, styles.noteInput]}
                  textAlignVertical="top"
                  value={note}
                />
              </View>

              <View style={styles.privacyNotice}>
                <Text style={styles.privacyMark}>i</Text>
                <Text style={styles.privacyText}>
                  Pass automatically attaches only your reason, this editable excerpt, optional
                  note, and its message reference—never login or device credentials, account
                  identifiers, project paths, or terminal history. The response itself may mention
                  sensitive information, so review the excerpt and remove secrets before submitting.
                </Text>
              </View>

              {error ? (
                <Text accessibilityLiveRegion="polite" style={styles.error}>{error}</Text>
              ) : null}

              <View style={styles.actions}>
                <AppButton
                  compact
                  disabled={submitting}
                  label="Cancel"
                  onPress={close}
                  style={styles.actionButton}
                  variant="ghost"
                />
                <AppButton
                  compact
                  disabled={!reason || !excerpt.trim()}
                  label="Submit report"
                  loading={submitting}
                  onPress={submit}
                  style={styles.actionButton}
                />
              </View>
            </ScrollView>
          )}
        </View>
      </KeyboardAvoidingView>
    </Modal>
  );
}

const styles = StyleSheet.create({
  overlay: {
    flex: 1,
    justifyContent: "flex-end",
    alignItems: "center",
    paddingTop: 48,
    backgroundColor: "rgba(0, 0, 0, 0.68)",
  },
  sheet: {
    width: "100%",
    maxWidth: 680,
    maxHeight: "92%",
    overflow: "hidden",
    backgroundColor: colors.surface,
    borderTopLeftRadius: radius.lg,
    borderTopRightRadius: radius.lg,
    borderWidth: 1,
    borderBottomWidth: 0,
    borderColor: colors.border,
  },
  header: {
    minHeight: 76,
    paddingHorizontal: spacing.md,
    paddingVertical: 14,
    flexDirection: "row",
    alignItems: "center",
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.border,
  },
  headerCopy: { flex: 1, gap: 3 },
  eyebrow: { color: colors.accent, fontSize: 9, fontWeight: "900", letterSpacing: 1.2 },
  title: { color: colors.text, fontSize: 20, lineHeight: 26, fontWeight: "800" },
  closeButton: {
    width: 38,
    height: 38,
    alignItems: "center",
    justifyContent: "center",
    borderRadius: radius.pill,
    backgroundColor: colors.raised,
  },
  closeText: { color: colors.muted, fontSize: 26, lineHeight: 29, fontWeight: "400" },
  form: { padding: spacing.md, paddingBottom: spacing.lg, gap: 20 },
  fieldGroup: { gap: 8 },
  labelRow: { flexDirection: "row", alignItems: "baseline", gap: spacing.sm },
  label: { flex: 1, color: colors.text, fontSize: 13, fontWeight: "800" },
  counter: { color: colors.subtle, fontSize: 10, fontVariant: ["tabular-nums"] },
  optional: { color: colors.subtle, fontSize: 9, fontWeight: "700", letterSpacing: 0.3 },
  hint: { color: colors.muted, fontSize: 11, lineHeight: 16 },
  reasonGrid: { gap: 7 },
  reason: {
    minHeight: 44,
    paddingHorizontal: 12,
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.sm,
    backgroundColor: "#14171b",
  },
  reasonSelected: { borderColor: colors.accent, backgroundColor: colors.accentSoft },
  radio: {
    width: 17,
    height: 17,
    alignItems: "center",
    justifyContent: "center",
    borderRadius: radius.pill,
    borderWidth: 1,
    borderColor: colors.subtle,
  },
  radioSelected: { borderColor: colors.accent },
  radioDot: { width: 9, height: 9, borderRadius: radius.pill, backgroundColor: colors.accent },
  reasonText: { flex: 1, color: colors.muted, fontSize: 13, fontWeight: "600" },
  reasonTextSelected: { color: colors.text },
  input: {
    color: colors.text,
    backgroundColor: "#101216",
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.sm,
    paddingHorizontal: 12,
    paddingVertical: 11,
    fontSize: 13,
    lineHeight: 19,
  },
  excerptInput: { minHeight: 128, maxHeight: 240 },
  noteInput: { minHeight: 80, maxHeight: 140 },
  privacyNotice: {
    padding: 12,
    flexDirection: "row",
    alignItems: "flex-start",
    gap: 10,
    borderRadius: radius.sm,
    backgroundColor: "#17221e",
    borderWidth: 1,
    borderColor: "#29473a",
  },
  privacyMark: {
    width: 19,
    height: 19,
    color: "#8edbb5",
    borderRadius: radius.pill,
    borderWidth: 1,
    borderColor: "#4c8b70",
    fontSize: 11,
    lineHeight: 17,
    fontWeight: "900",
    textAlign: "center",
  },
  privacyText: { flex: 1, color: "#a9c7b8", fontSize: 11, lineHeight: 17 },
  error: { color: colors.danger, fontSize: 12, lineHeight: 18 },
  actions: { flexDirection: "row", gap: spacing.sm },
  actionButton: { flex: 1 },
  pressed: { opacity: 0.72 },
  successPanel: { padding: spacing.lg, alignItems: "center", gap: spacing.md },
  successMark: {
    width: 50,
    height: 50,
    alignItems: "center",
    justifyContent: "center",
    borderRadius: radius.pill,
    backgroundColor: "#173326",
    borderWidth: 1,
    borderColor: "#2d6b4c",
  },
  successMarkText: { color: colors.success, fontSize: 24, fontWeight: "800" },
  successTitle: { color: colors.text, fontSize: 20, fontWeight: "800" },
  successText: { color: colors.muted, fontSize: 13, lineHeight: 20, textAlign: "center" },
  reportID: {
    color: colors.text,
    fontFamily: "Menlo",
    fontSize: 11,
    paddingHorizontal: 12,
    paddingVertical: 9,
    borderRadius: radius.sm,
    backgroundColor: colors.background,
  },
  fullWidth: { width: "100%", marginTop: spacing.sm },
});
