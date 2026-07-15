import { Action, ActionPanel, Form, Icon, popToRoot, showToast, Toast } from "@raycast/api";
import { readFileSync } from "node:fs";
import { useState } from "react";
import { useSessions } from "../lib/hooks";
import { sendText } from "../lib/inject";
import { statusIcon } from "../lib/ui";

interface Props {
  /** Preselect this session (e.g. when pushed from the list). */
  presetSession?: string;
  /** Show a file picker whose contents get sent alongside/instead of the text. */
  allowFile?: boolean;
  navigationTitle: string;
  submitTitle: string;
}

/**
 * One form for "reply" and "send message": pick a session, type text and/or attach a file, and
 * inject it into the agent via bracketed paste. Refuses to type into a bare shell.
 */
export function MessageForm({ presetSession, allowFile = false, navigationTitle, submitTitle }: Props) {
  const { data: sessions = [], isLoading } = useSessions();
  const [textError, setTextError] = useState<string | undefined>();

  async function onSubmit(values: { session: string; text: string; files?: string[] }) {
    const parts: string[] = [];
    if (values.text?.trim()) parts.push(values.text);
    if (allowFile && values.files?.length) {
      try {
        for (const f of values.files) parts.push(readFileSync(f, "utf8"));
      } catch (e) {
        await showToast({ style: Toast.Style.Failure, title: "Could not read file", message: String(e) });
        return;
      }
    }
    const message = parts.join("\n").replace(/\n+$/, "");
    if (!message.trim()) {
      setTextError("Enter text or attach a file");
      return;
    }
    if (!values.session) {
      await showToast({ style: Toast.Style.Failure, title: "No session selected" });
      return;
    }

    const toast = await showToast({ style: Toast.Style.Animated, title: "Sending…" });
    const result = await sendText(values.session, message);
    if (result.ok) {
      toast.style = Toast.Style.Success;
      toast.title = `Sent to ${values.session}`;
      await popToRoot();
    } else if (result.reason === "refusedShell") {
      toast.style = Toast.Style.Failure;
      toast.title = "Agent not running";
      toast.message = "The pane is at a shell — refusing to type a command into it.";
    } else {
      toast.style = Toast.Style.Failure;
      toast.title = "Failed to send";
      toast.message = result.message;
    }
  }

  return (
    <Form
      isLoading={isLoading}
      navigationTitle={navigationTitle}
      actions={
        <ActionPanel>
          <Action.SubmitForm title={submitTitle} icon={Icon.Reply} onSubmit={onSubmit} />
        </ActionPanel>
      }
    >
      <Form.Dropdown id="session" title="Session" defaultValue={presetSession} storeValue={!presetSession}>
        {sessions.map((s) => (
          <Form.Dropdown.Item key={s.name} value={s.name} title={s.displayName} icon={statusIcon(s.status)} />
        ))}
      </Form.Dropdown>
      <Form.TextArea
        id="text"
        title="Message"
        placeholder="Type a reply to the agent…"
        error={textError}
        onChange={() => textError && setTextError(undefined)}
      />
      {allowFile && (
        <Form.FilePicker id="files" title="Attach File" allowMultipleSelection={false} canChooseDirectories={false} />
      )}
      {allowFile && <Form.Description text="If a file is attached, its contents are sent (appended after the text)." />}
    </Form>
  );
}
