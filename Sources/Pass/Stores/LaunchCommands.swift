import Foundation

/// User-customizable launch command per agent kind — e.g. `claude --dangerously-skip-permissions`.
/// Backed by UserDefaults; falls back to the agent's built-in default when unset.
enum LaunchCommands {
    private static func key(_ agent: AgentKind) -> String { "launchCommand.\(agent.rawValue)" }

    /// The command pass types into a fresh session for this agent: the user's override if set,
    /// else the built-in default (nil for shell/generic → launch nothing, leave a shell).
    static func command(for agent: AgentKind) -> String? {
        if let custom = UserDefaults.standard.string(forKey: key(agent)) {
            let trimmed = custom.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        return agent.defaultLaunchCommand
    }

    /// Store a per-agent override. Blank (or equal to the default) clears it — reverts to default.
    static func setCommand(_ command: String, for agent: AgentKind) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == (agent.defaultLaunchCommand ?? "") {
            UserDefaults.standard.removeObject(forKey: key(agent))
        } else {
            UserDefaults.standard.set(trimmed, forKey: key(agent))
        }
    }

    /// The current effective command as an editable string (for the settings field) — shows the
    /// default so the user edits from it rather than a blank box.
    static func editableCommand(for agent: AgentKind) -> String {
        command(for: agent) ?? ""
    }
}
