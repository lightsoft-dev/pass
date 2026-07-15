import {
  Action,
  ActionPanel,
  Alert,
  Color,
  closeMainWindow,
  confirmAlert,
  Icon,
  Keyboard,
  List,
  showToast,
  Toast,
} from "@raycast/api";
import { useState } from "react";
import { MessageForm } from "./components/message-form";
import { attach } from "./lib/attach";
import { useSessions } from "./lib/hooks";
import { pick, sendDecision } from "./lib/inject";
import { prefs } from "./lib/prefs";
import { Session } from "./lib/session";
import { killSession } from "./lib/tmux";
import { shortAge, statusIcon, statusLabel } from "./lib/ui";

export default function Command() {
  const { data: sessions = [], isLoading, revalidate } = useSessions();
  const [showDetail, setShowDetail] = useState(false);

  return (
    <List isLoading={isLoading} isShowingDetail={showDetail} searchBarPlaceholder="Filter pass sessions…">
      <List.EmptyView
        icon={Icon.Terminal}
        title="No pass sessions"
        description="Start one with the New Session command, or from the pass menu bar app."
      />
      {sessions.map((s) => (
        <SessionItem
          key={s.name}
          session={s}
          showDetail={showDetail}
          onToggleDetail={() => setShowDetail((v) => !v)}
          onChanged={revalidate}
        />
      ))}
    </List>
  );
}

function SessionItem({
  session: s,
  showDetail,
  onToggleDetail,
  onChanged,
}: {
  session: Session;
  showDetail: boolean;
  onToggleDetail: () => void;
  onChanged: () => void;
}) {
  const summaryLine = s.summary?.split("\n")[0];

  const accessories: List.Item.Accessory[] = [];
  if (!showDetail) {
    if (s.emoji) accessories.push({ text: s.emoji });
    accessories.push({ tag: { value: `${s.glyph} ${s.agent}`, color: Color.SecondaryText } });
    if (s.status === "decision") accessories.push({ tag: { value: statusLabel(s.status), color: Color.Orange } });
    else if (s.status === "working") accessories.push({ tag: { value: statusLabel(s.status), color: Color.Blue } });
    if (s.attached) accessories.push({ icon: Icon.Desktop, tooltip: "Attached in a terminal" });
    accessories.push({ text: shortAge(s.activity), tooltip: s.activity.toLocaleString() });
  }

  return (
    <List.Item
      icon={statusIcon(s.status)}
      title={s.displayName}
      subtitle={showDetail ? undefined : summaryLine}
      accessories={accessories}
      detail={<SessionDetail session={s} />}
      actions={
        <ActionPanel>
          <ActionPanel.Section>
            {s.status === "decision" && s.decisionOptions.length > 0 && (
              <ActionPanel.Submenu title="Answer Prompt" icon={Icon.QuestionMarkCircle}>
                {s.decisionOptions.map((o) => (
                  <Action
                    key={o.number}
                    title={`${o.number}. ${o.label}`}
                    icon={o.highlighted ? Icon.CheckCircle : Icon.Circle}
                    onAction={() => runInject(() => pick(s.name, o.number), `Answered ${o.number}`, onChanged)}
                  />
                ))}
              </ActionPanel.Submenu>
            )}
            <Action.Push
              title="Reply…"
              icon={Icon.Reply}
              target={
                <MessageForm presetSession={s.name} navigationTitle={`Reply · ${s.name}`} submitTitle="Send Reply" />
              }
            />
            <Action.Push
              title="Send Message (Text / File)…"
              icon={Icon.Text}
              shortcut={{ modifiers: ["cmd"], key: "m" }}
              target={
                <MessageForm
                  presetSession={s.name}
                  allowFile
                  navigationTitle={`Send · ${s.name}`}
                  submitTitle="Send Message"
                />
              }
            />
          </ActionPanel.Section>

          <ActionPanel.Section>
            <Action
              title="Attach in Terminal"
              icon={Icon.Terminal}
              shortcut={{ modifiers: ["cmd"], key: "return" }}
              onAction={async () => {
                await closeMainWindow();
                const ok = await attach(s.name, prefs().terminalApp);
                if (!ok) await showToast({ style: Toast.Style.Failure, title: "Could not open a terminal" });
              }}
            />
            {s.status === "decision" && (
              <>
                <Action
                  title="Allow Once (1)"
                  icon={Icon.Check}
                  onAction={() => runInject(() => sendDecision(s.name, "allowOnce"), "Allowed once", onChanged)}
                />
                <Action
                  title="Allow Always (2)"
                  icon={Icon.CheckCircle}
                  onAction={() => runInject(() => sendDecision(s.name, "allowAll"), "Allowed always", onChanged)}
                />
                <Action
                  title="Deny (3)"
                  icon={Icon.XMarkCircle}
                  onAction={() => runInject(() => sendDecision(s.name, "deny"), "Denied", onChanged)}
                />
              </>
            )}
          </ActionPanel.Section>

          <ActionPanel.Section>
            <Action
              title={showDetail ? "Hide Details" : "Show Details"}
              icon={Icon.Sidebar}
              shortcut={{ modifiers: ["cmd"], key: "i" }}
              onAction={onToggleDetail}
            />
            <Action
              title="Refresh"
              icon={Icon.ArrowClockwise}
              shortcut={Keyboard.Shortcut.Common.Refresh}
              onAction={onChanged}
            />
            {s.summary && (
              <Action.CopyToClipboard
                title="Copy Last Response"
                content={s.summary}
                shortcut={Keyboard.Shortcut.Common.Copy}
              />
            )}
            <Action.CopyToClipboard title="Copy Session Name" content={s.name} />
          </ActionPanel.Section>

          <ActionPanel.Section>
            <Action
              title="Kill Session"
              icon={Icon.Trash}
              style={Action.Style.Destructive}
              shortcut={{ modifiers: ["ctrl"], key: "x" }}
              onAction={async () => {
                const confirmed = await confirmAlert({
                  title: `Kill ${s.name}?`,
                  message: "This ends the tmux session. The agent process is terminated.",
                  icon: Icon.Trash,
                  primaryAction: { title: "Kill Session", style: Alert.ActionStyle.Destructive },
                });
                if (!confirmed) return;
                await killSession(s.name);
                await showToast({ style: Toast.Style.Success, title: `Killed ${s.name}` });
                onChanged();
              }}
            />
          </ActionPanel.Section>
        </ActionPanel>
      }
    />
  );
}

function SessionDetail({ session: s }: { session: Session }) {
  const parts: string[] = [];
  if (s.status === "decision" && s.decisionPrompt) {
    parts.push(`### Prompt\n\n${s.decisionPrompt}`);
  }
  if (s.status === "decision" && s.decisionOptions.length) {
    parts.push(s.decisionOptions.map((o) => `${o.highlighted ? "▶" : " "} **${o.number}.** ${o.label}`).join("\n"));
  }
  if (s.summary) parts.push(`### Last Response\n\n${s.summary}`);
  const markdown = parts.join("\n\n") || "_No visible content yet._";

  return (
    <List.Item.Detail
      markdown={markdown}
      metadata={
        <List.Item.Detail.Metadata>
          <List.Item.Detail.Metadata.Label title="Session" text={s.name} />
          <List.Item.Detail.Metadata.Label
            title="Project"
            text={s.emoji ? `${s.emoji} ${s.projectName}` : s.projectName}
          />
          {s.branch && <List.Item.Detail.Metadata.Label title="Branch" text={s.branch} />}
          <List.Item.Detail.Metadata.Label title="Agent" text={`${s.glyph} ${s.agent}`} />
          <List.Item.Detail.Metadata.Label title="Status" text={statusLabel(s.status)} />
          <List.Item.Detail.Metadata.Label title="Directory" text={s.cwd} />
          <List.Item.Detail.Metadata.Label
            title="Attached"
            icon={s.attached ? Icon.Check : Icon.Minus}
            text={s.attached ? "Yes" : "No"}
          />
        </List.Item.Detail.Metadata>
      }
    />
  );
}

/** Run an injection, toast the outcome, and revalidate the list. */
async function runInject(
  action: () => Promise<{ ok: boolean; reason?: string }>,
  successTitle: string,
  onChanged: () => void,
) {
  const toast = await showToast({ style: Toast.Style.Animated, title: "Sending…" });
  const result = await action();
  if (result.ok) {
    toast.style = Toast.Style.Success;
    toast.title = successTitle;
  } else {
    toast.style = Toast.Style.Failure;
    toast.title = result.reason === "refusedShell" ? "Agent not running" : "Failed";
  }
  onChanged();
}
