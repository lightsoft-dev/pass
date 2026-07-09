import Foundation

/// Which coding agent runs in a session. Multi-agent is a first-class assumption:
/// only ClaudeAdapter is wired in the MVP, but the model carries the kind everywhere.
enum AgentKind: String, Codable, Hashable, CaseIterable {
    case claude
    case codex
    case pi
    case shell   // no agent — a plain shell (claude exited, or a manual session)
    case generic // unknown agent

    /// Glyph shown in inbox/palette rows so "which agent" reads at a glance.
    var glyph: String {
        switch self {
        case .claude:  return "✳"
        case .codex:   return "⬢"
        case .pi:      return "π"
        case .shell:   return "$"
        case .generic: return "•"
        }
    }

    /// Command typed into a fresh session to launch the agent.
    var launchCommand: String? {
        switch self {
        case .claude:  return "claude"
        case .codex:   return "codex"
        case .pi:      return "pi"
        case .shell, .generic: return nil
        }
    }

    /// Best-effort mapping from a pane's foreground command to an agent kind.
    /// (`claude.exe` is what Claude Code reports as `pane_current_command`.)
    static func infer(fromPaneCommand cmd: String) -> AgentKind {
        let c = cmd.lowercased()
        if c.hasPrefix("claude") { return .claude }
        if c.hasPrefix("codex") { return .codex }
        if c == "pi" { return .pi }
        if ["zsh", "bash", "fish", "sh", "-zsh", "-bash"].contains(c) { return .shell }
        return .generic
    }
}

/// Git identity of a session's working directory. Parsed live via `git` — never stored.
struct GitIdentity: Hashable, Sendable {
    var root: String            // worktree root (absolute)
    var branch: String?         // nil when detached
    var detachedSha: String?    // short sha when detached
    var isLinkedWorktree: Bool
    var mainRepoRoot: String?   // the primary checkout; worktrees group under this
    var worktreeDirName: String?

    /// The project this session belongs to — worktrees group under the main checkout.
    var projectRoot: String { mainRepoRoot ?? root }

    var repoName: String { URL(fileURLWithPath: projectRoot).lastPathComponent }
}

/// What a session needs from the user. Scalar by design → at most one inbox item per
/// session, so duplicates are impossible. Hook-driven (M3); reconcile leaves it .idle.
enum AttentionState: Hashable, Sendable {
    case working
    case idle
    case pending(Attention)
}

struct Attention: Hashable, Sendable {
    enum Kind: String, Sendable {
        case decision // Notification: permission_prompt
        case input    // Notification: idle_prompt | agent_needs_input | elicitation_dialog
        case finished // Stop
    }
    var kind: Kind
    var receivedAt: Date
    var preview: String
}

/// A live tmux session pass tracks. Derived from tmux + git — never persisted by the app.
struct Session: Identifiable, Hashable, Sendable {
    var name: String            // tmux session name == id, e.g. "pass-myrepo--feat-x"
    var id: String { name }
    var projectRoot: String     // from @pass_project_root, else git/cwd
    var cwd: String
    var agent: AgentKind
    var git: GitIdentity?
    var attention: AttentionState = .idle
    var lastActivity: Date
    var isAttached: Bool
    /// The agent's most recent completed response (from the last Stop). Persists across state
    /// changes so the home feed always shows each session's last response.
    var lastMessage: String?

    /// Human display: `repo [worktree-dir] · branch`, worktree badge distinct.
    var displayName: String {
        guard let git else { return URL(fileURLWithPath: cwd).lastPathComponent }
        var s = git.repoName
        if git.isLinkedWorktree, let wt = git.worktreeDirName { s += " ⧉ \(wt)" }
        if let branch = git.branch { s += " · \(branch)" }
        else if let sha = git.detachedSha { s += " · \(sha) (detached)" }
        return s
    }
}

/// A registered project (MRU list persisted to projects.json). Identity = root path;
/// name is just the directory name.
struct Project: Identifiable, Codable, Hashable, Sendable {
    var rootPath: String
    var id: String { rootPath }
    var name: String { URL(fileURLWithPath: rootPath).lastPathComponent }
}
