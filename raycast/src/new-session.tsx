import { Action, ActionPanel, Form, Icon, popToRoot, showToast, Toast } from "@raycast/api";
import { existsSync, statSync } from "node:fs";
import { basename } from "node:path";
import { useMemo, useState } from "react";
import { attach } from "./lib/attach";
import { AgentKind, agentGlyph, sessionName } from "./lib/config";
import { hasSession, newSession } from "./lib/tmux";
import { launchCommandFor, prefs } from "./lib/prefs";
import { loadProjects } from "./lib/projects";

const AGENT_CHOICES: { value: AgentKind; title: string }[] = [
  { value: "claude", title: "Claude" },
  { value: "codex", title: "Codex" },
  { value: "pi", title: "pi" },
  { value: "shell", title: "Shell (no agent)" },
];

export default function Command() {
  const projects = useMemo(() => loadProjects(), []);
  const [dirError, setDirError] = useState<string | undefined>();

  async function onSubmit(values: {
    project: string;
    customDir: string;
    branch: string;
    agent: AgentKind;
    openTerminal: boolean;
  }) {
    const dir = (values.customDir?.trim() || values.project || "").replace(/\/+$/, "");
    if (!dir) {
      setDirError("Pick a project or enter a directory");
      return;
    }
    if (!existsSync(dir) || !statSync(dir).isDirectory()) {
      setDirError("Directory does not exist");
      return;
    }

    const name = sessionName(basename(dir), values.branch);
    if (await hasSession(name)) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Session already exists",
        message: name,
      });
      return;
    }

    const toast = await showToast({ style: Toast.Style.Animated, title: `Creating ${name}…` });
    try {
      await newSession({
        name,
        cwd: dir,
        projectRoot: dir,
        agent: values.agent,
        launchCommand: launchCommandFor(values.agent),
      });
      if (values.openTerminal) await attach(name, prefs().terminalApp);
      toast.style = Toast.Style.Success;
      toast.title = `Created ${name}`;
      await popToRoot();
    } catch (e) {
      toast.style = Toast.Style.Failure;
      toast.title = "Failed to create session";
      toast.message = String(e);
    }
  }

  return (
    <Form
      navigationTitle="New Session"
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Create Session" icon={Icon.Plus} onSubmit={onSubmit} />
        </ActionPanel>
      }
    >
      <Form.Dropdown id="project" title="Project" storeValue>
        {projects.map((p) => (
          <Form.Dropdown.Item
            key={p.rootPath}
            value={p.rootPath}
            title={p.emoji ? `${p.emoji} ${p.name}` : p.name}
            keywords={[p.rootPath]}
          />
        ))}
      </Form.Dropdown>
      <Form.TextField
        id="customDir"
        title="Or Directory"
        placeholder="/absolute/path (overrides the project above)"
        error={dirError}
        onChange={() => dirError && setDirError(undefined)}
      />
      <Form.TextField
        id="branch"
        title="Branch / Label"
        placeholder="optional — becomes the pass-<repo>--<label> suffix"
      />
      <Form.Dropdown id="agent" title="Agent" storeValue defaultValue="claude">
        {AGENT_CHOICES.map((a) => (
          <Form.Dropdown.Item key={a.value} value={a.value} title={`${agentGlyph(a.value)}  ${a.title}`} />
        ))}
      </Form.Dropdown>
      <Form.Checkbox id="openTerminal" label="Open a terminal attached to the session" defaultValue={true} />
      <Form.Description text="Creates a detached tmux session (pass-<repo>[--<label>]) and launches the agent. pass picks it up automatically on its next reconcile." />
    </Form>
  );
}
