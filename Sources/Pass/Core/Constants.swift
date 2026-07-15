import Foundation

/// App-wide constants. Values validated in spikes/FINDINGS.md.
enum PassConfig {
    /// Loopback port for the hook server. 8787 (plan default) collides with Docker on
    /// this machine; a high private-range port is stable and collision-unlikely.
    static let hookPort: UInt16 = 49817

    static var hookBaseURL: String { "http://127.0.0.1:\(hookPort)" }

    /// tmux session name prefix. All pass-managed sessions are `pass-<slug>`.
    static let sessionPrefix = "pass-"

    /// pass's own state directory (`~/.pass`). Extensions live under it; nothing inside it is
    /// ever a project/workspace. The single spelling — SessionStore and ExtensionStore both
    /// derive from here so the "never remember ~/.pass" guard can't drift from the layout.
    static var stateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pass", isDirectory: true)
    }

    /// tmux custom options used to persist project/agent binding across app restarts.
    static let optProjectRoot = "@pass_project_root"
    static let optAgent = "@pass_agent"

    /// Env var injected at session create so hooks can self-identify (X-Pass-Session header).
    static let sessionEnvVar = "PASS_SESSION"

    /// Reconcile poll interval (session list truth).
    static let reconcileInterval: TimeInterval = 2.0

    /// Delay between bracketed-paste and Enter so Ink processes the paste (FINDINGS.md §2).
    static let pasteToEnterDelayMs: UInt64 = 150

    /// How long to wait for a confirming UserPromptSubmit before flagging a reply "unconfirmed".
    static let replyConfirmTimeout: TimeInterval = 5.0
}
