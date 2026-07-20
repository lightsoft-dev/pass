import { useRouter } from "expo-router";
import { useEffect, useMemo, useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";

import { AppButton } from "../components/AppButton";
import { Screen } from "../components/Screen";
import { COMMAND_LIMITS } from "../protocol/commands";
import type { AgentKind } from "../protocol/types";
import { useRemote } from "../state/RemoteProvider";
import { selectProjects } from "../state/selectors";
import { colors, radius, spacing } from "../theme/theme";

type LaunchableAgent = Extract<AgentKind, "claude" | "codex" | "pi">;
const agents: Array<{ id: LaunchableAgent; glyph: string; detail: string }> = [
  { id: "claude", glyph: "✳", detail: "Claude Code" },
  { id: "codex", glyph: "⬢", detail: "OpenAI Codex" },
  { id: "pi", glyph: "π", detail: "Pi coding agent" },
];

export default function CreateSessionScreen() {
  const router = useRouter();
  const { state, createSession, refresh } = useRemote();
  const projects = useMemo(() => selectProjects(state), [state]);
  const [projectRoot, setProjectRoot] = useState("");
  const [agent, setAgent] = useState<LaunchableAgent>("claude");
  const [prompt, setPrompt] = useState("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!projectRoot && projects[0]) setProjectRoot(projects[0].rootPath);
  }, [projectRoot, projects]);

  const canCreate =
    state.connection.phase === "online" &&
    state.capabilities.includes("sessions:write") &&
    Boolean(projectRoot);

  const create = () => {
    const result = createSession(projectRoot, agent, prompt);
    if (result.ok) router.back();
    else setError(result.error);
  };

  return (
    <Screen edges={["left", "right", "bottom"]}>
      <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
        <View style={styles.section}>
          <View style={styles.sectionHeader}>
            <Text style={styles.sectionTitle}>Project</Text>
            <AppButton compact variant="ghost" label="Reload" onPress={() => refresh()} />
          </View>
          {projects.length === 0 ? (
            <View style={styles.empty}>
              <Text style={styles.emptyTitle}>No registered projects</Text>
              <Text style={styles.muted}>Add a project in the Pass desktop settings, then reload.</Text>
            </View>
          ) : (
            projects.map((project) => {
              const selected = project.rootPath === projectRoot;
              return (
                <Pressable
                  key={project.rootPath}
                  onPress={() => setProjectRoot(project.rootPath)}
                  style={[styles.choice, selected && styles.choiceSelected]}
                >
                  <Text style={styles.choiceEmoji}>{project.emoji ?? "▣"}</Text>
                  <View style={styles.choiceText}>
                    <Text style={styles.choiceTitle}>{project.name}</Text>
                    <Text style={styles.choiceDetail} numberOfLines={1}>{project.rootPath}</Text>
                  </View>
                  <Text style={selected ? styles.checkSelected : styles.check}>●</Text>
                </Pressable>
              );
            })
          )}
        </View>

        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Agent</Text>
          <View style={styles.agentGrid}>
            {agents.map((item) => {
              const selected = item.id === agent;
              return (
                <Pressable
                  key={item.id}
                  onPress={() => setAgent(item.id)}
                  style={[styles.agentChoice, selected && styles.choiceSelected]}
                >
                  <Text style={styles.agentGlyph}>{item.glyph}</Text>
                  <Text style={styles.agentName}>{item.id}</Text>
                  <Text style={styles.agentDetail}>{item.detail}</Text>
                </Pressable>
              );
            })}
          </View>
        </View>

        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Initial instruction (optional)</Text>
          <TextInput
            maxLength={COMMAND_LIMITS.initialPromptCharacters}
            multiline
            onChangeText={setPrompt}
            placeholder="Describe the task to start immediately…"
            placeholderTextColor={colors.subtle}
            style={styles.prompt}
            value={prompt}
          />
        </View>

        {error ? <Text style={styles.error}>{error}</Text> : null}
        <AppButton label="Create session" disabled={!canCreate} onPress={create} />
        {state.connection.phase !== "online" ? (
          <Text style={styles.muted}>The desktop must be online; creation commands are never buffered.</Text>
        ) : null}
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: spacing.md, paddingBottom: spacing.xl, gap: spacing.lg, maxWidth: 760, width: "100%", alignSelf: "center" },
  section: { gap: spacing.sm },
  sectionHeader: { flexDirection: "row", justifyContent: "space-between", alignItems: "center" },
  sectionTitle: { color: colors.text, fontSize: 15, fontWeight: "800" },
  choice: { flexDirection: "row", alignItems: "center", gap: spacing.sm, backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, padding: spacing.md },
  choiceSelected: { borderColor: colors.accent, backgroundColor: colors.accentSoft },
  choiceEmoji: { fontSize: 22 },
  choiceText: { flex: 1, gap: 3 },
  choiceTitle: { color: colors.text, fontSize: 15, fontWeight: "700" },
  choiceDetail: { color: colors.subtle, fontSize: 11 },
  check: { color: colors.border },
  checkSelected: { color: colors.accent },
  agentGrid: { flexDirection: "row", gap: spacing.sm },
  agentChoice: { flex: 1, alignItems: "center", backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, padding: spacing.sm, gap: 4 },
  agentGlyph: { color: colors.text, fontSize: 22 },
  agentName: { color: colors.text, fontSize: 13, fontWeight: "800", textTransform: "capitalize" },
  agentDetail: { color: colors.subtle, fontSize: 9, textAlign: "center" },
  prompt: { minHeight: 120, color: colors.text, backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, padding: spacing.md, textAlignVertical: "top", fontSize: 14, lineHeight: 21 },
  empty: { backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, padding: spacing.md, gap: spacing.xs },
  emptyTitle: { color: colors.text, fontWeight: "700" },
  muted: { color: colors.muted, fontSize: 13, lineHeight: 19 },
  error: { color: colors.danger, fontSize: 13 },
});
