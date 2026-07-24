import AppKit
import SwiftUI
import Observation

enum AgentHookPromptPreference {
    static let dismissedKey = "agentHooks.installPromptDismissed.v1"
}

/// Composition root + shared observable state for the whole app.
@MainActor
@Observable
final class AppModel {
    /// Number of sessions that need the user (decision + input). Drives the menu-bar badge.
    var pendingCount: Int { sessions?.pendingCount ?? 0 }

    /// Non-nil when something is wrong the user must fix (tmux missing, port busy, hooks not installed).
    var setupProblem: String?

    /// True when one or more supported agent integrations aren't installed yet.
    var needsHookInstall: Bool = false

    /// The warning may be acknowledged without installing. Settings still exposes the
    /// integration status and installer after the home banner is dismissed.
    var hookInstallPromptDismissed =
        UserDefaults.standard.bool(forKey: AgentHookPromptPreference.dismissedKey)

    /// True when the hook server failed to bind its port.
    var hookServerFailed: Bool = false

    /// True when macOS notification banners are blocked (denied). The menu-bar badge still
    /// works, but the user should enable notifications in System Settings for banners.
    var notificationsBlocked: Bool = false

    /// Set once services are wired, so views can react.
    var isReady: Bool = false
    /// Bumped when a project-local pass-config.json changes so views re-read shared settings.
    var configRevision: Int = 0

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

    /// AppDelegate wires this to the reusable first-run window.
    var showOnboardingHandler: (() -> Void)?

    /// Set to force the panel to open a specific session's terminal (used for testing).
    var forceOpenSession: String?

    /// Set by the menu bar: the next panel show should land on the spec documents screen.
    var pendingOpenSpecs = false

    /// Set by the native titlebar control: the panel should show feature documents.
    var pendingOpenFeatures = false

    /// Dev-server sessions started from a spec document, per project root. Runtime-only —
    /// a local tmux session name has no business inside the portable, committable document.
    private(set) var specPreviewSessions: [String: String] = [:]

    /// Bumped to move keyboard focus into the visible browser's address field (⌘L).
    var browserFocusToken: Int = 0
    /// Prevents two simultaneously mounted session workspaces from both claiming the one-time
    /// Chrome import prompt before UserDefaults observation propagates through SwiftUI.
    @ObservationIgnored private var browserProfilePromptClaimed = false

    /// The session whose workspace (terminal │ browser) is on screen right now — the home
    /// selection or the open detail view. A CLI browser open targeting it may show
    /// immediately; any other target only gets the 🌐 badge (never steal the selection).
    var focusedSessionName: String?

    /// Local runtime sessions are intentionally not persisted into the portable feature file.
    /// The implementation agent session is a collaboration hint; a dev-server PID/session is not.
    private(set) var featurePreviewSessions: [String: String] = [:]

    // Stores (composition root). Set in configure() on the main actor.
    private(set) var projects: ProjectStore!
    private(set) var sessions: SessionStore!
    private(set) var specs: SpecStore!
    private(set) var features: FeatureStore!
    private(set) var browser: BrowserStore!
    private(set) var mirror: MirrorEngine!
    private(set) var miniTerminals: MiniTerminalManager!
    private(set) var webViews: WebViewPool!
    private(set) var extensions: ExtensionStore!
    private(set) var extensionRuntime: ExtensionRuntime!
    private(set) var extensionWindows: ExtensionWindowManager!
    private(set) var extensionBuilder: ExtensionBuilder!
    private(set) var extensionMarketplace: ExtensionMarketplaceService!

    /// Outbound-only mobile control plane. The gateway is disabled unless its feature flag is
    /// enabled, so normal desktop launches never make a relay connection.
    private(set) var remoteGatewayState: RemoteGatewayState = .stopped
    private(set) var remoteDesktopID: String = ""
    private(set) var remotePublicAccessAvailable = false
    private(set) var remoteUsesPublicCredentials = false
    private(set) var remoteAccountState: RemoteAccountState = .unavailable
    private(set) var remotePublicPairingPayload: String?
    @ObservationIgnored private var remoteGateway: RemoteGateway?
    @ObservationIgnored private var remoteSnapshotHook: RemoteSnapshotPublicationHook?
    @ObservationIgnored private var remoteTerminalCoordinator: RemoteTerminalCoordinator?
    @ObservationIgnored private var remoteGatewayGeneration = 0
    @ObservationIgnored private var remoteGatewayRestartTask: Task<Void, Never>?
    @ObservationIgnored private var remoteCredentialRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var remotePairingExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var projectSyncLoopTask: Task<Void, Never>?
    @ObservationIgnored private var remoteAccountService: RemoteAccountService!

    weak var panelController: PanelController?
    /// Set by AppDelegate — clears a session's delivered notifications.
    var clearSessionNotifications: ((String) -> Void)?
    /// Set by AppDelegate — applies the selected global summon shortcut immediately.
    @ObservationIgnored var summonShortcutModeChanged: ((SummonShortcutMode) -> Void)?

    nonisolated init() {}

    /// Build the stores and start the reconcile loop. Called once from AppDelegate.
    func configure() {
        remoteAccountService = RemoteAccountService()
        extensionMarketplace = ExtensionMarketplaceService(accountService: remoteAccountService)
        refreshRemoteAccountState()
        projects = ProjectStore()
        sessions = SessionStore(projects: projects)
        specs = SpecStore()
        features = FeatureStore()
        browser = BrowserStore()
        mirror = MirrorEngine()
        miniTerminals = MiniTerminalManager()
        webViews = WebViewPool()
        webViews.store = browser
        // Tabs are data (BrowserStore); webviews are the pool — keep them in lockstep.
        browser.onTabOpened = { [weak self] tab in self?.webViews?.load(tab) }
        browser.onTabClosed = { [weak self] id in self?.webViews?.drop(id) }
        // Session died → its tab/webview go with it (same lifecycle as the terminal pool).
        sessions.onReconciled = { [weak self] live in
            self?.browser?.pruneSessions(alive: live)
            self?.mirror?.pruneSessions(alive: live)
        }
        extensions = ExtensionStore()
        extensionWindows = ExtensionWindowManager(store: extensions)
        extensionRuntime = ExtensionRuntime(store: extensions, windows: extensionWindows, appModel: self)
        extensionBuilder = ExtensionBuilder(store: extensions, sessions: sessions)
        extensionWindows.runtime = extensionRuntime
        extensions.onReload = { [weak self] in self?.extensionWindows?.closeAll() }
        extensions.onDisabled = { [weak self] id in self?.extensionWindows?.close(extensionId: id) }
        sessions.onSessionsChanged = { [weak self] created, ended in
            guard let self else { return }
            self.extensionRuntime?.sessionsCreated(
                created.filter { !self.extensionBuilder.ownsSession($0.name) })
            self.extensionRuntime?.sessionsEnded(
                ended.filter { !self.extensionBuilder.ownsSession($0) })
        }
        sessions.onSessionInventory = { [weak self] liveNames in
            self?.extensions?.reconcileTerminalExecutions(liveSessionNames: liveNames)
        }
        sessions.start()
        isReady = true
        installRemoteGateway()
        syncProjectDirectories(automatic: true)
        projectSyncLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                self.syncProjectDirectories(automatic: true)
            }
        }
    }

    /// Re-read the feature configuration and replace the outbound relay connection. Settings
    /// calls this explicitly after persisting edits so typing in a URL never churns sockets.
    func reconfigureRemoteGateway() {
        let previous = remoteGateway
        let previousTerminalCoordinator = remoteTerminalCoordinator
        remoteGatewayGeneration &+= 1
        remoteGatewayRestartTask?.cancel()
        sessions?.stopRemoteStreaming()
        sessions?.onRemoteStateChanged = nil
        sessions?.onRemoteStreamChanged = nil
        projects?.onRemoteStateChanged = nil
        remoteGateway = nil
        remoteSnapshotHook = nil
        remoteTerminalCoordinator = nil
        remoteGatewayState = .stopped

        remoteGatewayRestartTask = Task { [weak self] in
            await previousTerminalCoordinator?.stop()
            await previous?.stop()
            guard !Task.isCancelled, let self else { return }
            self.installRemoteGateway()
        }
    }

    private func installRemoteGateway(configuration: RemoteGatewayConfiguration = .loadSecure()) {
        remoteGatewayGeneration &+= 1
        let generation = remoteGatewayGeneration
        remoteDesktopID = configuration.desktopID
        let backend = AppRemoteCommandBackend(appModel: self)
        let handler = RemoteCommandHandler(backend: backend)
        let gateway = RemoteGateway(
            configuration: configuration,
            handler: handler,
            stateObserver: { [weak self] state in
                guard let self, self.remoteGatewayGeneration == generation else { return }
                self.remoteGatewayState = state
            }
        )
        let snapshotHook = RemoteSnapshotPublicationHook(publisher: gateway)
        remoteGateway = gateway
        remoteSnapshotHook = snapshotHook
        remoteTerminalCoordinator = RemoteTerminalCoordinator { [weak gateway] snapshot in
            await gateway?.publishTerminalSnapshot(snapshot)
        }
        sessions?.onRemoteStateChanged = { [weak snapshotHook] in snapshotHook?.schedule() }
        sessions?.onRemoteStreamChanged = { [weak self] in
            guard let sessions = self?.sessions?.sessions else { return }
            let sources = sessions.map(RemoteMessageStreamSource.init)
            Task { await gateway.publishMessageStreams(sources) }
        }
        projects?.onRemoteStateChanged = { [weak snapshotHook] in snapshotHook?.schedule() }
        scheduleRemoteCredentialRefresh()
        if configuration.isEnabled {
            sessions?.startRemoteStreaming()
            sessions?.onRemoteStreamChanged?()
        } else {
            sessions?.stopRemoteStreaming()
        }
        Task { await gateway.start() }
    }

    func openRemoteTerminal(
        _ command: RemoteSessionTerminalOpenCommand
    ) async -> RemoteSessionTerminalSnapshot? {
        guard let remoteTerminalCoordinator else { return nil }
        return await remoteTerminalCoordinator.open(
            session: command.session,
            subscriptionID: command.subscriptionID,
            previousRevision: command.previousRevision
        )
    }

    func sendRemoteTerminalInput(_ command: RemoteSessionTerminalInputCommand) async -> Bool {
        guard let remoteTerminalCoordinator else { return false }
        return await remoteTerminalCoordinator.sendInput(
            session: command.session,
            subscriptionID: command.subscriptionID,
            input: command.input
        )
    }

    func closeRemoteTerminal(_ command: RemoteSessionTerminalCloseCommand) async {
        await remoteTerminalCoordinator?.close(
            session: command.session,
            subscriptionID: command.subscriptionID
        )
    }

    func signInForRemoteAccess() {
        guard let configuration = RemotePublicConfiguration.load() else {
            remoteAccountState = .failed("Public account authentication is not configured in this build.")
            return
        }
        remoteAccountState = .signingIn
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.remoteAccountService.signInAndRegisterDesktop(
                    configuration: configuration
                )
                self.remoteUsesPublicCredentials = true
                self.remotePublicAccessAvailable = true
                self.remoteAccountState = .registered
                self.reconfigureRemoteGateway()
            } catch {
                self.remoteAccountState = .failed(error.localizedDescription)
            }
        }
    }

    func createRemotePairing() {
        guard remoteUsesPublicCredentials else {
            remoteAccountState = .failed("Sign in before creating a pairing code.")
            return
        }
        remoteAccountState = .creatingPairing
        Task { [weak self] in
            guard let self else { return }
            do {
                let (pairing, registration) = try await self.remoteAccountService.createPairing()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(pairing)
                guard let payload = String(data: data, encoding: .utf8) else {
                    throw RemoteAccountError.invalidServerResponse
                }
                self.remotePublicPairingPayload = payload
                self.remoteDesktopID = registration.id
                self.remoteAccountState = .registered
                self.reconfigureRemoteGateway()
                self.clearRemotePairingPayload(at: pairing.expiresAt)
            } catch {
                self.remoteAccountState = .failed(error.localizedDescription)
            }
        }
    }

    func signOutFromRemoteAccess() {
        remoteAccountState = .signingOut
        Task { [weak self] in
            guard let self else { return }
            do {
                if let configuration = RemotePublicConfiguration.load() {
                    try await self.remoteAccountService.revokeDesktop(configuration: configuration)
                } else {
                    try self.remoteAccountService.clearLocalCredentials()
                }
                self.remoteCredentialRefreshTask?.cancel()
                self.remoteCredentialRefreshTask = nil
                self.remotePairingExpiryTask?.cancel()
                self.remotePairingExpiryTask = nil
                self.remotePublicPairingPayload = nil
                self.remoteUsesPublicCredentials = false
                self.remoteAccountState = RemotePublicConfiguration.load() == nil ? .unavailable : .signedOut
                self.reconfigureRemoteGateway()
            } catch {
                self.remoteAccountState = .failed(error.localizedDescription)
            }
        }
    }

    private func refreshRemoteAccountState() {
        let hasConfiguration = RemotePublicConfiguration.load() != nil
        let hasCredentials = (try? RemoteCredentialStore.loadDesktopRegistration()) != nil
        remotePublicAccessAvailable = hasConfiguration || hasCredentials
        remoteUsesPublicCredentials = hasCredentials
        remoteAccountState = hasCredentials ? .registered : (hasConfiguration ? .signedOut : .unavailable)
    }

    private func scheduleRemoteCredentialRefresh() {
        remoteCredentialRefreshTask?.cancel()
        guard
            let registration = try? RemoteCredentialStore.loadDesktopRegistration(),
            let expiration = registration.credentials.accessExpiration
        else { return }
        let delay = max(0, expiration.timeIntervalSinceNow - 60)
        remoteCredentialRefreshTask = Task { [weak self] in
            let nanoseconds = UInt64(min(delay, 86_400) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            do {
                _ = try await self.remoteAccountService.refreshDesktopRegistrationIfNeeded()
                self.remoteCredentialRefreshTask = nil
                self.reconfigureRemoteGateway()
            } catch {
                self.remoteAccountState = .failed(error.localizedDescription)
            }
        }
    }

    private func clearRemotePairingPayload(at expiration: String) {
        remotePairingExpiryTask?.cancel()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: expiration) else { return }
        let payload = remotePublicPairingPayload
        remotePairingExpiryTask = Task { [weak self] in
            let delay = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.remotePublicPairingPayload == payload else { return }
            self.remotePublicPairingPayload = nil
        }
    }

    /// Menu bar → open the spec documents screen (summons the panel if hidden).
    func showSpecs() {
        pendingOpenSpecs = true
        panelController?.show(preselecting: nil)
    }

    func showFeatures() {
        pendingOpenFeatures = true
        focusToken &+= 1
    }

    func summon() {
        panelController?.toggle()
    }

    /// Menu bar → attach the mobile-device picker to the terminal workspace already on screen.
    func showDeviceMirror() {
        guard let focusedSessionName else {
            panelController?.show(preselecting: nil)
            return
        }
        mirror.openPicker(for: focusedSessionName)
        panelController?.show(preselecting: focusedSessionName)
    }

    func hidePanel() {
        panelController?.hide()
    }

    var panelFloating: Bool { panelController?.isFloating ?? true }
    func setPanelFloating(_ on: Bool) { panelController?.isFloating = on }
    func togglePanelFloating() { panelController?.toggleFloating() }
    func setSettingsPresented(_ presented: Bool) { panelController?.setSettingsPresented(presented) }
    func setSummonShortcutMode(_ mode: SummonShortcutMode) { summonShortcutModeChanged?(mode) }

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

    /// Manually mark a session as checked/read. For input or decision prompts this behaves like
    /// a successful reply: the pending card state is cleared and the session returns to working.
    func markSessionChecked(_ name: String) {
        guard let session = sessions?.session(named: name) else { return }
        sessions?.acknowledge(name)
        if case .pending(let attention) = session.attention {
            switch attention.kind {
            case .decision, .input:
                sessions?.applyAttention(name: name, .working)
            case .finished:
                sessions?.applyAttention(name: name, .idle)
            }
        }
        clearSessionNotifications?(name)
    }

    /// Spin off a git worktree for a project (from a `+branch` message) and start a session in
    /// it. Returns nil on success, or a short error message for the caller to show.
    @discardableResult
    func createWorktreeSession(fromProjectRoot root: String, branch: String, agent: AgentKind) async -> String? {
        guard let sessions else { return "not ready" }
        return await sessions.createWorktreeSession(fromProjectRoot: root, branch: branch, agent: agent)
    }

    // MARK: Embedded browser (M6 — BROWSER.md)

    /// ⌘B — toggle the session's browser split. With no tab yet, open a blank one and put
    /// the keyboard in its address field (creating is the only sensible meaning of ⌘B then).
    func toggleBrowser(for session: String) {
        guard let browser else { return }
        if browser.tab(for: session) == nil {
            browser.open(url: URL(string: "about:blank")!, session: session)
            browserFocusToken &+= 1
        } else {
            browser.toggleHidden(session: session)
        }
    }

    /// ⌘L — make sure the split is visible, then move focus into its address field.
    func focusBrowserAddress(for session: String) {
        guard let browser else { return }
        if browser.tab(for: session) == nil {
            browser.open(url: URL(string: "about:blank")!, session: session)
        } else if browser.visibleTab(for: session) == nil {
            browser.toggleHidden(session: session) // un-hide
        }
        browserFocusToken &+= 1
    }

    /// Standard browser zoom shortcuts target only a browser pane that is currently visible.
    /// A hidden tab is left untouched, so ⌘-/⌘+ remain available to the normal responder chain
    /// on screens with no browser.
    func zoomBrowser(for session: String, action: BrowserZoomAction) {
        guard let tab = browser?.visibleTab(for: session) else { return }
        webViews?.zoom(tab.id, action: action)
    }

    /// The first browser pane ever mounted gets one concise Chrome-profile import prompt.
    /// Recording the claim immediately makes this genuinely one-time across sessions/relaunches;
    /// the full import control remains available in Settings if the prompt is dismissed.
    func claimBrowserProfileImportPrompt() -> Bool {
        let defaults = UserDefaults.standard
        guard !browserProfilePromptClaimed,
              !defaults.bool(forKey: BrowserProfileImportPreference.promptShownKey),
              !defaults.bool(forKey: BrowserProfileImportPreference.importedKey) else {
            return false
        }
        browserProfilePromptClaimed = true
        defaults.set(true, forKey: BrowserProfileImportPreference.promptShownKey)
        return true
    }

    /// A CLI `browser open` landed — open the tab and surface per BROWSER.md §4.4:
    /// hidden panel → summon it preselecting the target (non-activating, so the user's editor
    /// keeps focus); target already on screen → it just shows; any other case → 🌐 badge only.
    func openBrowserFromCLI(session: String, url: URL, background: Bool) {
        guard let browser else { return }
        if background {
            browser.open(url: url, session: session, markUnseen: true)
            return
        }
        if !panelVisible {
            browser.open(url: url, session: session)
            panelController?.show(preselecting: session)
        } else if focusedSessionName == session {
            browser.open(url: url, session: session)
        } else {
            browser.open(url: url, session: session, markUnseen: true)
        }
    }

    /// Open a project-configured URL directly in the selected session's embedded browser.
    func openConfiguredURL(_ url: URL, for session: String) {
        browser?.open(url: url, session: session)
        if !panelVisible {
            panelController?.show(preselecting: session)
        }
    }

    @discardableResult
    func addConfiguredURL(projectRoot: String, rawURL: String, label: String? = nil) throws -> PassConfigStore.URLItem {
        let item = try PassConfigStore.addURL(projectRoot: projectRoot, rawURL: rawURL, label: label)
        configRevision &+= 1
        return item
    }

    // MARK: Project registration

    /// Transient result of the last "Add directories…" action (shown in Settings).
    var lastProjectAddMessage: String?
    var lastProjectSyncMessage: String?
    var isProjectSyncing = false

    /// Register projects from picked folders. For each folder: if it's a git repo, register
    /// it; otherwise scan its immediate children and register every repo found. Handles
    /// single-project, parent-folder, and multi-select in one flow.
    func addProjects(dirs: [String]) {
        guard !dirs.isEmpty else { return }
        Task { @MainActor in
            var added = 0
            var addedDirectories = 0
            for dir in dirs {
                if projects?.rememberDirectory(path: dir) == true {
                    addedDirectories += 1
                }
                for root in await Self.resolveProjectRoots(under: dir) {
                    projects?.remember(rootPath: root)
                    added += 1
                }
            }
            if added == 0 {
                lastProjectAddMessage = addedDirectories == 0
                    ? "Already tracking those directories."
                    : "Directory added; no git repositories found yet."
            } else {
                lastProjectAddMessage = "Tracking \(addedDirectories) new director\(addedDirectories == 1 ? "y" : "ies"); found \(added) project\(added == 1 ? "" : "s")."
            }
            Log.app.info("addProjects: \(added) projects from \(dirs.count) tracked folder(s)")
        }
    }

    /// Re-scan every registered source. New repositories become available everywhere Pass
    /// lists projects; project paths that no longer exist are removed unless a live session
    /// still references them. Runs at launch and on demand from Settings.
    func syncProjectDirectories(automatic: Bool = false) {
        guard !isProjectSyncing else { return }
        let directories = projects?.projectDirectories ?? []
        guard !directories.isEmpty else {
            if !automatic { lastProjectSyncMessage = "Add a directory before syncing." }
            return
        }

        isProjectSyncing = true
        if !automatic { lastProjectSyncMessage = nil }
        Task { @MainActor in
            let knownBefore = Set(projects?.projects.map(\.rootPath) ?? [])
            var discovered: Set<String> = []
            var availableDirectories: [String] = []
            var unavailable = 0

            for directory in directories {
                if await Self.directoryExists(directory) {
                    availableDirectories.append(directory)
                    discovered.formUnion(await Self.resolveProjectRoots(under: directory))
                } else {
                    unavailable += 1
                }
            }

            for root in discovered {
                projects?.rememberIfNew(rootPath: root)
            }

            let liveRoots = Set(sessions?.sessions.map(\.projectRoot) ?? [])
            let missing = (projects?.projects ?? []).filter { project in
                Self.isPath(project.rootPath, insideAny: availableDirectories)
                    && !FileManager.default.fileExists(atPath: project.rootPath)
                    && !liveRoots.contains(project.rootPath)
            }
            missing.forEach { projects?.forget(rootPath: $0.rootPath) }

            let added = discovered.subtracting(knownBefore).count
            let unavailableSuffix = unavailable == 0
                ? ""
                : " · \(unavailable) unavailable director\(unavailable == 1 ? "y" : "ies")"
            lastProjectSyncMessage = "Synced \(directories.count) director\(directories.count == 1 ? "y" : "ies") · \(added) new · \(missing.count) removed\(unavailableSuffix)"
            isProjectSyncing = false
            Log.app.info("project sync: \(discovered.count) found, \(added) new, \(missing.count) removed")
        }
    }

    func setNewProjectParentDirectory(_ path: String) {
        let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        UserDefaults.standard.set(normalized, forKey: ProjectCreationService.defaultParentDirectoryKey)
        projects?.rememberDirectory(path: normalized)
    }

    /// Create an empty Git repository from the ⌘N palette, register it, and launch its first
    /// agent session. Returns a user-facing error; nil means the launch succeeded.
    func createProject(named name: String, agent: AgentKind) async -> String? {
        var parent = UserDefaults.standard.string(
            forKey: ProjectCreationService.defaultParentDirectoryKey
        ) ?? ""
        if parent.isEmpty {
            guard let picked = ProjectPicker.pickOne(
                prompt: "Use for new projects",
                message: "Choose where Pass should create new project folders"
            ) else {
                return "Choose a new-projects location in Settings › Projects."
            }
            setNewProjectParentDirectory(picked)
            parent = picked
        }

        do {
            let root = try await Task.detached { [parent] in
                try ProjectCreationService.createProject(named: name, in: parent)
            }.value
            projects?.rememberDirectory(path: parent)
            projects?.remember(rootPath: root)
            _ = await sessions?.createSession(projectDir: root, agent: agent)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func directoryExists(_ path: String) async -> Bool {
        await Task.detached {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }.value
    }

    private static func isPath(_ path: String, insideAny directories: [String]) -> Bool {
        let path = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        return directories.contains { directory in
            let directory = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.path
            return path == directory || path.hasPrefix(directory == "/" ? "/" : directory + "/")
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
        let status = AgentHooksInstaller.installAll()
        needsHookInstall = !AgentHooksInstaller.isInstalled()
        if !needsHookInstall {
            hookInstallPromptDismissed = false
            UserDefaults.standard.removeObject(forKey: AgentHookPromptPreference.dismissedKey)
        }
        Log.hooks.info("hook install requested -> \(String(describing: status), privacy: .public)")
    }

    func dismissHookInstallPrompt() {
        hookInstallPromptDismissed = true
        UserDefaults.standard.set(true, forKey: AgentHookPromptPreference.dismissedKey)
    }

    func showOnboarding() {
        showOnboardingHandler?()
    }

    func refreshRuntimeAvailability() async {
        await sessions?.refreshTmuxAvailability()
        setupProblem = sessions?.tmuxMissing == true ? "tmux가 필요합니다" : nil
    }

    /// Send a text reply into a session from the home input (without opening the terminal).
    /// Returns the injection result so the UI can surface a shell-refusal.
    @discardableResult
    func reply(to name: String, text: String) async -> ReplyInjector.Result {
        guard let s = sessions?.session(named: name) else { return .error("no session") }
        let r = await ReplyInjector.shared.sendText(name, agent: s.agent, text: text)
        // Only clear attention after tmux confirms every injection primitive succeeded. Keeping
        // the pending item visible on failure lets the user retry instead of showing false work.
        if case .delivered = r {
            sessions?.acknowledge(name)
            sessions?.applyAttention(name: name, .working)
        }
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
        guard let name = await sessions.createCommandSession(
            projectDir: cwd, slug: "dev", command: command
        ) else { return .failure("Could not start the development session.") }
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
        // Its workspace is on screen — an agent-opened page counts as seen (🌐 badge off).
        browser?.markSeen(session.name)
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
        guard PassConfig.enableFeatureDocuments else { return nil }
        guard let name = featurePreviewSessions[featureRuntimeKey(projectRoot, featureID)] else { return nil }
        return sessions?.session(named: name)
    }

    /// Start the document's development command only after the user explicitly clicks Run.
    /// Working directories are resolved by FeatureStore and cannot escape the project root.
    func startFeaturePreview(projectRoot: String, featureID: String) async -> FeatureActionResult {
        guard PassConfig.enableFeatureDocuments else {
            return .failure("Feature documents are disabled.")
        }
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
        guard let name = await sessions.createCommandSession(
            projectDir: cwd,
            slug: "preview-\(featureID)",
            command: command
        ) else { return .failure("Could not start the preview session.") }
        featurePreviewSessions[key] = name
        sessions.setAlias(name, "Preview · \(document.title)")
        return .success(name)
    }

    func stopFeaturePreview(projectRoot: String, featureID: String) {
        guard PassConfig.enableFeatureDocuments else { return }
        let key = featureRuntimeKey(projectRoot, featureID)
        guard let name = featurePreviewSessions.removeValue(forKey: key) else { return }
        killSession(name)
    }

    func openFeatureURL(_ rawURL: String) -> Bool {
        guard PassConfig.enableFeatureDocuments else { return false }
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return false }
        return NSWorkspace.shared.open(url)
    }

    func revealFeatureFile(projectRoot: String, featureID: String) {
        guard PassConfig.enableFeatureDocuments else { return }
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
        guard PassConfig.enableFeatureDocuments else {
            return .failure("Feature documents are disabled.")
        }
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
