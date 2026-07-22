import { useEffect, useRef, useState } from "react";
import {
  ActivityIndicator,
  Pressable,
  StyleSheet,
  Text,
  View,
} from "react-native";
import { WebView, type WebViewMessageEvent } from "react-native-webview";

import type { SessionTerminalSnapshotPayload } from "../protocol/types";
import { terminalDocument } from "../terminal/terminalDocument.generated";
import { colors, spacing } from "../theme/theme";

type Props = {
  snapshot?: SessionTerminalSnapshotPayload;
  enabled: boolean;
  error?: string | null;
  onInput: (input: string) => void;
  onError?: (message: string) => void;
};

type ViewportMode = "readable" | "fit" | "native";

const keys = [
  { label: "Esc", input: "\u001b" },
  { label: "Tab", input: "\t" },
  { label: "^C", input: "\u0003" },
  { label: "←", input: "\u001b[D" },
  { label: "↓", input: "\u001b[B" },
  { label: "↑", input: "\u001b[A" },
  { label: "→", input: "\u001b[C" },
  { label: "↵", input: "\r" },
] as const;

export function TerminalSurface({ snapshot, enabled, error, onInput, onError }: Props) {
  const webView = useRef<WebView>(null);
  const [ready, setReady] = useState(false);
  const [viewportMode, setViewportMode] = useState<ViewportMode>("readable");

  useEffect(() => {
    if (!ready || !snapshot || snapshot.content === undefined || snapshot.content === null) return;
    webView.current?.postMessage(JSON.stringify({
      type: "snapshot",
      ...snapshot,
      content: snapshot.content,
    }));
  }, [ready, snapshot]);

  useEffect(() => {
    if (!ready) return;
    webView.current?.postMessage(JSON.stringify({ type: "viewportMode", value: viewportMode }));
  }, [ready, viewportMode]);

  const handleMessage = (event: WebViewMessageEvent) => {
    try {
      const message = JSON.parse(event.nativeEvent.data) as {
        type?: string;
        data?: unknown;
        message?: unknown;
      };
      if (message.type === "ready") {
        setReady(true);
      } else if (message.type === "input" && typeof message.data === "string") {
        if (enabled) onInput(message.data);
      } else if (message.type === "error" && typeof message.message === "string") {
        onError?.(message.message);
      }
    } catch {
      onError?.("Terminal renderer sent an invalid message.");
    }
  };

  const changeViewportMode = (value: ViewportMode) => {
    setViewportMode(value);
  };

  return (
    <View style={styles.container}>
      <View style={styles.statusBar}>
        <View style={styles.liveGroup}>
          <View style={[styles.statusDot, enabled ? styles.onlineDot : styles.offlineDot]} />
          <Text style={styles.statusText}>{enabled ? "LIVE TTY" : "READ ONLY"}</Text>
        </View>
        <Text style={styles.dimensions}>
          {snapshot ? `${snapshot.columns}×${snapshot.rows}` : "Waiting for pane"}
          {snapshot?.truncated ? " · TRUNCATED" : ""}
        </Text>
        <View style={styles.viewportControl}>
          {(["readable", "fit", "native"] as const).map((mode) => (
            <Pressable
              key={mode}
              accessibilityLabel={
                mode === "readable"
                  ? "Use readable terminal text"
                  : mode === "fit"
                    ? "Fit terminal to screen width"
                    : "Show terminal at actual size"
              }
              accessibilityState={{ selected: viewportMode === mode }}
              hitSlop={6}
              onPress={() => changeViewportMode(mode)}
              style={[styles.viewportButton, viewportMode === mode && styles.viewportButtonSelected]}
            >
              <Text style={[styles.viewportText, viewportMode === mode && styles.viewportTextSelected]}>
                {mode === "readable" ? "Read" : mode === "fit" ? "Fit" : "1:1"}
              </Text>
            </Pressable>
          ))}
        </View>
      </View>

      {error ? (
        <View style={styles.errorBar}>
          <Text numberOfLines={2} style={styles.errorText}>{error}</Text>
        </View>
      ) : null}

      <View style={styles.webViewShell}>
        <WebView
          ref={webView}
          accessibilityLabel="Remote tmux terminal"
          allowsLinkPreview={false}
          bounces={false}
          domStorageEnabled={false}
          hideKeyboardAccessoryView
          javaScriptEnabled
          keyboardDisplayRequiresUserAction={false}
          onMessage={handleMessage}
          onShouldStartLoadWithRequest={(request) => request.url === "about:blank"}
          originWhitelist={["about:*"]}
          scrollEnabled={false}
          setSupportMultipleWindows={false}
          source={{ html: terminalDocument }}
          style={styles.webView}
        />
        {!ready || !snapshot ? (
          <View pointerEvents="none" style={styles.loading}>
            <ActivityIndicator color={colors.accent} />
            <Text style={styles.loadingText}>
              {ready ? "Opening tmux pane…" : "Starting terminal renderer…"}
            </Text>
          </View>
        ) : null}
      </View>

      <View style={styles.keyRow}>
        {keys.map((key) => (
          <Pressable
            key={key.label}
            accessibilityLabel={`Send ${key.label} to terminal`}
            disabled={!enabled}
            onPress={() => onInput(key.input)}
            style={({ pressed }) => [
              styles.key,
              !enabled && styles.keyDisabled,
              pressed && enabled && styles.keyPressed,
            ]}
          >
            <Text style={styles.keyText}>{key.label}</Text>
          </Pressable>
        ))}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, minHeight: 320, backgroundColor: "#090b0f" },
  statusBar: {
    height: 38,
    paddingHorizontal: spacing.sm,
    flexDirection: "row",
    alignItems: "center",
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#282d35",
    backgroundColor: "#111318",
  },
  liveGroup: { flexDirection: "row", alignItems: "center", gap: 7 },
  statusDot: { width: 7, height: 7, borderRadius: 4 },
  onlineDot: { backgroundColor: "#72d39a" },
  offlineDot: { backgroundColor: "#646b75" },
  statusText: { color: "#abb2bd", fontSize: 10, fontWeight: "800" },
  dimensions: { flex: 1, color: "#747c87", fontSize: 10, textAlign: "center" },
  viewportControl: {
    width: 112,
    height: 28,
    padding: 2,
    flexDirection: "row",
    alignItems: "center",
    borderWidth: 1,
    borderColor: "#303640",
    borderRadius: 6,
    backgroundColor: "#090b0f",
  },
  viewportButton: {
    flex: 1,
    height: 22,
    alignItems: "center",
    justifyContent: "center",
    borderRadius: 4,
  },
  viewportButtonSelected: { backgroundColor: "#303640" },
  viewportText: { color: "#747c87", fontSize: 10, fontWeight: "700" },
  viewportTextSelected: { color: "#d7dce2" },
  errorBar: {
    minHeight: 30,
    paddingHorizontal: spacing.sm,
    paddingVertical: 6,
    justifyContent: "center",
    backgroundColor: "#30191d",
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#71343d",
  },
  errorText: { color: "#ff9aa3", fontSize: 11, lineHeight: 15 },
  webViewShell: { flex: 1, minHeight: 240, backgroundColor: "#090b0f" },
  webView: { flex: 1, backgroundColor: "#090b0f" },
  loading: {
    ...StyleSheet.absoluteFill,
    alignItems: "center",
    justifyContent: "center",
    gap: spacing.sm,
    backgroundColor: "#090b0f",
  },
  loadingText: { color: "#747c87", fontSize: 12 },
  keyRow: {
    height: 46,
    paddingHorizontal: 5,
    flexDirection: "row",
    alignItems: "center",
    gap: 4,
    backgroundColor: "#111318",
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: "#282d35",
  },
  key: {
    flex: 1,
    height: 34,
    minWidth: 34,
    alignItems: "center",
    justifyContent: "center",
    borderWidth: 1,
    borderColor: "#303640",
    backgroundColor: "#1a1e24",
    borderRadius: 6,
  },
  keyPressed: { backgroundColor: "#31594c", borderColor: "#4f8d76" },
  keyDisabled: { opacity: 0.42 },
  keyText: { color: "#d7dce2", fontSize: 11, fontWeight: "700" },
});
