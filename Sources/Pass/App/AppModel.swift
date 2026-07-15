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

    /// Whether the panel is on screen. The home view attaches a live terminal to the selected
    /// session only while visible — hiding the panel detaches it (the session keeps running).
    var panelVisible: Bool = false

    /// Bumped by ⌘[ to step back from the session terminal to the inbox.
    var backToken: Int = 0
    func requestBack() { backToken &+= 1 }

    /// Set by CommandView on appear. Routes plain Up/Down/Return/Escape from
    /// SummonPanel.performKeyEquivalent — bypasses SwiftUI's onKeyPress, which can lose track
    /// of the focus chain after a mouse click moves real AppKit first-responder status.
    var keyHandler: ((PanelNavEvent) -> Bool)?

    /// Set to force the panel to open a specific session's terminal (used for testing).
    var forceOpenSession: String?

    /// Set by the menu bar: the next panel show should land on the spec documents screen.
    var pendingOpenSpecs = false

    /// Dev-server sessions started from a spec document, per project root. Runtime-only —
    /// a local tmux session name has no business inside the portable, committable document.
    private(set) var specPreviewSessions: [String: String] = [:]

    // Stores (composition root). Set in configure() on the main actor.
    private(set) var projects: ProjectStore!
    private(set) var sessions: SessionStore!
    private(set) var specs: SpecStore!

    weak var panelController: PanelController?

    /// Set by AppDelegate — clears a session's delivered notifications.
    var clearSessionNotifications: ((String) -> Void)?

    nonisolated init() {}

    /// Build the stores and start the reconcile loop. Called once from AppDelegate.
    func configure() {
        projects = ProjectStore()
        sessions = SessionStore(projects: projects)
        specs = SpecStore()
        sessions.start()
        isReady = true
    }

    /// Menu bar → open the spec documents screen (summons the panel if hidden).
    func showSpecs() {
        pendingOpenSpecs = true
        panelController?.show(preselecting: nil)
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

    // MARK: Spec documents (.pass/specs.json — one document per project, numbered specs)

    enum SpecAgentAction {
        case implement
        case verify
        case rework(feedback: String)
    }

    enum SpecActionResult: Equatable {
        case success(String) // session name working on it
        case failure(String)
    }

    /// The dev-server session started from this project's document, if it's still alive.
    func specPreviewSession(projectRoot: String) -> Session? {
        guard let name = specPreviewSessions[projectRoot] else { return nil }
        return sessions?.session(named: name)
    }

    /// Start the document's development command — only ever on an explicit click. The working
    /// directory is resolved by SpecStore and cannot escape the project root.
    func startSpecPreview(projectRoot: String) async -> SpecActionResult {
        specs.reload(projectRoot: projectRoot)
        guard let doc = specs.document(for: projectRoot) else {
            return .failure("Spec document not found.")
        }
        let command = doc.development.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .failure("Add a development command first.") }
        guard let cwd = specs.developmentWorkingDirectory(projectRoot: projectRoot) else {
            return .failure("Working directory must stay inside the project.")
        }
        if let existing = specPreviewSessions[projectRoot], sessions.session(named: existing) != nil {
            return .success(existing)
        }
        let name = await sessions.createCommandSession(projectDir: cwd, slug: "dev", command: command)
        specPreviewSessions[projectRoot] = name
        sessions.setAlias(name, "Dev · \(doc.title.isEmpty ? URL(fileURLWithPath: projectRoot).lastPathComponent : doc.title)")
        return .success(name)
    }

    func stopSpecPreview(projectRoot: String) {
        guard let name = specPreviewSessions.removeValue(forKey: projectRoot) else { return }
        killSession(name)
    }

    /// Hand a numbered spec to an agent. The JSON document is the contract: the agent reads
    /// `.pass/specs.json`, works on exactly that spec, and writes its resulting status back —
    /// so progress is visible in the document without scraping terminal prose.
    func runSpecAgent(projectRoot: String, number: Int, action: SpecAgentAction) async -> SpecActionResult {
        specs.reload(projectRoot: projectRoot)
        guard let doc = specs.document(for: projectRoot),
              let spec = doc.specs.first(where: { $0.number == number }) else {
            return .failure("Spec #\(number) not found.")
        }

        var feedback: String?
        var newStatus: SpecStatus = .implementing
        switch action {
        case .implement:
            newStatus = .implementing
        case .verify:
            newStatus = .verifying
        case .rework(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure("Describe what behaved incorrectly.") }
            newStatus = .implementing
            feedback = trimmed
        }

        // Reuse the spec's previous agent session while it's alive (context continuity).
        let sessionName: String
        var agent = AgentKind.claude
        if let existing = spec.agentSession,
           let live = sessions.session(named: existing), live.agent != .shell {
            sessionName = existing
            agent = live.agent
        } else {
            sessionName = await sessions.createSession(projectDir: projectRoot, agent: .claude)
        }

        do {
            try specs.updateSpec(projectRoot: projectRoot, number: number) { s in
                s.status = newStatus
                s.agentSession = sessionName
                if let feedback { s.feedback.append(SpecFeedback(text: feedback)) }
            }
        } catch {
            return .failure("Could not update the spec document: \(error.localizedDescription)")
        }

        let prompt = specAgentPrompt(document: doc, spec: spec, action: action, feedback: feedback)
        // A freshly-created tmux pane briefly reports the login shell while the agent boots.
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
        return .failure("The agent did not become ready — open the session and check its launch command.")
    }

    private func specAgentPrompt(document: SpecDocument, spec: Spec,
                                 action: SpecAgentAction, feedback: String?) -> String {
        let intent: String
        let doneStatus: String
        switch action {
        case .implement:
            intent = "Implement this spec completely."
            doneStatus = "needsReview"
        case .verify:
            intent = "Inspect the current implementation and verify this spec's behavior end-to-end. Fix only what the spec requires."
            doneStatus = "verified (or needsReview if anything is uncertain)"
        case .rework:
            intent = "A human review found incorrect behavior. Reproduce it, then revise the implementation."
            doneStatus = "needsReview"
        }

        let startedStatus = if case .verify = action { "verifying" } else { "implementing" }
        var lines = [
            "You are working from this project's executable spec document: .pass/specs.json",
            "",
            "Target: spec #\(spec.number) — \(spec.title)",
            "Its status has just been set to \"\(startedStatus)\".",
            "",
            intent,
        ]
        if !spec.detail.isEmpty {
            lines += ["", "Spec detail:", spec.detail]
        }
        if let feedback {
            lines += ["", "Latest human feedback:", feedback]
        }
        lines += [
            "",
            "Rules:",
            "- Treat .pass/specs.json as the contract; work on exactly spec #\(spec.number).",
            "- When you finish, edit .pass/specs.json: set that spec's \"status\" to \"\(doneStatus)\" and keep the JSON valid.",
            "- Never renumber, remove, or edit other specs.",
        ]
        return lines.joined(separator: "\n")
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
}
