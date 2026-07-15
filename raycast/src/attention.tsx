import { Color, Icon, launchCommand, LaunchType, MenuBarExtra } from "@raycast/api";
import { execFile } from "node:child_process";
import { attach } from "./lib/attach";
import { useSessions } from "./lib/hooks";
import { prefs } from "./lib/prefs";
import { Session } from "./lib/session";

/** Menu-bar count of pass sessions waiting on your answer, refreshed on the command's interval. */
export default function Command() {
  const { data: sessions = [], isLoading } = useSessions();

  const needsYou = sessions.filter((s) => s.status === "decision");
  const working = sessions.filter((s) => s.status === "working");

  const title = needsYou.length > 0 ? String(needsYou.length) : undefined;
  const icon = needsYou.length > 0 ? { source: Icon.QuestionMarkCircle, tintColor: Color.Orange } : Icon.Terminal;

  return (
    <MenuBarExtra isLoading={isLoading} icon={icon} title={title} tooltip="Pass sessions">
      {needsYou.length > 0 && (
        <MenuBarExtra.Section title="Needs your answer">
          {needsYou.map((s) => (
            <SessionMenuItem key={s.name} session={s} />
          ))}
        </MenuBarExtra.Section>
      )}
      {working.length > 0 && (
        <MenuBarExtra.Section title="Working">
          {working.map((s) => (
            <SessionMenuItem key={s.name} session={s} />
          ))}
        </MenuBarExtra.Section>
      )}
      {needsYou.length === 0 && working.length === 0 && (
        <MenuBarExtra.Item title="All quiet — nothing needs you" icon={Icon.Check} />
      )}
      <MenuBarExtra.Section>
        <MenuBarExtra.Item
          title="Open Session List"
          icon={Icon.List}
          onAction={() => launchCommand({ name: "list-sessions", type: LaunchType.UserInitiated })}
        />
        <MenuBarExtra.Item
          title="Open pass App"
          icon={Icon.AppWindow}
          onAction={() => execFile("/usr/bin/open", ["-b", "dev.lightsoft.pass"], () => undefined)}
        />
      </MenuBarExtra.Section>
    </MenuBarExtra>
  );
}

function SessionMenuItem({ session: s }: { session: Session }) {
  const subtitle = s.decisionPrompt?.split("\n")[0] ?? s.summary?.split("\n")[0];
  return (
    <MenuBarExtra.Item
      title={s.displayName}
      subtitle={subtitle ? ` — ${subtitle.slice(0, 60)}` : undefined}
      icon={s.emoji ? undefined : Icon.Terminal}
      tooltip="Attach in a terminal"
      onAction={() => attach(s.name, prefs().terminalApp)}
    />
  );
}
