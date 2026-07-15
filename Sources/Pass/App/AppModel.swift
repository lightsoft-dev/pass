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

    // Stores (composition root). Set in configure() on the main actor.
    private(set) var projects: ProjectStore!
    private(set) var sessions: SessionStore!

    weak var panelController: PanelController?

    /// Set by AppDelegate — clears a session's delivered notifications.
    var clearSessionNotifications: ((String) -> Void)?

    nonisolated init() {}

    /// Build the stores and start the reconcile loop. Called once from AppDelegate.
    func configure() {
        projects = ProjectStore()
        sessions = SessionStore(projects: projects)
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

    // MARK: Backup / export

    /// Transient result of the last export (shown in Settings): a short summary on success, or the
    /// error message on failure. Twin of `lastProjectAddMessage`.
    var lastExportMessage: String?

    /// True while an export runs — drives a spinner in Settings.
    var isExporting: Bool = false

    /// Export all registered projects (+ Pass settings) into a single .tar.gz the user picks.
    /// Heavy work runs off the main thread; result/error surface via `lastExportMessage`.
    func exportAllProjects(optimizeGit: Bool) {
        let all = projects?.projects ?? []
        guard !all.isEmpty else { lastExportMessage = "No projects to back up yet."; return }
        guard let dest = ProjectPicker.saveBackupPanel(defaultName: "pass-backup-\(Self.timestamp()).tar.gz") else { return }

        isExporting = true
        lastExportMessage = nil
        let options = ProjectExportService.Options(optimizeGitRepos: optimizeGit)
        Task { @MainActor in
            let result = await Self.runExport(projects: all, options: options, to: dest)
            isExporting = false
            switch result {
            case .success(let s):
                lastExportMessage = "Backed up \(s.total) project\(s.total == 1 ? "" : "s") · \(s.linkedByURL) linked, \(s.archived) archived · \(Self.humanBytes(s.bytes))"
                Log.app.info("export ok: \(s.total) projects, \(s.bytes) bytes -> \(dest.path, privacy: .public)")
            case .failure(let f):
                lastExportMessage = "Export failed: \(f.message)"
                Log.app.error("export failed: \(f.message, privacy: .public)")
            }
        }
    }

    /// Run the blocking export on a background queue.
    private static func runExport(projects: [Project], options: ProjectExportService.Options,
                                  to dest: URL) async -> Result<ProjectExportService.Summary, ProjectExportService.Failure> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: ProjectExportService.export(projects: projects, options: options, to: dest))
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: Date())
    }

    private static func humanBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
}
