import { useRef, useState } from "react";
import {
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
  type NativeScrollEvent,
  type NativeSyntheticEvent,
} from "react-native";

import type { ConversationBlock } from "../conversation/terminalConversation";
import {
  parseRichSections,
  type RichSection,
  type TableAlignment,
} from "../conversation/richText";
import { colors, spacing } from "../theme/theme";

type Props = {
  blocks: ConversationBlock[];
  truncated?: boolean;
};

function InlineText({ value }: { value: string }) {
  return value.split(/(`[^`]+`|\*\*[^*]+\*\*)/g).map((part, index) => {
    if (part.startsWith("`") && part.endsWith("`")) {
      return <Text key={index} style={styles.inlineCode}>{part.slice(1, -1)}</Text>;
    }
    if (part.startsWith("**") && part.endsWith("**")) {
      return <Text key={index} style={styles.strong}>{part.slice(2, -2)}</Text>;
    }
    return part;
  });
}

function readableLength(value: string): number {
  return Array.from(value).reduce(
    (length, character) => length + (/[^\u0000-\u00ff]/.test(character) ? 2 : 1),
    0,
  );
}

function alignmentStyle(alignment: TableAlignment) {
  return alignment === "center"
    ? styles.tableTextCenter
    : alignment === "right"
      ? styles.tableTextRight
      : styles.tableTextLeft;
}

function TableSection({ section }: { section: Extract<RichSection, { kind: "table" }> }) {
  const widths = section.headers.map((header, columnIndex) => {
    const longest = Math.max(
      readableLength(header),
      ...section.rows.map((row) => readableLength(row[columnIndex] ?? "")),
    );
    return Math.max(104, Math.min(224, 28 + longest * 7.5));
  });
  const rows = [section.headers, ...section.rows];

  return (
    <ScrollView
      accessibilityLabel={`Table with ${section.headers.length} columns and ${section.rows.length} rows`}
      horizontal
      nestedScrollEnabled
      showsHorizontalScrollIndicator={section.headers.length > 2}
      style={styles.tableScroll}
    >
      <View style={styles.table}>
        {rows.map((row, rowIndex) => (
          <View
            key={rowIndex}
            style={[
              styles.tableRow,
              rowIndex === 0 && styles.tableHeaderRow,
              rowIndex > 0 && rowIndex % 2 === 0 && styles.tableAlternateRow,
              rowIndex < rows.length - 1 && styles.tableRowBorder,
            ]}
          >
            {widths.map((width, columnIndex) => (
              <View
                key={columnIndex}
                style={[
                  styles.tableCell,
                  { width },
                  columnIndex < widths.length - 1 && styles.tableCellBorder,
                ]}
              >
                <Text
                  selectable
                  style={[
                    styles.tableText,
                    rowIndex === 0 && styles.tableHeaderText,
                    alignmentStyle(section.alignments[columnIndex] ?? "left"),
                  ]}
                >
                  <InlineText value={row[columnIndex] ?? ""} />
                </Text>
              </View>
            ))}
          </View>
        ))}
      </View>
    </ScrollView>
  );
}

function RichMessage({ text }: { text: string }) {
  return (
    <View style={styles.richMessage}>
      {parseRichSections(text).map((section, index) => {
        if (section.kind === "table") {
          return <TableSection key={index} section={section} />;
        }
        if (section.kind === "code") {
          return (
            <View key={index} style={styles.codeBlock}>
              {section.language ? <Text style={styles.codeLanguage}>{section.language}</Text> : null}
              <ScrollView horizontal showsHorizontalScrollIndicator={false}>
                <Text selectable style={styles.codeText}>{section.text}</Text>
              </ScrollView>
            </View>
          );
        }
        if (section.kind === "heading") {
          return <Text key={index} style={styles.messageHeading}><InlineText value={section.text} /></Text>;
        }
        if (section.kind === "bullet" || section.kind === "number") {
          return (
            <View key={index} style={styles.listRow}>
              <Text style={styles.listMarker}>{section.kind === "bullet" ? "•" : section.marker}</Text>
              <Text selectable style={[styles.messageText, styles.listText]}><InlineText value={section.text} /></Text>
            </View>
          );
        }
        return <Text key={index} selectable style={styles.messageText}><InlineText value={section.text} /></Text>;
      })}
    </View>
  );
}

function ToolBlock({ block }: { block: ConversationBlock }) {
  const [expanded, setExpanded] = useState(false);
  const summary = block.text.split("\n").find(Boolean);
  return (
    <View style={styles.toolBlock}>
      <Pressable
        accessibilityLabel={`${expanded ? "Collapse" : "Expand"} ${block.title ?? "tool output"}`}
        accessibilityRole="button"
        onPress={() => setExpanded((value) => !value)}
        style={({ pressed }) => [styles.toolHeader, pressed && styles.pressed]}
      >
        <View style={styles.toolMark}><Text style={styles.toolMarkText}>{"{}"}</Text></View>
        <View style={styles.toolCopy}>
          <Text numberOfLines={1} style={styles.toolTitle}>{block.title ?? "Terminal output"}</Text>
          {!expanded && summary ? <Text numberOfLines={1} style={styles.toolSummary}>{summary}</Text> : null}
        </View>
        <Text style={styles.chevron}>{expanded ? "⌄" : "›"}</Text>
      </Pressable>
      {expanded && block.text ? (
        <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.toolOutput}>
          <Text selectable style={styles.toolOutputText}>{block.text}</Text>
        </ScrollView>
      ) : null}
    </View>
  );
}

function ConversationItem({ block }: { block: ConversationBlock }) {
  if (block.kind === "tool") return <ToolBlock block={block} />;
  if (block.kind === "output") {
    return (
      <View style={styles.outputBlock}>
        <Text selectable style={styles.outputText}>{block.text}</Text>
      </View>
    );
  }
  if (block.kind === "user") {
    return (
      <View style={styles.userRow}>
        <View style={styles.userMessage}><RichMessage text={block.text} /></View>
      </View>
    );
  }
  return (
    <View style={styles.assistantMessage}>
      {block.streaming ? (
        <View style={styles.assistantMeta}>
          <View style={[styles.agentDot, styles.streamingDot]} />
          <Text style={styles.liveLabel}>LIVE</Text>
        </View>
      ) : null}
      <RichMessage text={block.text} />
    </View>
  );
}

export function ConversationSurface({ blocks, truncated = false }: Props) {
  const scrollView = useRef<ScrollView>(null);
  const nearBottom = useRef(true);
  const handleScroll = (event: NativeSyntheticEvent<NativeScrollEvent>) => {
    const { contentOffset, contentSize, layoutMeasurement } = event.nativeEvent;
    nearBottom.current = contentSize.height - contentOffset.y - layoutMeasurement.height < 80;
  };
  const followLatest = () => {
    if (nearBottom.current) scrollView.current?.scrollToEnd({ animated: false });
  };

  return (
    <ScrollView
      ref={scrollView}
      contentContainerStyle={styles.content}
      keyboardDismissMode="interactive"
      keyboardShouldPersistTaps="handled"
      onContentSizeChange={followLatest}
      onScroll={handleScroll}
      scrollEventThrottle={80}
    >
      {blocks.length ? blocks.map((block) => (
        <ConversationItem block={block} key={block.id} />
      )) : (
        <View style={styles.emptyState}>
          <View style={styles.emptyLine} />
          <Text style={styles.emptyTitle}>Waiting for output</Text>
          <Text style={styles.emptyText}>The next agent response will appear here.</Text>
        </View>
      )}
      {truncated ? <Text style={styles.truncated}>Response truncated at the transport limit.</Text> : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  content: {
    width: "100%",
    maxWidth: 760,
    alignSelf: "center",
    paddingHorizontal: spacing.md,
    paddingTop: spacing.lg,
    paddingBottom: spacing.xl,
    gap: 18,
  },
  userRow: { alignItems: "flex-end", flexGrow: 0 },
  userMessage: {
    maxWidth: "88%",
    flexGrow: 0,
    flexShrink: 1,
    paddingHorizontal: 14,
    paddingVertical: 11,
    backgroundColor: "#252a31",
    borderWidth: 1,
    borderColor: "#353c46",
    borderRadius: 8,
  },
  assistantMessage: { gap: 9, paddingLeft: 2 },
  assistantMeta: { flexDirection: "row", alignItems: "center", gap: 7 },
  agentDot: { width: 7, height: 7, borderRadius: 4, backgroundColor: "#69c89a" },
  streamingDot: { backgroundColor: "#72b7ff" },
  liveLabel: { color: "#72b7ff", fontSize: 9, fontWeight: "900" },
  richMessage: { gap: 8 },
  messageText: { color: "#e6e9ed", fontSize: 15, lineHeight: 23 },
  listText: { flex: 1, minWidth: 0 },
  messageHeading: { color: "#ffffff", fontSize: 16, lineHeight: 22, fontWeight: "800", marginTop: 4 },
  strong: { color: "#ffffff", fontWeight: "800" },
  inlineCode: { color: "#8edbb5", fontFamily: "Menlo", fontSize: 13, backgroundColor: "#17221e" },
  listRow: { flexDirection: "row", alignItems: "flex-start", gap: 9 },
  listMarker: { width: 18, color: "#69c89a", fontSize: 13, lineHeight: 23, fontWeight: "800", textAlign: "right" },
  codeBlock: { backgroundColor: "#0a0c0f", borderLeftWidth: 2, borderLeftColor: "#4c8b70", padding: 12, gap: 8 },
  codeLanguage: { color: "#6f7884", fontSize: 9, fontWeight: "800", textTransform: "uppercase" },
  codeText: { color: "#cfd5dc", fontFamily: "Menlo", fontSize: 11, lineHeight: 17 },
  tableScroll: {
    maxWidth: "100%",
    borderWidth: 1,
    borderColor: "#353c46",
    borderRadius: 6,
    backgroundColor: "#121519",
  },
  table: { overflow: "hidden" },
  tableRow: { flexDirection: "row", backgroundColor: "#121519" },
  tableHeaderRow: { backgroundColor: "#20262d" },
  tableAlternateRow: { backgroundColor: "#171b20" },
  tableRowBorder: { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: "#353c46" },
  tableCell: { minHeight: 42, paddingHorizontal: 11, paddingVertical: 10, justifyContent: "center" },
  tableCellBorder: { borderRightWidth: StyleSheet.hairlineWidth, borderRightColor: "#353c46" },
  tableText: { color: "#d7dce2", fontSize: 13, lineHeight: 19 },
  tableHeaderText: { color: "#ffffff", fontWeight: "800" },
  tableTextLeft: { textAlign: "left" },
  tableTextCenter: { textAlign: "center" },
  tableTextRight: { textAlign: "right" },
  toolBlock: { borderWidth: 1, borderColor: "#292f37", borderRadius: 7, backgroundColor: "#121519", overflow: "hidden" },
  toolHeader: { minHeight: 48, flexDirection: "row", alignItems: "center", paddingHorizontal: 10, gap: 10 },
  pressed: { opacity: 0.72 },
  toolMark: { width: 28, height: 28, alignItems: "center", justifyContent: "center", borderRadius: 6, backgroundColor: "#20262d" },
  toolMarkText: { color: "#8edbb5", fontFamily: "Menlo", fontSize: 10, fontWeight: "800" },
  toolCopy: { flex: 1, minWidth: 0, gap: 2 },
  toolTitle: { color: "#d7dce2", fontFamily: "Menlo", fontSize: 11, fontWeight: "700" },
  toolSummary: { color: "#737c88", fontSize: 10 },
  chevron: { width: 20, color: "#7f8995", fontSize: 18, textAlign: "center" },
  toolOutput: { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: "#292f37", padding: 11 },
  toolOutputText: { color: "#9da6b1", fontFamily: "Menlo", fontSize: 10, lineHeight: 16, paddingRight: 20 },
  outputBlock: { padding: 11, backgroundColor: "#0a0c0f", borderLeftWidth: 2, borderLeftColor: "#4b535e" },
  outputText: { color: "#a9b1bb", fontFamily: "Menlo", fontSize: 10, lineHeight: 16 },
  emptyState: { minHeight: 280, alignItems: "center", justifyContent: "center", gap: 8, paddingHorizontal: spacing.xl },
  emptyLine: { width: 32, height: 2, backgroundColor: "#69c89a", marginBottom: 4 },
  emptyTitle: { color: colors.text, fontSize: 15, fontWeight: "800" },
  emptyText: { color: colors.subtle, fontSize: 12, textAlign: "center" },
  truncated: { color: colors.warning, fontSize: 10, textAlign: "center" },
});
