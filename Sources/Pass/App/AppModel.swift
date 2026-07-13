import AppKit
import SwiftUI
import Observation

/// Composition root + shared observable state for the whole app.
@MainActor
@Observable
final class AppModel {
    /// Number of sessions that need the user (decision + input). Drives the menu-bar badge.
    var pendingCount: Int { sessions?.pendingCount ?? 0 }

    /// Non-nil when something is wrong the user must fix (tmux missing, port busy, hooks not installed).
    var setupProblem: String?

    /// True when Claude Code hooks aren't installed yet (offer a one-click install).
    var needsHookInstall: Bool = false

    /// True when the hook server failed to bind its port.
    var hookServerFailed: Bool = false

    /// True when macOS notification banners are blocked (denied). The menu-bar badge still
    /// works, but the user should enable notifications in System Settings for banners.
    var notificationsBlocked: Bool = false

    /// Set once services are wired, so views can react.
    var isReady: Bool = false

    /// When a notification is clicked, the session to preselect on next panel show.
    var pendingPreselect: String?

    /// Bumped by PanelController on every show so the omnibox re-takes focus (onAppear
    /// only fires once for a cached panel).
    var focusToken: Int = 0

    /// Bumped by ⌘[ to step back from the session terminal to the inbox.
    var backToken: Int = 0
    func requestBack() { backToken &+= 1 }

    /// Set by CommandView on appear. Routes plain Up/Down/Return/Escape from
    /// SummonPanel.performKeyEquivalent — bypasses SwiftUI's onKeyPress, which can lose track
    /// of the focus chain after a mouse click moves real AppKit first-responder status.
    var keyHandler: ((PanelNavEvent) -> Bool)?

    /// Set to force the panel to open a specific session's terminal (used for testing).
    var forceOpenSession: String?

    /// Local runtime sessions are intentionally not persisted into the portable feature file.
    /// The implementation agent session is a collaboration hint; a dev-server PID/session is not.
    private(set) var featurePreviewSessions: [String: String] = [:]

    // Stores (composition root). Set in configure() on the main actor.
    private(set) var projects: ProjectStore!
    private(set) var sessions: SessionStore!
    private(set) var features: FeatureStore!

    weak var panelController: PanelController?

    /// Set by AppDelegate — clears a session's delivered notifications.
    var clearSessionNotifications: ((String) -> Void)?

    nonisolated init() {}

    /// Build the stores and start the reconcile loop. Called once from AppDelegate.
    func configure() {
        projects = ProjectStore()
        sessions = SessionStore(projects: projects)
        features = FeatureStore()
        sessions.start()
        isReady = true
    }

    func summon() {
        panelController?.toggle()
    }

    func hidePanel() {
        panelController?.hide()
    }

    var panelFloating: Bool { panelController?.isFloating ?? true }
    func setPanelFloating(_ on: Bool) { panelController?.isFloating = on }
    func togglePanelFloating() { panelController?.toggleFloating() }

    // MARK: Session actions (called from the panel)

    func attach(_ session: Session) {
        AttachService.attach(session: session.name)
        hidePanel()
    }

    func createSession(projectDir: String, agent: AgentKind = .claude) {
        Task { await sessions?.createSession(projectDir: projectDir, agent: agent) }
    }

    /// Kill a session (ends its tmux session and the agent running in it). Destructive.
    func killSession(_ name: String) {
        Task { await sessions?.kill(name) }
    }

    /// Set (or clear, with empty) a session's custom display name. Only changes what pass
    /// shows — the folder and tmux session name are untouched.
    func renameSession(_ name: String, to alias: String) {
        sessions?.setAlias(name, alias)
    }

    /// Spin off a git worktree for a project (from a `+branch` message) and start a session in
    /// it. Returns nil on success, or a short error message for the caller to show.
    @discardableResult
    func createWorktreeSession(fromProjectRoot root: String, branch: String, agent: AgentKind) async -> String? {
        guard let sessions else { return "not ready" }
        return await sessions.createWorktreeSession(fromProjectRoot: root, branch: branch, agent: agent)
    }

    // MARK: Project registration

    /// Transient result of the last "Add projects…" action (shown in Settings).
    var lastProjectAddMessage: String?

    /// Register projects from picked folders. For each folder: if it's a git repo, register
    /// it; otherwise scan its immediate children and register every repo found. Handles
    /// single-project, parent-folder, and multi-select in one flow.
    func addProjects(dirs: [String]) {
        Task { @MainActor in
            var added = 0
            for dir in dirs {
                for root in await Self.resolveProjectRoots(under: dir) {
                    projects?.remember(rootPath: root)
                    added += 1
                }
            }
            lastProjectAddMessage = added == 0
                ? "No git repositories found there."
                : "Added \(added) project\(added == 1 ? "" : "s")."
            Log.app.info("addProjects: \(added) registered from \(dirs.count) folder(s)")
        }
    }

    private static func resolveProjectRoots(under dir: String) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                // The picked folder is itself a repo → register just it.
                if let id = GitIdentityService.identity(for: dir) {
                    cont.resume(returning: [id.projectRoot]); return
                }
                // Otherwise treat it as a parent and register each child repo.
                var roots: Set<String> = []
                let children = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
                for name in children where !name.hasPrefix(".") {
                    let child = (dir as NSString).appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue else { continue }
                    if let id = GitIdentityService.identity(for: child) { roots.insert(id.projectRoot) }
                }
                cont.resume(returning: Array(roots).sorted())
            }
        }
    }

    func installHooks() {
        let status = ClaudeHooksInstaller.install()
        needsHookInstall = !ClaudeHooksInstaller.isInstalled()
        Log.hooks.info("hook install requested -> \(String(describing: status), privacy: .public)")
    }

    /// Answer a pending permission decision for a session.
    func decide(_ name: String, _ decision: ReplyInjector.Decision) {
        guard let s = sessions?.session(named: name) else { return }
        Task { _ = await ReplyInjector.shared.sendDecision(name, agent: s.agent, decision) }
        sessions?.acknowledge(name)
    }

    /// Forward a navigation key (Up/Down/Enter) to a session's agent — lets you drive a decision
    /// menu shown in the mirror with the arrow keys, not just number picks.
    func sendMenuKey(_ name: String, _ key: String) {
        Task {
            let state = await TmuxClient.shared.paneState(name)
            if state.inMode { await TmuxClient.shared.cancelMode(name) } // leave copy-mode first
            await TmuxClient.shared.sendKeys(name, [key])
        }
        sessions?.acknowledge(name)
    }

    /// Pick a numbered option (permission dialog / AskUserQuestion) from the home card.
    func pickOption(_ name: String, _ number: Int) {
        guard let s = sessions?.session(named: name) else { return }
        Task { _ = await ReplyInjector.shared.pick(name, agent: s.agent, option: number) }
        sessions?.acknowledge(name)
        sessions?.applyAttention(name: name, .working) // optimistic; hook corrects
    }

    /// Send a text reply into a session from the home input (without opening the terminal).
    /// Returns the injection result so the UI can surface a shell-refusal.
    @discardableResult
    func reply(to name: String, text: String) async -> ReplyInjector.Result {
        guard let s = sessions?.session(named: name) else { return .error("no session") }
        let r = await ReplyInjector.shared.sendText(name, agent: s.agent, text: text)
        // optimistic: mark working, clear the pending item + the unacknowledged highlight
        sessions?.acknowledge(name)
        sessions?.applyAttention(name: name, .working)
        return r
    }

    /// When a session's detail is opened: clear a finished FYI, and auto-resolve a pending
    /// item the user already handled directly in a terminal ("already handled").
    func reconcileOnOpen(_ session: Session) {
        // Opening a session's detail counts as checking it — clear the persistent needs-you border.
        sessions?.acknowledge(session.name)
        switch session.attention {
        case .pending(let a) where a.kind == .finished:
            sessions?.applyAttention(name: session.name, .idle)
            clearSessionNotifications?(session.name)
        case .pending(let a) where a.kind == .decision:
            Task { [weak self] in
                let kind = await ReplyInjector.shared.classify(session.name, agent: session.agent)
                if kind != .permissionDialog {
                    self?.sessions?.applyAttention(name: session.name, .idle)
                    self?.clearSessionNotifications?(session.name)
                }
            }
        default:
            break
        }
    }

    // MARK: Executable feature documents

    enum FeatureAgentAction {
        case implement
        case verify
        case rework(feedback: String)
    }

    enum FeatureActionResult: Equatable {
        case success(String)
        case failure(String)
    }

    func previewSession(projectRoot: String, featureID: String) -> Session? {
        guard let name = featurePreviewSessions[featureRuntimeKey(projectRoot, featureID)] else { return nil }
        return sessions?.session(named: name)
    }

    /// Start the document's development command only after the user explicitly clicks Run.
    /// Working directories are resolved by FeatureStore and cannot escape the project root.
    func startFeaturePreview(projectRoot: String, featureID: String) async -> FeatureActionResult {
        features.reload(projectRoot: projectRoot)
        guard let document = features.document(projectRoot: projectRoot, id: featureID) else {
            return .failure("Feature document not found.")
        }
        let command = document.development.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .failure("Add a development command first.") }
        guard let cwd = features.developmentWorkingDirectory(for: document, projectRoot: projectRoot) else {
            return .failure("Working directory must stay inside the project.")
        }

        let key = featureRuntimeKey(projectRoot, featureID)
        if let existing = featurePreviewSessions[key], sessions.session(named: existing) != nil {
            return .success(existing)
        }
        let name = await sessions.createCommandSession(projectDir: cwd, featureID: featureID, command: command)
        featurePreviewSessions[key] = name
        sessions.setAlias(name, "Preview · \(document.title)")
        return .success(name)
    }

    func stopFeaturePreview(projectRoot: String, featureID: String) {
        let key = featureRuntimeKey(projectRoot, featureID)
        guard let name = featurePreviewSessions.removeValue(forKey: key) else { return }
        killSession(name)
    }

    func openFeatureURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return false }
        return NSWorkspace.shared.open(url)
    }

    func revealFeatureFile(projectRoot: String, featureID: String) {
        let url = features.fileURL(projectRoot: projectRoot, id: featureID)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Give an agent the JSON document as its contract. The same path is used for implementation,
    /// verification and human-requested rework, and the agent must write its evidence back into
    /// the document so status is visible without scraping prose from a terminal.
    func runFeatureAgent(
        projectRoot: String,
        featureID: String,
        action: FeatureAgentAction
    ) async -> FeatureActionResult {
        features.reload(projectRoot: projectRoot)
        guard var document = features.document(projectRoot: projectRoot, id: featureID) else {
            return .failure("Feature document not found.")
        }

        let feedback: String?
        switch action {
        case .implement:
            document.status = .implementing
            feedback = nil
        case .verify:
            document.status = .verifying
            feedback = nil
        case .rework(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure("Describe what behaved incorrectly.") }
            document.status = .implementing
            document.reviews.append(FeatureReview(feedback: trimmed))
            feedback = trimmed
        }

        var agent = document.implementation.preferredAgent
        if !AgentKind.launchable.contains(agent) { agent = .claude }
        let sessionName: String
        if let existing = document.implementation.agentSession,
           let live = sessions.session(named: existing), live.agent != .shell {
            sessionName = existing
            agent = live.agent
        } else {
            sessionName = await sessions.createSession(projectDir: projectRoot, agent: agent)
        }
        document.implementation.agentSession = sessionName

        do {
            try features.save(document, projectRoot: projectRoot)
        } catch {
            return .failure("Could not update feature status: \(error.localizedDescription)")
        }

        let prompt = featureAgentPrompt(document: document, projectRoot: projectRoot,
                                        action: action, feedback: feedback)
        // A freshly-created tmux pane briefly reports the login shell while the agent starts.
        // Retry only that safe refusal; any other delivery result is final.
        for _ in 0..<20 {
            let result = await ReplyInjector.shared.sendText(sessionName, agent: agent, text: prompt)
            switch result {
            case .delivered:
                sessions.applyAttention(name: sessionName, .working)
                return .success(sessionName)
            case .refusedShell:
                try? await Task.sleep(for: .milliseconds(250))
            case .error(let message):
                return .failure(message)
            }
        }
        return .failure("The agent did not become ready. Open the session and check its launch command.")
    }

    private func featureRuntimeKey(_ projectRoot: String, _ featureID: String) -> String {
        projectRoot + "\u{1f}" + featureID
    }

    private func featureAgentPrompt(document: FeatureDocument, projectRoot: String,
                                    action: FeatureAgentAction, feedback: String?) -> String {
        let relativePath = ".pass/features/\(document.id).json"
        let intent: String
        switch action {
        case .implement:
            intent = "Implement this feature completely."
        case .verify:
            intent = "Inspect the current implementation and verify every acceptance criterion. Fix only issues required by the document."
        case .rework:
            intent = "The human review found incorrect behavior. Reproduce it and revise the implementation."
        }

        var lines = [
            "Pass feature task: \(intent)",
            "Project root: \(projectRoot)",
            "Contract file: \(relativePath)",
            "",
            "Read the JSON contract before changing code. Work only inside this project and preserve the document id/schema.",
            "Implement the requirements, then verify every acceptance criterion and run the development.testCommand when present.",
            "Before finishing, update the same JSON file atomically:",
            "- set status to needsReview when the work is ready for a human, or blocked if you cannot proceed",
            "- write a concise implementation.summary",
            "- list every changed project-relative path in implementation.files",
            "- replace implementation.checks with one passed/failed/pending evidence record per criterion or command",
            "- never set status to verified; only the human reviewer may do that",
        ]
        if let feedback {
            lines += ["", "Human review feedback (treat as required reproduction evidence):", feedback]
        }
        return lines.joined(separator: "\n")
    }
}
