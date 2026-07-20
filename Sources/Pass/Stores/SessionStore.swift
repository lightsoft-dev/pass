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

    /// Sessions with a needs-you request the user hasn't checked yet. Set when an input/decision
    /// arrives; cleared only when the user opens or acts on the session (not by state changes).
    /// Drives the persistent highlighted border.
    private(set) var unacked: Set<String> = []

    /// User-assigned display names per session (display-only; folder/tmux names untouched).
    private(set) var aliasByName: [String: String] = [:]

    /// Called after every non-empty reconcile with the live session names — lets AppModel
    /// prune session-scoped state held by other stores (browser tabs/webviews) without this
    /// store knowing about them. Guarded on non-empty for the same transient-tmux-failure
    /// reason as the state pruning below.
    var onReconciled: ((Set<String>) -> Void)?
    /// Extension-runtime tap: sessions that appeared / vanished, reported once per reconcile.
    var onSessionsChanged: (@MainActor (_ created: [Session], _ ended: [String]) -> Void)?
    /// Remote control-plane tap. AppModel wires this to a debounced snapshot publisher so
    /// mobile clients see the same state transitions as the local UI without polling tmux.
    var onRemoteStateChanged: (@MainActor () -> Void)?
    /// High-frequency live response tap. Kept separate from snapshots so stream refreshes do not
    /// resend every session and project several times per second.
    var onRemoteStreamChanged: (@MainActor () -> Void)?
    /// Names seen by the previous reconcile. nil until the first pass — adopting sessions
    /// that were already running at launch must not fire "created" events.
    private var knownNames: Set<String>?
    /// Command sessions whose project must never enter the MRU (extension report sessions).
    /// The name-based tag is authoritative — the ~/.pass path heuristic alone can be escaped
    /// when git hoists the projectRoot (e.g. a dotfiles setup where $HOME itself is a repo).
    private var ephemeralSessions: Set<String> = []

    /// Descriptors for the CURRENT live launchable-agent sessions, mirrored to state.json so a
    /// session can be recreated after its tmux server dies. Rebuilt on every non-empty reconcile.
    private var sessionDescriptors: [String: SessionStatePersistence.SessionRef] = [:]
    /// Sessions persisted by the PREVIOUS run, consumed once at launch to restore any the
    /// (possibly restarted) tmux server no longer holds. Kept separate from `sessionDescriptors`
    /// so a reconcile can't prune it before `restoreOrphanedSessions()` runs.
    private var pendingRestore: [SessionStatePersistence.SessionRef] = []

    /// Opt-out for launch-time session restore (default on).
    static let restoreDefaultsKey = "restoreSessionsOnLaunch"

    private let tmux: TmuxClient
    private let projects: ProjectStore
    private var pollTask: Task<Void, Never>?
    private var remoteStreamTask: Task<Void, Never>?
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
            await restoreOrphanedSessions()   // bring back sessions lost to a tmux server restart
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

    func startRemoteStreaming() {
        remoteStreamTask?.cancel()
        remoteStreamTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshRemoteStreams()
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    func stopRemoteStreaming() {
        remoteStreamTask?.cancel()
        remoteStreamTask = nil
    }

    func stop() {
        pollTask?.cancel()
        stopRemoteStreaming()
    }

    // MARK: Restore (survive a tmux server death — reboot / kill-server)

    /// Recreate sessions the previous run had but the (restarted) tmux server no longer holds.
    /// Runs once, right after the first reconcile. tmux sessions can't be resurrected — their
    /// live process and scrollback are gone with the server — so this respawns a fresh session
    /// with the SAME name, project dir and agent; for Claude it launches `--continue`, resuming
    /// the last conversation in that directory. Skips anything whose dir has since disappeared,
    /// and honours the opt-out default.
    private func restoreOrphanedSessions() async {
        defer { pendingRestore = [] }   // consume once, whatever the outcome
        guard !pendingRestore.isEmpty else { return }
        guard UserDefaults.standard.object(forKey: Self.restoreDefaultsKey) as? Bool ?? true else { return }

        let live = Set(sessions.map(\.name))
        let fm = FileManager.default
        var restored = 0
        for ref in pendingRestore {
            guard !live.contains(ref.name) else { continue }             // still here — nothing to do
            guard let agent = AgentKind(rawValue: ref.agent),
                  AgentKind.launchable.contains(agent) else { continue } // only agents we can relaunch
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: ref.cwd, isDirectory: &isDir), isDir.boolValue else {
                Log.tmux.info("restore skipped \(ref.name, privacy: .public) — dir gone: \(ref.cwd, privacy: .public)")
                continue
            }
            guard !(await tmux.hasSession(ref.name)) else { continue }   // name already taken

            upsertLaunching(name: ref.name, projectRoot: ref.projectRoot, cwd: ref.cwd, agent: agent, git: nil)
            await tmux.newSession(name: ref.name, cwd: ref.cwd, projectRoot: ref.projectRoot,
                                  agent: agent, launchCommand: Self.resumeCommand(for: agent))
            projects.rememberIfNew(rootPath: ref.projectRoot)
            restored += 1
        }
        if restored > 0 {
            Log.tmux.info("restored \(restored, privacy: .public) session(s) after tmux server loss")
            await reconcile()
        }
    }

    /// How to relaunch an agent so it picks up where it left off. Claude resumes the directory's
    /// last conversation with `--continue`; other agents relaunch fresh (no reliable resume flag).
    /// Honours the user's per-agent launch-command override.
    private static func resumeCommand(for agent: AgentKind) -> String? {
        guard let base = LaunchCommands.command(for: agent) else { return nil }
        switch agent {
        case .claude:
            let hasContinue = base.contains("--continue")
                || base.range(of: #"(^|\s)-c(\s|$)"#, options: .regularExpression) != nil
            return hasContinue ? base : base + " --continue"
        default:
            return base
        }
    }

    // MARK: Reconcile

    func reconcile() async {
        let raw = await tmux.listSessions()
        // Snapshot BEFORE the pruning below drops dead ephemerals — the created/ended diff at
        // the end must still know a just-vanished report session was ephemeral.
        let ephemeralSnapshot = ephemeralSessions

        var next: [Session] = []
        var newDescriptors: [String: SessionStatePersistence.SessionRef] = [:]
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
            // Any live session's project is worth remembering (shows up in @ afterwards) —
            // except ephemeral command sessions and pass's own state directory (extension
            // report sessions run under ~/.pass, which is never a workspace).
            if isManaged, projectRoot != r.name,
               !ephemeralSessions.contains(r.name), !Self.isInternalRoot(projectRoot) {
                projects.rememberIfNew(rootPath: projectRoot)
                // Remember enough to respawn this session if the tmux server dies (agents only —
                // shell/generic have no launch command to restore).
                if AgentKind.launchable.contains(agent) {
                    newDescriptors[r.name] = .init(name: r.name, projectRoot: projectRoot,
                                                   cwd: r.cwd.isEmpty ? projectRoot : r.cwd,
                                                   agent: agent.rawValue)
                }
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
            session.unacknowledged = unacked.contains(r.name)
            session.customName = aliasByName[r.name]
            // Card preview always prefers Claude's transcript (the real last assistant message)
            // over terminal scraping — for live (streaming) sessions too, not just settled ones.
            // Fall back to pane scraping only for non-Claude agents / when no transcript is found.
            if isStreaming(session) {
                session.liveTail = await liveText(for: session)
            } else if session.lastMessage == nil || session.needsUser {
                // Waiting sessions refresh from the transcript too: the newest assistant text
                // is usually the QUESTION being asked — far more useful on the card than a
                // generic "Claude needs your input" hook preview or a stale last message.
                if let text = await lastAssistantText(cwd: r.cwd) {
                    session.paneTail = text
                } else {
                    let pane = await tmux.capturePane(r.name, colors: false)
                    session.paneTail = PaneSummary.lastAgentMessage(pane) ?? PaneSummary.lastContentLines(pane, max: 2)
                }
            }
            next.append(session)
        }

        // Drop attention / last messages for sessions that no longer exist — but NEVER on an
        // empty listing: a transient tmux failure (server starting up, socket briefly gone,
        // stale build mid-launch) is indistinguishable from "no sessions" and used to wipe
        // every persisted alias/message/pending state in one save.
        if !next.isEmpty {
            let liveNames = Set(next.map(\.name))
            let before = (attentionByName.count, lastMessageByName.count, unacked.count, aliasByName.count)
            attentionByName = attentionByName.filter { liveNames.contains($0.key) }
            lastMessageByName = lastMessageByName.filter { liveNames.contains($0.key) }
            unacked = unacked.intersection(liveNames)
            aliasByName = aliasByName.filter { liveNames.contains($0.key) }
            ephemeralSessions = ephemeralSessions.intersection(liveNames)
            // Descriptors track exactly the live launchable-agent sessions. Pruning here (rather
            // than on an empty listing) is deliberate: a session that vanished while others remain
            // really ended, but an all-gone listing is a transient/server-death case whose
            // descriptors we must KEEP so the next launch can restore them.
            let descriptorsChanged = sessionDescriptors != newDescriptors
            sessionDescriptors = newDescriptors
            if before != (attentionByName.count, lastMessageByName.count, unacked.count, aliasByName.count) || descriptorsChanged { scheduleSave() }
            onReconciled?(liveNames)
        }

        // Extension events: which sessions appeared / vanished this pass. The FIRST pass is a
        // baseline — even when empty, so the first session after a quiet launch still reports
        // as created (adopting sessions already running at launch is what must stay silent).
        // Afterwards, an empty listing may be a transient tmux failure (same rule as the
        // pruning above), so a kill that empties the list is reported from kill() instead.
        // Ephemeral report sessions are excluded entirely: a `session.created` rule with a
        // terminal action would otherwise re-trigger on its own report session, forever.
        if let known = knownNames {
            if !next.isEmpty {
                let names = Set(next.map(\.name)).subtracting(ephemeralSnapshot)
                let created = next.filter { !known.contains($0.name) && !ephemeralSnapshot.contains($0.name) }
                let ended = known.subtracting(names).sorted()
                if !created.isEmpty || !ended.isEmpty { onSessionsChanged?(created, ended) }
                knownNames = names
            }
        } else {
            knownNames = Set(next.map(\.name)).subtracting(ephemeralSnapshot)
        }

        // Sort: needs-you first, then most-recent activity.
        let sorted = next.sorted { a, b in
            let ap = a.attention.isPending, bp = b.attention.isPending
            if ap != bp { return ap }
            return a.lastActivity > b.lastActivity
        }
        let previousStreams = activeRemoteStreams(in: sessions)
        let changed = sessions != sorted
        sessions = sorted
        if changed { onRemoteStateChanged?() }
        if previousStreams != activeRemoteStreams(in: sorted) { onRemoteStreamChanged?() }
    }

    /// Is the session actively producing output right now? `.working` is the definitive signal
    /// (UserPromptSubmit fired, Stop hasn't); recent pane activity is the fallback when hooks
    /// aren't driving state. A session waiting on the user (`.pending`) is NOT streaming.
    private func isStreaming(_ s: Session) -> Bool {
        if case .working = s.attention { return true }
        if case .pending = s.attention { return false }
        return Date().timeIntervalSince(s.lastActivity) < 3
    }

    /// Refresh only active output between full tmux/git reconciles. This gives the remote UI a
    /// responsive stream without multiplying the expensive full-session polling work.
    private func refreshRemoteStreams() async {
        guard onRemoteStreamChanged != nil, !sessions.isEmpty else { return }

        let candidates = sessions.filter(isStreaming)
        var textByName: [String: String] = [:]
        for session in candidates {
            if let text = await liveText(for: session), !text.isEmpty {
                textByName[session.name] = text
            }
        }

        var changed = false
        for index in sessions.indices {
            let next = textByName[sessions[index].name]
            if sessions[index].liveTail != next {
                sessions[index].liveTail = next
                changed = true
            }
        }
        if changed { onRemoteStreamChanged?() }
    }

    private func liveText(for session: Session) async -> String? {
        let text: String?
        if session.agent == .claude,
           let transcript = await lastAssistantText(cwd: session.cwd),
           !transcript.isEmpty {
            text = transcript
        } else {
            text = PaneSummary.lastContentLine(
                await tmux.capturePane(session.name, colors: false)
            )
        }
        guard text != session.lastMessage else { return nil }
        return text
    }

    private func activeRemoteStreams(in sessions: [Session]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
            guard let text = session.liveTail, !text.isEmpty else { return nil }
            return (session.name, text)
        })
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

    /// Read a session's last assistant message from Claude Code's transcript, off the main actor
    /// (file I/O). nil for non-Claude agents / unknown cwd.
    private func lastAssistantText(cwd: String) async -> String? {
        guard !cwd.isEmpty else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: ClaudeTranscript.lastAssistantText(cwd: cwd))
            }
        }
    }

    // MARK: Lifecycle actions

    /// Create a new pass session for a project directory running the given agent. Inserts an
    /// optimistic "launching" placeholder card immediately (so there's instant feedback instead
    /// of waiting on tmux + a full reconcile), then swaps in the real session.
    /// `initialPrompt` (e.g. shared content from the OS share sheet) is passed to the agent as
    /// its CLI argument so it starts working on it right away.
    @discardableResult
    func createSession(projectDir: String, agent: AgentKind = .claude,
                       initialPrompt: String? = nil) async -> String {
        // 1. Instant placeholder — a card appears the moment you hit create.
        let dirRepo = URL(fileURLWithPath: projectDir).lastPathComponent
        let provisional = Slug.sessionName(repo: dirRepo, branch: nil)
        upsertLaunching(name: provisional, projectRoot: projectDir, cwd: projectDir, agent: agent, git: nil)

        // 2. Resolve identity + spawn the tmux session.
        let git = await resolveGit(projectDir)
        let repo = git?.repoName ?? dirRepo
        let branch = git?.isLinkedWorktree == true ? (git?.branch ?? git?.worktreeDirName) : nil
        var name = Slug.sessionName(repo: repo, branch: branch)
        name = await uniqueName(name)
        let projectRoot = git?.projectRoot ?? projectDir
        var launch = LaunchCommands.command(for: agent)
        if let base = launch,
           let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            launch = base + " " + Shell.singleQuoted(prompt) // e.g. claude '<shared content>'
        }
        await tmux.newSession(name: name, cwd: projectDir, projectRoot: projectRoot,
                              agent: agent, launchCommand: launch)
        projects.remember(rootPath: projectRoot)

        // 3. Swap the provisional card for the real one (name may differ once git/uniqueness resolve).
        if name != provisional { sessions.removeAll { $0.name == provisional } }
        upsertLaunching(name: name, projectRoot: projectRoot, cwd: projectDir, agent: agent, git: git)

        // 4. Finalize from tmux (clears `launching`, fills attention).
        await reconcile()
        return name
    }

    /// Start a project tool (normally the spec document's dev server) in a visible, durable
    /// tmux session. Unlike agent sessions, the document-provided command is launched directly
    /// and the session is tagged `.shell`, so pass never mistakes it for an agent that accepts
    /// replies (ReplyInjector refuses shells).
    /// `rememberProject: false` for sessions whose cwd is not a workspace (e.g. an extension's
    /// report script) — they must not pollute the project MRU.
    @discardableResult
    func createCommandSession(projectDir: String, slug: String, command: String,
                              rememberProject: Bool = true) async -> String {
        let git = await resolveGit(projectDir)
        let projectRoot = git?.projectRoot ?? projectDir
        let repo = git?.repoName ?? URL(fileURLWithPath: projectRoot).lastPathComponent
        let base = "\(PassConfig.sessionPrefix)\(Slug.make(repo))--\(Slug.make(slug))"
        let name = await uniqueName(base)

        if !rememberProject { ephemeralSessions.insert(name) } // before reconcile can see it
        upsertLaunching(name: name, projectRoot: projectRoot, cwd: projectDir, agent: .shell, git: git)
        await tmux.newSession(name: name, cwd: projectDir, projectRoot: projectRoot,
                              agent: .shell, launchCommand: command)
        if rememberProject { projects.remember(rootPath: projectRoot) }
        await reconcile()
        return name
    }

    /// Insert or refresh an optimistic launching placeholder in the live list.
    private func upsertLaunching(name: String, projectRoot: String, cwd: String, agent: AgentKind, git: GitIdentity?) {
        var s = Session(name: name, projectRoot: projectRoot, cwd: cwd, agent: agent, git: git,
                        lastActivity: Date(), isAttached: false)
        s.attention = .working
        s.launching = true
        s.emoji = projects.emoji(forRoot: projectRoot)
        s.customName = aliasByName[name]
        if let idx = sessions.firstIndex(where: { $0.name == name }) { sessions[idx] = s }
        else { sessions.append(s) }
        resort()
        onRemoteStateChanged?()
    }

    /// Create a git worktree off a project's main checkout, then start a session inside it.
    /// Triggered by a `+branch` message on the home card. Returns nil on success, or a short
    /// error message to surface (e.g. "not a git repo", a git failure).
    func createWorktreeSession(fromProjectRoot root: String, branch: String, agent: AgentKind) async -> String? {
        guard let mainRoot = (await resolveGit(root))?.projectRoot else { return "not a git repo" }
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<String, GitWorktreeService.Failure>, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: GitWorktreeService.addWorktree(mainRepoRoot: mainRoot, branch: branch))
            }
        }
        switch result {
        case .success(let path):
            await createSession(projectDir: path, agent: agent)
            return nil
        case .failure(let e):
            Log.tmux.error("worktree create failed: \(e.message, privacy: .public)")
            return e.message
        }
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
        // Optimistic removal — the row animates out immediately instead of after the reconcile.
        sessions.removeAll { $0.name == name }
        attentionByName[name] = nil
        unacked.remove(name)
        aliasByName.removeValue(forKey: name)
        // Forget the restore descriptor and persist now — a deliberate kill must not come back on
        // the next launch, and if this was the LAST session reconcile skips its save (empty list).
        if sessionDescriptors.removeValue(forKey: name) != nil { scheduleSave() }
        onRemoteStateChanged?()
        // Report the end explicitly: if this was the LAST session, reconcile sees an empty
        // listing and (deliberately, transient-failure rule) stays silent.
        if knownNames?.remove(name) != nil { onSessionsChanged?([], [name]) }
        await tmux.killSession(name)
        await reconcile()
    }

    // MARK: Attention (driven by EventRouter / hooks)

    /// Apply a new attention state to a session. Records it in `attentionByName` (so reconcile
    /// preserves it) and updates the in-memory session immediately for instant UI.
    func applyAttention(name: String, _ state: AttentionState) {
        attentionByName[name] = state
        // A fresh input/decision request marks the session unacknowledged (persistent highlight).
        // Other transitions (working/idle/finished) leave the flag alone — only the user clears it.
        if case .pending(let a) = state, a.kind == .decision || a.kind == .input {
            unacked.insert(name)
        }
        if let idx = sessions.firstIndex(where: { $0.name == name }) {
            sessions[idx].attention = state
            sessions[idx].unacknowledged = unacked.contains(name)
            resort()
        }
        scheduleSave()
        onRemoteStateChanged?()
    }

    /// Set (or clear, with empty/whitespace) a session's user-assigned display name.
    /// Display-only — the folder and tmux session name are untouched.
    func setAlias(_ name: String, _ alias: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { aliasByName.removeValue(forKey: name) }
        else { aliasByName[name] = trimmed }
        if let idx = sessions.firstIndex(where: { $0.name == name }) {
            sessions[idx].customName = trimmed.isEmpty ? nil : trimmed
        }
        scheduleSave()
        onRemoteStateChanged?()
    }

    /// The user checked (or acted on) a session — clear its persistent needs-you highlight.
    func acknowledge(_ name: String) {
        guard unacked.remove(name) != nil else { return }
        if let idx = sessions.firstIndex(where: { $0.name == name }) {
            sessions[idx].unacknowledged = false
        }
        scheduleSave()
        onRemoteStateChanged?()
    }

    /// Record a session's latest completed response.
    func setLastMessage(name: String, _ message: String) {
        guard !message.isEmpty else { return }
        lastMessageByName[name] = message
        if let idx = sessions.firstIndex(where: { $0.name == name }) {
            sessions[idx].lastMessage = message
        }
        scheduleSave()
        onRemoteStateChanged?()
    }

    // MARK: Persistence — the "needs you" queue + last responses survive app restarts.

    private func loadPersistedState() {
        let snap = SessionStatePersistence.load()
        lastMessageByName = snap.lastMessages
        unacked = Set(snap.unacked ?? [])
        aliasByName = snap.aliases ?? [:]
        pendingRestore = snap.sessions ?? []
        for (name, p) in snap.pending {
            guard let kind = Attention.Kind(rawValue: p.kind) else { continue }
            attentionByName[name] = .pending(Attention(kind: kind, receivedAt: p.receivedAt, preview: p.preview))
        }
    }

    /// Debounced write — coalesces bursts of hook events into one save.
    private func scheduleSave() {
        saveTask?.cancel()
        let attn = attentionByName, last = lastMessageByName
        let unack = unacked
        let aliases = aliasByName
        let descriptors = sessionDescriptors
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, self != nil else { return }
            // Load-modify-save: this store owns pending/lastMessages/unacked/aliases/sessions;
            // fields owned by other stores (browserURLs) must survive our writes.
            var snap = SessionStatePersistence.load()
            snap.pending = [:]
            snap.lastMessages = last
            snap.unacked = Array(unack)
            snap.aliases = aliases
            snap.sessions = Array(descriptors.values)
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

    /// pass's own state directory (`~/.pass/…`) is never a project/workspace.
    static func isInternalRoot(_ root: String) -> Bool {
        let state = PassConfig.stateDirectory.path
        return root == state || root.hasPrefix(state + "/")
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
