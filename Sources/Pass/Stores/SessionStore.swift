import Foundation
import Observation

/// Canonical live view of tmux sessions. tmux + git are the source of truth; this store
/// reconciles from them every couple of seconds and holds derived Session values.
/// Attention state is layered on top by the hook pipeline (M3); reconcile preserves it.
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [Session] = []
    private(set) var tmuxMissing = false

    /// Sessions that need the user right now (decision or input) — drives the badge.
    var pendingCount: Int {
        sessions.filter {
            if case .pending(let a) = $0.attention { return a.kind == .decision || a.kind == .input }
            return false
        }.count
    }

    /// Attention keyed by session name — owned by EventRouter (M3); reconcile reads it so
    /// liveness updates don't clobber "needs you" state. Empty in M1 → everything idle.
    var attentionByName: [String: AttentionState] = [:]

    /// Last completed response per session (from Stop's last_assistant_message). Persists so
    /// the home feed shows every session's last response regardless of current state.
    var lastMessageByName: [String: String] = [:]

    private let tmux: TmuxClient
    private let projects: ProjectStore
    private var pollTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(tmux: TmuxClient = .shared, projects: ProjectStore) {
        self.tmux = tmux
        self.projects = projects
        loadPersistedState()
    }

    func start() {
        Task {
            tmuxMissing = !(await tmux.isAvailable)
            await reconcile()
            // Headless test hook: PASS_DEBUG_CREATE=<dir> creates a session on launch.
            if let dir = ProcessInfo.processInfo.environment["PASS_DEBUG_CREATE"], !dir.isEmpty {
                let name = await createSession(projectDir: dir)
                Log.tmux.info("PASS_DEBUG_CREATE made session \(name, privacy: .public)")
            }
            // Headless test hook: PASS_DEBUG_INJECT=<session>|<text> injects a reply on launch.
            if let spec = ProcessInfo.processInfo.environment["PASS_DEBUG_INJECT"],
               let bar = spec.firstIndex(of: "|") {
                let name = String(spec[..<bar])
                let text = String(spec[spec.index(after: bar)...])
                let agent = sessions.first(where: { $0.name == name })?.agent ?? .claude
                let r = await ReplyInjector.shared.sendText(name, agent: agent, text: text)
                Log.inject.info("PASS_DEBUG_INJECT \(name, privacy: .public) -> \(String(describing: r), privacy: .public)")
            }
        }
        startPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reconcile()
                try? await Task.sleep(for: .seconds(PassConfig.reconcileInterval))
            }
        }
    }

    func stop() { pollTask?.cancel() }

    // MARK: Reconcile

    func reconcile() async {
        let raw = await tmux.listSessions()

        var next: [Session] = []
        for r in raw {
            // Only manage pass-* sessions (tag/adopt). Non-pass sessions are shown read-only.
            let isManaged = r.name.hasPrefix(PassConfig.sessionPrefix)

            let git = await resolveGit(r.cwd)
            let agent = agentKind(for: r)
            let projectRoot = r.projectRootOption
                ?? git?.projectRoot
                ?? (r.cwd.isEmpty ? r.name : r.cwd)

            // Adopt: a pass-* session missing our tag → write it back so identity persists.
            if isManaged && r.projectRootOption == nil && !r.cwd.isEmpty {
                await tmux.adoptTag(name: r.name, projectRoot: projectRoot, agent: agent)
            }
            // Any live session's project is worth remembering (shows up in @ afterwards).
            if isManaged, projectRoot != r.name {
                projects.rememberIfNew(rootPath: projectRoot)
            }

            var session = Session(
                name: r.name,
                projectRoot: projectRoot,
                cwd: r.cwd,
                agent: agent,
                git: git,
                lastActivity: r.activity,
                isAttached: r.attached
            )
            session.attention = attentionByName[r.name] ?? .idle
            session.lastMessage = lastMessageByName[r.name]
            session.emoji = projects.emoji(forRoot: projectRoot)
            // Streaming sessions: scrape the current last line so the card shows live activity.
            if isStreaming(session) {
                session.liveTail = PaneSummary.lastContentLine(await tmux.capturePane(r.name, colors: false))
            }
            next.append(session)
        }

        // Drop attention / last messages for sessions that no longer exist.
        let liveNames = Set(next.map(\.name))
        let before = (attentionByName.count, lastMessageByName.count)
        attentionByName = attentionByName.filter { liveNames.contains($0.key) }
        lastMessageByName = lastMessageByName.filter { liveNames.contains($0.key) }
        if before != (attentionByName.count, lastMessageByName.count) { scheduleSave() }

        // Sort: needs-you first, then most-recent activity.
        sessions = next.sorted { a, b in
            let ap = a.attention.isPending, bp = b.attention.isPending
            if ap != bp { return ap }
            return a.lastActivity > b.lastActivity
        }
    }

    /// Is the session actively producing output right now? `.working` is the definitive signal
    /// (UserPromptSubmit fired, Stop hasn't); recent pane activity is the fallback when hooks
    /// aren't driving state. A session waiting on the user (`.pending`) is NOT streaming.
    private func isStreaming(_ s: Session) -> Bool {
        if case .working = s.attention { return true }
        if case .pending = s.attention { return false }
        return Date().timeIntervalSince(s.lastActivity) < 3
    }

    private func agentKind(for r: RawSession) -> AgentKind {
        if let opt = r.agentOption, let k = AgentKind(rawValue: opt) { return k }
        return AgentKind.infer(fromPaneCommand: r.paneCommand)
    }

    private func resolveGit(_ cwd: String) async -> GitIdentity? {
        guard !cwd.isEmpty else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: GitIdentityService.identity(for: cwd))
            }
        }
    }

    // MARK: Lifecycle actions

    /// Create a new pass session for a project directory running the given agent.
    @discardableResult
    func createSession(projectDir: String, agent: AgentKind = .claude) async -> String {
        let git = await resolveGit(projectDir)
        let repo = git?.repoName ?? URL(fileURLWithPath: projectDir).lastPathComponent
        let branch = git?.isLinkedWorktree == true ? (git?.branch ?? git?.worktreeDirName) : nil
        var name = Slug.sessionName(repo: repo, branch: branch)
        name = await uniqueName(name)

        let projectRoot = git?.projectRoot ?? projectDir
        await tmux.newSession(name: name, cwd: projectDir, projectRoot: projectRoot, agent: agent)
        projects.remember(rootPath: projectRoot)
        await reconcile()
        return name
    }

    private func uniqueName(_ base: String) async -> String {
        var name = base
        var n = 2
        while await tmux.hasSession(name) {
            name = "\(base)-\(n)"
            n += 1
        }
        return name
    }

    func kill(_ name: String) async {
        await tmux.killSession(name)
        attentionByName[name] = nil
        await reconcile()
    }

    // MARK: Attention (driven by EventRouter / hooks)

    /// Apply a new attention state to a session. Records it in `attentionByName` (so reconcile
    /// preserves it) and updates the in-memory session immediately for instant UI.
    func applyAttention(name: String, _ state: AttentionState) {
        attentionByName[name] = state
        if let idx = sessions.firstIndex(where: { $0.name == name }) {
            sessions[idx].attention = state
            resort()
        }
        scheduleSave()
    }

    /// Record a session's latest completed response.
    func setLastMessage(name: String, _ message: String) {
        guard !message.isEmpty else { return }
        lastMessageByName[name] = message
        if let idx = sessions.firstIndex(where: { $0.name == name }) {
            sessions[idx].lastMessage = message
        }
        scheduleSave()
    }

    // MARK: Persistence — the "needs you" queue + last responses survive app restarts.

    private func loadPersistedState() {
        let snap = SessionStatePersistence.load()
        lastMessageByName = snap.lastMessages
        for (name, p) in snap.pending {
            guard let kind = Attention.Kind(rawValue: p.kind) else { continue }
            attentionByName[name] = .pending(Attention(kind: kind, receivedAt: p.receivedAt, preview: p.preview))
        }
    }

    /// Debounced write — coalesces bursts of hook events into one save.
    private func scheduleSave() {
        saveTask?.cancel()
        let attn = attentionByName, last = lastMessageByName
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, self != nil else { return }
            var snap = SessionStatePersistence.Snapshot(pending: [:], lastMessages: last)
            for (name, state) in attn {
                if case .pending(let a) = state {
                    snap.pending[name] = .init(kind: a.kind.rawValue, receivedAt: a.receivedAt, preview: a.preview)
                }
            }
            SessionStatePersistence.save(snap)
        }
    }

    /// Resolve a hook event to a session name: trust the header hint (it's our env var),
    /// else a unique cwd match, else nil (never mis-route).
    func resolveSessionName(hint: String?, cwd: String?) -> String? {
        if let hint, !hint.isEmpty { return hint }
        guard let cwd, !cwd.isEmpty else { return nil }
        let matches = sessions.filter { $0.cwd == cwd }
        return matches.count == 1 ? matches[0].name : nil
    }

    func session(named name: String) -> Session? {
        sessions.first { $0.name == name }
    }

    private func resort() {
        sessions.sort { a, b in
            let ap = a.attention.isPending, bp = b.attention.isPending
            if ap != bp { return ap }
            return a.lastActivity > b.lastActivity
        }
    }
}

extension AttentionState {
    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}
