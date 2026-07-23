import Foundation

/// Installs the event bridge for every agent Pass can launch.
///
/// Each agent has a different extension surface:
/// - Claude Code: native HTTP hooks in `~/.claude/settings.json`
/// - Codex: command hooks in `~/.codex/hooks.json`
/// - pi: a global TypeScript extension in `~/.pi/agent/extensions`
enum AgentHooksInstaller {
    enum Status: Equatable {
        case installed
        case alreadyInstalled
        case failed(String)
    }

    static func isInstalled() -> Bool {
        AgentKind.launchable.allSatisfy { isInstalled(for: $0) }
    }

    static func isInstalled(for agent: AgentKind) -> Bool {
        switch agent {
        case .claude: return ClaudeHooksInstaller.isInstalled()
        case .codex: return CodexHooksInstaller.isInstalled()
        case .pi: return PiHooksInstaller.isInstalled()
        case .shell, .generic: return true
        }
    }

    @discardableResult
    static func install(for agent: AgentKind) -> Status {
        switch agent {
        case .claude:
            return map(ClaudeHooksInstaller.install())
        case .codex:
            return CodexHooksInstaller.install()
        case .pi:
            return PiHooksInstaller.install()
        case .shell, .generic:
            return .alreadyInstalled
        }
    }

    @discardableResult
    static func installAll() -> Status {
        var changed = false
        var failures: [String] = []

        for agent in AgentKind.launchable {
            switch install(for: agent) {
            case .installed:
                changed = true
            case .alreadyInstalled:
                break
            case .failed(let message):
                failures.append("\(agent.rawValue): \(message)")
            }
        }

        if !failures.isEmpty { return .failed(failures.joined(separator: " · ")) }
        return changed ? .installed : .alreadyInstalled
    }

    private static func map(_ status: ClaudeHooksInstaller.Status) -> Status {
        switch status {
        case .installed: return .installed
        case .alreadyInstalled: return .alreadyInstalled
        case .failed(let message): return .failed(message)
        }
    }
}

/// Codex supports command lifecycle hooks. Pass adds one curl handler to each event while
/// retaining all existing matcher groups and handlers in the user's hooks.json.
enum CodexHooksInstaller {
    static let events = ["SessionStart", "PermissionRequest", "UserPromptSubmit", "Stop"]
    static var hookURL: String { "\(PassConfig.hookBaseURL)/hook/codex" }
    static var hookCommand: String {
        #"/usr/bin/curl --silent --max-time 2 --header 'Content-Type: application/json' --header "X-Pass-Session: $PASS_SESSION" --data-binary @- '"#
            + hookURL
            + #"' >/dev/null 2>&1 || true"#
    }

    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/hooks.json")
    }

    static func isInstalled() -> Bool {
        guard let root = readJSON(at: settingsURL) else { return false }
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return events.allSatisfy {
            hasOurHook(in: hooks[$0] as? [[String: Any]] ?? [])
        }
    }

    @discardableResult
    static func install() -> AgentHooksInstaller.Status {
        let existing = readJSON(at: settingsURL) ?? [:]
        let (root, changed) = merged(into: existing)
        guard changed else { return .alreadyInstalled }

        backupIfNeeded(settingsURL)
        return writeJSON(root, to: settingsURL)
    }

    /// Pure merge used by tests and by the on-device installer.
    static func merged(into existing: [String: Any]) -> (root: [String: Any], changed: Bool) {
        var root = existing
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            guard !hasOurHook(in: groups) else { continue }
            groups.append([
                "hooks": [[
                    "type": "command",
                    "command": hookCommand,
                    "timeout": 3,
                    "statusMessage": "Notifying Pass",
                ] as [String: Any]],
            ])
            hooks[event] = groups
            changed = true
        }
        root["hooks"] = hooks
        return (root, changed)
    }

    private static func hasOurHook(in groups: [[String: Any]]) -> Bool {
        groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { hook in
                guard (hook["type"] as? String) == "command",
                      let command = hook["command"] as? String else { return false }
                return command.contains(hookURL) && command.contains("X-Pass-Session")
            }
        }
    }
}

/// pi exposes lifecycle events through global TypeScript extensions. The generated extension
/// has no dependencies and posts a small Claude-compatible envelope to Pass's pi route.
enum PiHooksInstaller {
    static let marker = "// pass-agent-hooks v1"

    private static var extensionURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/extensions/dev.lightsoft.pass-hooks.ts")
    }

    static func isInstalled() -> Bool {
        guard let source = try? String(contentsOf: extensionURL, encoding: .utf8) else {
            return false
        }
        return source == extensionSource
    }

    @discardableResult
    static func install() -> AgentHooksInstaller.Status {
        if isInstalled() { return .alreadyInstalled }
        backupIfNeeded(extensionURL)
        do {
            try FileManager.default.createDirectory(
                at: extensionURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(extensionSource.utf8).write(to: extensionURL, options: .atomic)
            Log.hooks.info("installed pi event extension at \(extensionURL.path, privacy: .public)")
            return .installed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static var extensionSource: String {
        """
        \(marker)
        const endpoint = "\(PassConfig.hookBaseURL)/hook/pi";

        function sessionId(ctx: any): string | undefined {
          return ctx.sessionManager?.getSessionFile?.();
        }

        function messageText(message: any): string | undefined {
          if (!message) return undefined;
          if (typeof message.content === "string") return message.content;
          if (!Array.isArray(message.content)) return undefined;
          const text = message.content
            .filter((part: any) => part?.type === "text" && typeof part.text === "string")
            .map((part: any) => part.text)
            .join("\\n");
          return text || undefined;
        }

        async function post(eventName: string, ctx: any, extra: Record<string, unknown> = {}) {
          const controller = new AbortController();
          const timer = setTimeout(() => controller.abort(), 1000);
          try {
            await fetch(endpoint, {
              method: "POST",
              headers: {
                "Content-Type": "application/json",
                "X-Pass-Session": process.env.PASS_SESSION ?? "",
              },
              body: JSON.stringify({
                hook_event_name: eventName,
                session_id: sessionId(ctx),
                cwd: ctx.cwd,
                ...extra,
              }),
              signal: controller.signal,
            });
          } catch {
            // Pass may not be running. Agent work must never fail because the bridge is offline.
          } finally {
            clearTimeout(timer);
          }
        }

        export default function (pi: any) {
          pi.on("session_start", async (_event: any, ctx: any) => {
            await post("SessionStart", ctx);
          });
          pi.on("input", async (_event: any, ctx: any) => {
            await post("UserPromptSubmit", ctx);
          });
          pi.on("agent_end", async (event: any, ctx: any) => {
            const assistant = [...(event.messages ?? [])]
              .reverse()
              .find((message: any) => message?.role === "assistant");
            await post("Stop", ctx, { last_assistant_message: messageText(assistant) });
          });
          pi.on("session_shutdown", async (_event: any, ctx: any) => {
            await post("SessionEnd", ctx);
          });
        }
        """
    }
}

private func readJSON(at url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return root
}

private func writeJSON(
    _ root: [String: Any],
    to url: URL
) -> AgentHooksInstaller.Status {
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
        Log.hooks.info("updated agent hooks in \(url.path, privacy: .public)")
        return .installed
    } catch {
        return .failed(error.localizedDescription)
    }
}

private func backupIfNeeded(_ url: URL) {
    let backup = url.appendingPathExtension("pass-backup")
    guard FileManager.default.fileExists(atPath: url.path),
          !FileManager.default.fileExists(atPath: backup.path) else { return }
    try? FileManager.default.copyItem(at: url, to: backup)
    Log.hooks.info("backed up \(url.lastPathComponent, privacy: .public)")
}
