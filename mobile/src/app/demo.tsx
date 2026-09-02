import { useRouter } from "expo-router";
import { useState, type ReactNode } from "react";
import {
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
  type ColorValue,
} from "react-native";

import { AppButton } from "../components/AppButton";
import { Screen } from "../components/Screen";
import {
  DEMO_SECTIONS,
  DEMO_SESSIONS,
  DEMO_TERMINAL_LINES,
  type DemoSection,
  type DemoSession,
} from "../demo/demoData";
import { useAdaptiveLayout } from "../hooks/useAdaptiveLayout";
import { colors, radius, spacing } from "../theme/theme";

const statusColor: Record<DemoSession["status"], ColorValue> = {
  "Needs decision": colors.warning,
  Working: colors.success,
  Finished: colors.info,
};

export default function StoreReviewDemoScreen() {
  const router = useRouter();
  const { isRegular } = useAdaptiveLayout();
  const [section, setSection] = useState<DemoSection>("inbox");
  const [decision, setDecision] = useState<"once" | "always" | "denied" | null>(null);
  const [reportPreview, setReportPreview] = useState(false);

  return (
    <Screen edges={["top", "bottom", "left", "right"]}>
      <View accessibilityRole="summary" style={styles.demoBanner}>
        <View style={styles.demoIdentity}>
          <View style={styles.demoBadge}><Text style={styles.demoBadgeText}>DEMO</Text></View>
          <View style={styles.demoCopy}>
            <Text style={styles.demoTitle}>Store review preview</Text>
            <Text numberOfLines={1} style={styles.demoSubtitle}>
              Synthetic local data · no account, network, or Mac
            </Text>
          </View>
        </View>
        <Pressable
          accessibilityLabel="Exit store review demo"
          accessibilityRole="button"
          onPress={() => router.replace("/login")}
          style={({ pressed }) => [styles.exitButton, pressed && styles.pressed]}
        >
          <Text style={styles.exitText}>Exit demo</Text>
        </Pressable>
      </View>

      <View style={[styles.shell, isRegular && styles.shellRegular]}>
        <View style={styles.brandRow}>
          <View style={styles.mark}><Text style={styles.markText}>P</Text></View>
          <View>
            <Text style={styles.brand}>Pass Remote</Text>
            <Text style={styles.desktop}>Studio Mac · sample workspace</Text>
          </View>
        </View>

        <ScrollView
          accessibilityRole="tablist"
          contentContainerStyle={styles.navContent}
          horizontal
          showsHorizontalScrollIndicator={false}
          style={styles.nav}
        >
          {DEMO_SECTIONS.map((item) => {
            const selected = section === item.id;
            return (
              <Pressable
                accessibilityRole="tab"
                accessibilityState={{ selected }}
                key={item.id}
                onPress={() => setSection(item.id)}
                style={({ pressed }) => [
                  styles.navItem,
                  selected && styles.navItemSelected,
                  pressed && styles.pressed,
                ]}
              >
                <Text style={[styles.navGlyph, selected && styles.navTextSelected]}>{item.glyph}</Text>
                <Text style={[styles.navText, selected && styles.navTextSelected]}>{item.label}</Text>
              </Pressable>
            );
          })}
        </ScrollView>

        <View style={styles.contentFrame}>
          {section === "inbox" ? <InboxDemo onOpen={setSection} /> : null}
          {section === "chat" ? (
            <ChatDemo onOpenDecision={() => setSection("decision")} onReport={() => setReportPreview(true)} />
          ) : null}
          {section === "decision" ? (
            <DecisionDemo decision={decision} onDecision={setDecision} />
          ) : null}
          {section === "terminal" ? <TerminalDemo /> : null}
          {section === "security" ? <SecurityDemo /> : null}
        </View>
      </View>

      {reportPreview ? (
        <View style={styles.toast} accessibilityLiveRegion="polite">
          <View style={styles.toastCopy}>
            <Text style={styles.toastTitle}>Demo report preview</Text>
            <Text style={styles.toastText}>Nothing was submitted. Live reports send only the response you select.</Text>
          </View>
          <Pressable accessibilityRole="button" onPress={() => setReportPreview(false)}>
            <Text style={styles.toastDismiss}>Dismiss</Text>
          </Pressable>
        </View>
      ) : null}
    </Screen>
  );
}

function DemoPage({
  eyebrow,
  title,
  description,
  children,
}: {
  eyebrow: string;
  title: string;
  description: string;
  children: ReactNode;
}) {
  return (
    <ScrollView contentContainerStyle={styles.page} showsVerticalScrollIndicator={false}>
      <View style={styles.pageHeading}>
        <Text style={styles.eyebrow}>{eyebrow}</Text>
        <Text style={styles.pageTitle}>{title}</Text>
        <Text style={styles.pageDescription}>{description}</Text>
      </View>
      {children}
      <View style={styles.readOnlyNote}>
        <Text style={styles.readOnlyTitle}>Read-only store demo</Text>
        <Text style={styles.readOnlyText}>All content on this screen is bundled sample data. No command or credential leaves this device.</Text>
      </View>
    </ScrollView>
  );
}

function InboxDemo({ onOpen }: { onOpen: (section: DemoSection) => void }) {
  return (
    <DemoPage
      description="See what needs attention across development sessions at a glance."
      eyebrow="REMOTE WORKSPACE"
      title="Session inbox"
    >
      <View style={styles.onlineRow}>
        <View style={styles.onlineDot} />
        <Text style={styles.onlineText}>Sample desktop online</Text>
        <Text style={styles.syncedText}>Synced just now</Text>
      </View>
      <View style={styles.sectionHeading}>
        <Text style={styles.sectionTitle}>Needs you</Text>
        <Text style={styles.countBadge}>1</Text>
      </View>
      {DEMO_SESSIONS.map((session) => (
        <Pressable
          accessibilityLabel={`Open sample session ${session.title}`}
          accessibilityRole="button"
          key={session.id}
          onPress={() => onOpen(session.section)}
          style={({ pressed }) => [
            styles.sessionCard,
            session.status === "Needs decision" && styles.sessionCardAttention,
            pressed && styles.pressed,
          ]}
        >
          <View style={styles.sessionTop}>
            <Text numberOfLines={1} style={styles.sessionTitle}>{session.title}</Text>
            <Text style={[styles.sessionStatus, { color: statusColor[session.status] }]}>
              {session.status.toUpperCase()}
            </Text>
          </View>
          <Text style={styles.sessionMeta}>{session.project} · {session.agent} · {session.branch}</Text>
          <Text numberOfLines={2} style={styles.sessionPreview}>{session.preview}</Text>
        </Pressable>
      ))}
    </DemoPage>
  );
}

function ChatDemo({ onOpenDecision, onReport }: { onOpenDecision: () => void; onReport: () => void }) {
  return (
    <DemoPage
      description="Follow an agent response in a clean conversation, then return to the exact terminal when needed."
      eyebrow="PREPARE MOBILE RELEASE"
      title="Agent conversation"
    >
      <View style={styles.chatMetaRow}>
        <Text style={styles.chatMeta}>Claude · dev</Text>
        <View style={styles.statusPill}><Text style={styles.statusPillText}>FINISHED</Text></View>
      </View>
      <View style={styles.userBubble}>
        <Text style={styles.messageText}>Check the production release configuration and summarize anything blocking submission.</Text>
      </View>
      <View style={styles.assistantBlock}>
        <View style={styles.agentRow}><View style={styles.agentDot} /><Text style={styles.agentLabel}>ASSISTANT</Text></View>
        <Text style={styles.messageHeading}>Release check complete</Text>
        <Text style={styles.messageText}>The identifiers, signing profile, and update channel match the production configuration.</Text>
        <View style={styles.checkRow}><Text style={styles.check}>✓</Text><Text style={styles.checkText}>Bundle identifier: dev.lightsoft.passmobile</Text></View>
        <View style={styles.checkRow}><Text style={styles.check}>✓</Text><Text style={styles.checkText}>Runtime policy: app version</Text></View>
        <View style={styles.checkRow}><Text style={styles.check}>✓</Text><Text style={styles.checkText}>Relay health check: ready</Text></View>
        <View style={styles.assistantActions}>
          <AppButton compact label="View decision" onPress={onOpenDecision} />
          <AppButton compact label="Report sample" onPress={onReport} variant="ghost" />
        </View>
      </View>
      <View style={styles.toolCard}>
        <Text style={styles.toolGlyph}>{"{}"}</Text>
        <View style={styles.toolCopy}>
          <Text style={styles.toolTitle}>release-check</Text>
          <Text style={styles.toolSummary}>3 checks passed · no secrets displayed</Text>
        </View>
        <Text style={styles.toolChevron}>›</Text>
      </View>
      <View style={styles.disabledComposer}>
        <Text style={styles.disabledComposerText}>Messaging is disabled in the store demo</Text>
        <View style={styles.disabledSend}><Text style={styles.disabledSendText}>↑</Text></View>
      </View>
    </DemoPage>
  );
}

function DecisionDemo({
  decision,
  onDecision,
}: {
  decision: "once" | "always" | "denied" | null;
  onDecision: (value: "once" | "always" | "denied") => void;
}) {
  const decisionLabel = decision === "once" ? "Allowed once" : decision === "always" ? "Allowed for this session" : "Denied";
  return (
    <DemoPage
      description="Sensitive agent actions stop here until you approve or deny them."
      eyebrow="NEEDS YOUR ATTENTION"
      title="Review a decision"
    >
      <View style={styles.decisionCard}>
        <View style={styles.warningIcon}><Text style={styles.warningIconText}>!</Text></View>
        <Text style={styles.decisionTitle}>Run a local migration check?</Text>
        <Text style={styles.decisionText}>The agent wants to inspect the schema in a temporary local test database.</Text>
        <View style={styles.commandPreview}>
          <Text style={styles.commandLabel}>PROPOSED COMMAND</Text>
          <Text selectable style={styles.commandText}>npm run db:check -- --local</Text>
        </View>
        <View style={styles.safetyRow}>
          <Text style={styles.safetyLabel}>Scope</Text>
          <Text style={styles.safetyValue}>Temporary sample database</Text>
        </View>
        <View style={styles.safetyRow}>
          <Text style={styles.safetyLabel}>Network</Text>
          <Text style={styles.safetyValue}>Not requested</Text>
        </View>
        {decision ? (
          <View style={styles.localResult}>
            <Text style={styles.localResultTitle}>{decisionLabel}</Text>
            <Text style={styles.localResultText}>Previewed locally. No decision was sent.</Text>
          </View>
        ) : null}
        <View style={styles.decisionActions}>
          <AppButton compact label="Allow once" onPress={() => onDecision("once")} />
          <AppButton compact label="Allow session" onPress={() => onDecision("always")} variant="secondary" />
          <AppButton compact label="Deny" onPress={() => onDecision("denied")} variant="danger" />
        </View>
      </View>
    </DemoPage>
  );
}

function TerminalDemo() {
  return (
    <DemoPage
      description="Inspect the source tmux pane when exact terminal output matters."
      eyebrow="READ-ONLY TERMINAL"
      title="Live pane preview"
    >
      <View style={styles.terminalToolbar}>
        <View style={styles.trafficLights}>
          <View style={[styles.trafficLight, { backgroundColor: colors.danger }]} />
          <View style={[styles.trafficLight, { backgroundColor: colors.warning }]} />
          <View style={[styles.trafficLight, { backgroundColor: colors.success }]} />
        </View>
        <Text style={styles.terminalTitle}>pass-remote — 92 × 28</Text>
        <View style={styles.livePill}><Text style={styles.liveText}>SAMPLE</Text></View>
      </View>
      <ScrollView horizontal style={styles.terminal}>
        <Text selectable style={styles.terminalText}>{DEMO_TERMINAL_LINES.join("\n")}</Text>
      </ScrollView>
      <View style={styles.terminalControls}>
        <Text style={styles.terminalControlsText}>Keyboard input is disabled in the store demo.</Text>
        <View style={styles.keyCaps}>
          {['esc', 'ctrl', '⌘', 'tab'].map((key) => <View key={key} style={styles.keyCap}><Text style={styles.keyCapText}>{key}</Text></View>)}
        </View>
      </View>
    </DemoPage>
  );
}

function SecurityDemo() {
  return (
    <DemoPage
      description="Each phone, tablet, and desktop has its own revocable credentials."
      eyebrow="DEVICE SECURITY"
      title="Paired devices"
    >
      <View style={styles.securityHero}>
        <View style={styles.shield}><Text style={styles.shieldText}>✓</Text></View>
        <View style={styles.securityHeroCopy}>
          <Text style={styles.securityHeroTitle}>Protected connection</Text>
          <Text style={styles.securityHeroText}>Short-lived access credentials · rotating refresh credentials · TLS</Text>
        </View>
      </View>
      <DeviceCard
        detail="Online now · Studio"
        glyph="▣"
        name="Studio Mac"
        tags={["Desktop", "Session owner"]}
      />
      <DeviceCard
        detail="This device · Active now"
        glyph="▯"
        name="Reviewer's phone"
        tags={["Mobile", "Read, write, decisions"]}
      />
      <View style={styles.securityCard}>
        <Text style={styles.securityCardTitle}>Pairing safeguards</Text>
        <SecurityLine label="QR validity" value="5 minutes" />
        <SecurityLine label="Pairing code" value="Single use" />
        <SecurityLine label="Access credential" value="15 minutes" />
        <SecurityLine label="Refresh credential" value="Rotates on use" />
      </View>
      <AppButton disabled label="Revoke sample device" onPress={() => undefined} variant="danger" />
      <Text style={styles.disabledHint}>Device changes are unavailable because this preview has no account.</Text>
    </DemoPage>
  );
}

function DeviceCard({ glyph, name, detail, tags }: { glyph: string; name: string; detail: string; tags: string[] }) {
  return (
    <View style={styles.deviceCard}>
      <View style={styles.deviceGlyph}><Text style={styles.deviceGlyphText}>{glyph}</Text></View>
      <View style={styles.deviceCopy}>
        <Text style={styles.deviceName}>{name}</Text>
        <Text style={styles.deviceDetail}>{detail}</Text>
        <View style={styles.tags}>{tags.map((tag) => <Text key={tag} style={styles.tag}>{tag}</Text>)}</View>
      </View>
    </View>
  );
}

function SecurityLine({ label, value }: { label: string; value: string }) {
  return (
    <View style={styles.securityLine}>
      <Text style={styles.securityLabel}>{label}</Text>
      <Text style={styles.securityValue}>{value}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  demoBanner: {
    minHeight: 58,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    backgroundColor: "#261f4a",
    borderBottomColor: "#4c4186",
    borderBottomWidth: 1,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    gap: spacing.sm,
  },
  demoIdentity: { flex: 1, minWidth: 0, flexDirection: "row", alignItems: "center", gap: spacing.sm },
  demoBadge: { backgroundColor: colors.accent, borderRadius: radius.pill, paddingHorizontal: 9, paddingVertical: 4 },
  demoBadgeText: { color: colors.white, fontSize: 10, lineHeight: 12, fontWeight: "900", letterSpacing: 1 },
  demoCopy: { flex: 1, minWidth: 0 },
  demoTitle: { color: colors.text, fontSize: 13, fontWeight: "800" },
  demoSubtitle: { color: "#b9b0ee", fontSize: 10, lineHeight: 15 },
  exitButton: { minHeight: 36, justifyContent: "center", borderWidth: 1, borderColor: "#7568bd", borderRadius: radius.sm, paddingHorizontal: 12 },
  exitText: { color: colors.white, fontSize: 12, fontWeight: "800" },
  pressed: { opacity: 0.7 },
  shell: { flex: 1, width: "100%", alignSelf: "center" },
  shellRegular: { maxWidth: 980 },
  brandRow: { paddingHorizontal: spacing.md, paddingTop: spacing.md, paddingBottom: spacing.sm, flexDirection: "row", alignItems: "center", gap: spacing.sm },
  mark: { width: 38, height: 38, borderRadius: 11, backgroundColor: colors.accent, alignItems: "center", justifyContent: "center" },
  markText: { color: colors.white, fontWeight: "900", fontSize: 20 },
  brand: { color: colors.text, fontSize: 17, fontWeight: "900" },
  desktop: { color: colors.muted, fontSize: 11, marginTop: 2 },
  nav: { flexGrow: 0, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.border },
  navContent: { paddingHorizontal: spacing.md, gap: spacing.xs },
  navItem: { minHeight: 44, paddingHorizontal: 12, flexDirection: "row", alignItems: "center", gap: 6, borderBottomWidth: 2, borderBottomColor: "transparent" },
  navItemSelected: { borderBottomColor: colors.accent },
  navGlyph: { color: colors.subtle, fontFamily: "Menlo", fontSize: 11, fontWeight: "900" },
  navText: { color: colors.muted, fontSize: 12, fontWeight: "800" },
  navTextSelected: { color: colors.text },
  contentFrame: { flex: 1 },
  page: { width: "100%", maxWidth: 760, alignSelf: "center", padding: spacing.md, paddingBottom: 96, gap: spacing.md },
  pageHeading: { gap: 5, paddingTop: spacing.sm, paddingBottom: spacing.xs },
  eyebrow: { color: colors.accent, fontSize: 10, fontWeight: "900", letterSpacing: 1.4 },
  pageTitle: { color: colors.text, fontSize: 27, lineHeight: 32, fontWeight: "900" },
  pageDescription: { color: colors.muted, fontSize: 14, lineHeight: 20 },
  readOnlyNote: { marginTop: spacing.sm, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: 4, backgroundColor: "#121519" },
  readOnlyTitle: { color: colors.text, fontSize: 12, fontWeight: "800" },
  readOnlyText: { color: colors.subtle, fontSize: 11, lineHeight: 17 },
  onlineRow: { flexDirection: "row", alignItems: "center", gap: 7, paddingVertical: 4 },
  onlineDot: { width: 8, height: 8, borderRadius: 4, backgroundColor: colors.success },
  onlineText: { color: colors.success, fontSize: 12, fontWeight: "800" },
  syncedText: { marginLeft: "auto", color: colors.subtle, fontSize: 11 },
  sectionHeading: { marginTop: spacing.sm, flexDirection: "row", alignItems: "center", gap: spacing.sm },
  sectionTitle: { color: colors.text, fontSize: 15, fontWeight: "800" },
  countBadge: { color: colors.muted, fontSize: 11, borderRadius: radius.pill, backgroundColor: colors.raised, paddingHorizontal: 7, paddingVertical: 2 },
  sessionCard: { backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border, borderRadius: radius.lg, padding: spacing.md, gap: 8 },
  sessionCardAttention: { borderColor: "#70572f", backgroundColor: "#211d17" },
  sessionTop: { flexDirection: "row", gap: spacing.sm, alignItems: "center" },
  sessionTitle: { color: colors.text, fontSize: 16, fontWeight: "800", flex: 1 },
  sessionStatus: { fontSize: 9, fontWeight: "900", letterSpacing: 0.65 },
  sessionMeta: { color: colors.subtle, fontSize: 11 },
  sessionPreview: { color: colors.muted, fontSize: 13, lineHeight: 19 },
  chatMetaRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between" },
  chatMeta: { color: colors.muted, fontSize: 12 },
  statusPill: { borderRadius: radius.pill, paddingHorizontal: 8, paddingVertical: 4, backgroundColor: "#173022" },
  statusPillText: { color: colors.success, fontSize: 9, fontWeight: "900", letterSpacing: 0.6 },
  userBubble: { maxWidth: "88%", alignSelf: "flex-end", borderRadius: radius.md, backgroundColor: "#252a31", borderWidth: 1, borderColor: "#353c46", padding: 13 },
  assistantBlock: { gap: spacing.sm, padding: spacing.md, borderRadius: radius.md, backgroundColor: colors.surface },
  agentRow: { flexDirection: "row", alignItems: "center", gap: 7 },
  agentDot: { width: 7, height: 7, borderRadius: 4, backgroundColor: colors.success },
  agentLabel: { color: colors.success, fontSize: 9, fontWeight: "900", letterSpacing: 1 },
  messageHeading: { color: colors.text, fontSize: 16, fontWeight: "800" },
  messageText: { color: "#e0e3e7", fontSize: 14, lineHeight: 21 },
  checkRow: { flexDirection: "row", alignItems: "flex-start", gap: spacing.sm },
  check: { color: colors.success, fontSize: 13, fontWeight: "900" },
  checkText: { color: colors.muted, fontSize: 13, lineHeight: 19, flex: 1 },
  assistantActions: { marginTop: spacing.xs, flexDirection: "row", flexWrap: "wrap", gap: spacing.sm },
  toolCard: { minHeight: 58, borderWidth: 1, borderColor: colors.border, borderRadius: radius.sm, flexDirection: "row", alignItems: "center", gap: spacing.sm, padding: spacing.sm, backgroundColor: "#121519" },
  toolGlyph: { width: 32, height: 32, textAlign: "center", textAlignVertical: "center", color: colors.success, backgroundColor: colors.raised, borderRadius: radius.sm, fontSize: 10, lineHeight: 32, fontFamily: "Menlo", fontWeight: "900" },
  toolCopy: { flex: 1, minWidth: 0, gap: 2 },
  toolTitle: { color: colors.text, fontFamily: "Menlo", fontSize: 11, fontWeight: "700" },
  toolSummary: { color: colors.subtle, fontSize: 10 },
  toolChevron: { color: colors.subtle, fontSize: 18 },
  disabledComposer: { minHeight: 52, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, backgroundColor: "#111419", flexDirection: "row", alignItems: "center", paddingLeft: 14, paddingRight: 7, gap: spacing.sm },
  disabledComposerText: { flex: 1, color: colors.subtle, fontSize: 12 },
  disabledSend: { width: 36, height: 36, borderRadius: 18, backgroundColor: colors.raised, alignItems: "center", justifyContent: "center", opacity: 0.5 },
  disabledSendText: { color: colors.muted, fontSize: 19, fontWeight: "900" },
  decisionCard: { borderRadius: radius.lg, backgroundColor: colors.surface, borderWidth: 1, borderColor: "#6a512b", padding: spacing.md, gap: spacing.md },
  warningIcon: { width: 42, height: 42, borderRadius: 21, alignItems: "center", justifyContent: "center", backgroundColor: "#3b2a15", borderWidth: 1, borderColor: "#70572f" },
  warningIconText: { color: colors.warning, fontWeight: "900", fontSize: 20 },
  decisionTitle: { color: colors.text, fontSize: 19, fontWeight: "900" },
  decisionText: { color: colors.muted, fontSize: 14, lineHeight: 21 },
  commandPreview: { padding: 13, borderRadius: radius.sm, backgroundColor: "#090b0f", gap: 7 },
  commandLabel: { color: colors.subtle, fontSize: 9, fontWeight: "900", letterSpacing: 0.8 },
  commandText: { color: "#a9e2c1", fontFamily: "Menlo", fontSize: 12 },
  safetyRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", gap: spacing.md, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.border, paddingBottom: spacing.sm },
  safetyLabel: { color: colors.subtle, fontSize: 12 },
  safetyValue: { color: colors.text, fontSize: 12, fontWeight: "700", textAlign: "right" },
  localResult: { borderRadius: radius.sm, padding: spacing.sm, backgroundColor: colors.accentSoft, gap: 3 },
  localResultTitle: { color: "#c5bcff", fontSize: 12, fontWeight: "800" },
  localResultText: { color: "#968dcc", fontSize: 11 },
  decisionActions: { flexDirection: "row", flexWrap: "wrap", gap: spacing.sm },
  terminalToolbar: { minHeight: 46, flexDirection: "row", alignItems: "center", paddingHorizontal: 12, borderTopLeftRadius: radius.md, borderTopRightRadius: radius.md, backgroundColor: "#1d2025", borderWidth: 1, borderColor: colors.border, gap: spacing.sm },
  trafficLights: { flexDirection: "row", gap: 5 },
  trafficLight: { width: 8, height: 8, borderRadius: 4 },
  terminalTitle: { flex: 1, color: colors.muted, fontFamily: "Menlo", fontSize: 10, textAlign: "center" },
  livePill: { borderRadius: radius.pill, backgroundColor: "#2a244b", paddingHorizontal: 7, paddingVertical: 3 },
  liveText: { color: "#bcb3ff", fontSize: 8, fontWeight: "900", letterSpacing: 0.6 },
  terminal: { minHeight: 286, backgroundColor: "#090b0f", borderLeftWidth: 1, borderRightWidth: 1, borderColor: colors.border, padding: spacing.md },
  terminalText: { color: "#cdd3db", fontFamily: "Menlo", fontSize: 12, lineHeight: 19, paddingRight: spacing.xl },
  terminalControls: { borderBottomLeftRadius: radius.md, borderBottomRightRadius: radius.md, borderWidth: 1, borderColor: colors.border, backgroundColor: "#121519", padding: spacing.sm, gap: spacing.sm },
  terminalControlsText: { color: colors.subtle, fontSize: 11 },
  keyCaps: { flexDirection: "row", gap: 7 },
  keyCap: { minWidth: 38, alignItems: "center", borderRadius: 6, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.raised, paddingHorizontal: 8, paddingVertical: 6, opacity: 0.55 },
  keyCapText: { color: colors.muted, fontSize: 10, fontWeight: "700" },
  securityHero: { flexDirection: "row", alignItems: "center", borderRadius: radius.lg, backgroundColor: "#13281d", borderWidth: 1, borderColor: "#275039", padding: spacing.md, gap: spacing.md },
  shield: { width: 48, height: 48, borderRadius: 18, backgroundColor: "#1d3b2a", alignItems: "center", justifyContent: "center" },
  shieldText: { color: colors.success, fontSize: 22, fontWeight: "900" },
  securityHeroCopy: { flex: 1, gap: 4 },
  securityHeroTitle: { color: colors.text, fontSize: 15, fontWeight: "900" },
  securityHeroText: { color: "#8fc3a4", fontSize: 11, lineHeight: 17 },
  deviceCard: { flexDirection: "row", borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.surface, padding: spacing.md, gap: spacing.md },
  deviceGlyph: { width: 44, height: 44, borderRadius: 13, alignItems: "center", justifyContent: "center", backgroundColor: colors.raised },
  deviceGlyphText: { color: colors.accent, fontSize: 22 },
  deviceCopy: { flex: 1, gap: 3 },
  deviceName: { color: colors.text, fontSize: 15, fontWeight: "800" },
  deviceDetail: { color: colors.muted, fontSize: 11 },
  tags: { marginTop: 5, flexDirection: "row", flexWrap: "wrap", gap: 5 },
  tag: { color: "#a9a0e5", backgroundColor: colors.accentSoft, borderRadius: radius.pill, paddingHorizontal: 7, paddingVertical: 3, fontSize: 9, fontWeight: "700" },
  securityCard: { borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: spacing.sm },
  securityCardTitle: { color: colors.text, fontSize: 14, fontWeight: "900", marginBottom: 2 },
  securityLine: { flexDirection: "row", justifyContent: "space-between", gap: spacing.md },
  securityLabel: { color: colors.subtle, fontSize: 12 },
  securityValue: { color: colors.text, fontSize: 12, fontWeight: "700" },
  disabledHint: { color: colors.subtle, fontSize: 10, textAlign: "center", marginTop: -8 },
  toast: { position: "absolute", left: spacing.md, right: spacing.md, bottom: spacing.md, maxWidth: 620, alignSelf: "center", borderRadius: radius.md, backgroundColor: "#312957", borderWidth: 1, borderColor: "#6659a5", padding: spacing.md, flexDirection: "row", alignItems: "center", gap: spacing.md },
  toastCopy: { flex: 1, gap: 3 },
  toastTitle: { color: colors.text, fontSize: 12, fontWeight: "800" },
  toastText: { color: "#bbb2ed", fontSize: 10, lineHeight: 15 },
  toastDismiss: { color: colors.white, fontSize: 11, fontWeight: "900" },
});
