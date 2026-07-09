import Foundation

/// Per-agent interaction knowledge used by ReplyInjector. Only Claude is populated in the
/// MVP; other agents get a profile in M5. Values validated in spikes/FINDINGS.md.
struct InteractionProfile: Sendable {
    /// send-keys sequences for a permission prompt (single keypress, no Enter).
    var approveOnce: [String]
    var approveAll: [String]
    var deny: [String]
    /// Delay between bracketed paste and Enter so the TUI processes the paste.
    var pasteToEnterDelayMs: UInt64
    /// True if the visible pane tail is a permission dialog (text input not accepted).
    var isPermissionDialog: @Sendable (String) -> Bool

    static let claude = InteractionProfile(
        approveOnce: ["1"],
        approveAll: ["2"],
        deny: ["3"],
        pasteToEnterDelayMs: PassConfig.pasteToEnterDelayMs,
        isPermissionDialog: { tail in
            // e.g. "Do you want to create X?  ❯ 1. Yes  2. …  3. No  Esc to cancel"
            tail.contains("❯ 1.") && (tail.contains("Do you want") || tail.contains("Esc to cancel"))
        }
    )

    static func `for`(_ agent: AgentKind) -> InteractionProfile {
        switch agent {
        case .claude: return .claude
        // Codex/pi/etc. get real profiles in M5; fall back to Claude's shape for now.
        default: return .claude
        }
    }
}

/// The single choke point for sending anything into a session's pane. Every injection
/// runs precheck → deliver → (caller does post-confirm via hooks). Refuses to type into a
/// bare shell (that would run arbitrary commands).
actor ReplyInjector {
    static let shared = ReplyInjector()
    private let tmux: TmuxClient

    init(tmux: TmuxClient = .shared) { self.tmux = tmux }

    enum PaneKind: Sendable { case agentReady, permissionDialog, shell, copyMode }

    enum Result: Sendable, Equatable {
        case delivered
        case refusedShell        // agent not running — would type into a shell
        case error(String)
    }

    /// Classify the pane before acting.
    func classify(_ session: String, agent: AgentKind) async -> PaneKind {
        let state = await tmux.paneState(session)
        if state.inMode { return .copyMode }
        if AgentKind.infer(fromPaneCommand: state.command) == .shell { return .shell }
        let tail = await captureTail(session)
        if InteractionProfile.for(agent).isPermissionDialog(tail) { return .permissionDialog }
        return .agentReady
    }

    /// Send free-text into the agent's input box. Bracketed paste + delay + Enter.
    /// Returns `.refusedShell` when the agent isn't running (safety).
    func sendText(_ session: String, agent: AgentKind, text: String, allowShell: Bool = false) async -> Result {
        let profile = InteractionProfile.for(agent)
        let kind = await classify(session, agent: agent)
        switch kind {
        case .copyMode:
            await tmux.cancelMode(session) // then fall through by re-injecting as agentReady
        case .shell where !allowShell:
            return .refusedShell
        default:
            break
        }
        await tmux.setBuffer(text)
        await tmux.pasteBuffer(into: session)
        try? await Task.sleep(nanoseconds: profile.pasteToEnterDelayMs * 1_000_000)
        await tmux.sendKeys(session, ["Enter"])
        Log.inject.info("sent text to \(session, privacy: .public) (\(text.count) chars)")
        return .delivered
    }

    /// Answer a permission prompt. `.allowOnce` / `.allowAll` / `.deny`.
    enum Decision: Sendable { case allowOnce, allowAll, deny }

    func sendDecision(_ session: String, agent: AgentKind, _ decision: Decision) async -> Result {
        let profile = InteractionProfile.for(agent)
        let keys: [String]
        switch decision {
        case .allowOnce: keys = profile.approveOnce
        case .allowAll:  keys = profile.approveAll
        case .deny:      keys = profile.deny
        }
        await tmux.sendKeys(session, keys)
        Log.inject.info("sent decision \(String(describing: decision), privacy: .public) to \(session, privacy: .public)")
        return .delivered
    }

    /// Pick a numbered option from a menu (permission dialog / AskUserQuestion). A bare digit
    /// selects+confirms the highlighted-by-number choice (FINDINGS.md §2). Refuses a bare shell.
    func pick(_ session: String, agent: AgentKind, option: Int) async -> Result {
        guard await classify(session, agent: agent) != .shell else { return .refusedShell }
        await tmux.sendKeys(session, [String(option)])
        Log.inject.info("picked option \(option) in \(session, privacy: .public)")
        return .delivered
    }

    private func captureTail(_ session: String, lines: Int = 12) async -> String {
        let full = await tmux.capturePane(session, colors: false)
        let all = full.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(lines).joined(separator: "\n")
    }
}
