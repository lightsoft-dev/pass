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

    /// Built-in command typed into a fresh session to launch the agent. The user can override
    /// this per agent in Settings (see `LaunchCommands`).
    var defaultLaunchCommand: String? {
        switch self {
        case .claude:  return "claude"
        case .codex:   return "codex"
        case .pi:      return "pi"
        case .shell, .generic: return nil
        }
    }

    /// Agents the user can start (and customize the launch command for). shell/generic are
    /// adopted, never launched.
    static var launchable: [AgentKind] { [.claude, .codex, .pi] }

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

/// How the home feed lays out sessions. Persisted in UserDefaults under "homeMode".
enum HomeMode: String, CaseIterable {
    case stack // one big focused card (embedded input) + small rows for the rest
    case list  // uniform compact rows, selected one highlighted, one input at the bottom

    var label: String {
        switch self {
        case .stack: return "Card stack"
        case .list:  return "Compact list"
        }
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
    /// While the session is actively producing output, the last meaningful line on screen —
    /// so the compact card shows what it's doing right now (not "no response yet").
    var liveTail: String?
    /// Fallback when there's no recorded `lastMessage` yet (e.g. first launch before any Stop
    /// hook fired): the last meaningful line(s) currently on the pane, so the card shows real
    /// content instead of "no response yet".
    var paneTail: String?
    /// The project's user-assigned emoji (shown at the front of the card), if any.
    var emoji: String?
    /// User-assigned display name (alias). Overrides the derived name everywhere in pass —
    /// never touches the folder or the tmux session name.
    var customName: String?
    /// A needs-you request (input/decision) arrived that the user hasn't checked yet. Keeps the
    /// highlighted border on until the user opens or acts on the session — even if the underlying
    /// attention state later changes (e.g. the agent moved on).
    var unacknowledged: Bool = false
    /// Optimistically-inserted placeholder shown the instant you create a session, before tmux
    /// and the first reconcile catch up. Cleared once reconcile picks up the real session.
    var launching: Bool = false

    /// The session is actively waiting on the user (a decision or input) — drives the
    /// highlighted "needs you" border. A finished FYI does not count.
    var needsUser: Bool {
        if case .pending(let a) = attention { return a.kind == .decision || a.kind == .input }
        return false
    }

    /// Human display: `repo [worktree-dir] · branch`, with the user's alias replacing only the
    /// repo part when set — the worktree/branch suffix always stays (e.g. "결제 서버 · main").
    var displayName: String {
        if let customName, !customName.isEmpty { return customName + gitSuffix }
        return defaultDisplayName
    }

    /// The derived (git/path-based) name, ignoring any alias — shown as secondary context when
    /// an alias is set, and as the rename field's placeholder.
    var defaultDisplayName: String {
        guard let git else { return URL(fileURLWithPath: cwd).lastPathComponent }
        return git.repoName + gitSuffix
    }

    /// The " ⧉ worktree · branch" tail appended after the repo name (or the alias).
    private var gitSuffix: String {
        guard let git else { return "" }
        var s = ""
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
    /// Optional user-assigned emoji shown at the front of this project's session cards.
    var emoji: String?
    var id: String { rootPath }
    var name: String { URL(fileURLWithPath: rootPath).lastPathComponent }
}
