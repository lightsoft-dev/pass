import SwiftUI

/// Root of the floating panel — a chat-style home over every session, with the SELECTED
/// session shown as a live terminal: a real `tmux attach` client (colors, styles, cursor),
/// so every keystroke goes straight into the agent's TUI and all of its features work.
/// ⌘P summons the quick command (session/project/extension search, `+branch` worktree,
/// `>command` extension-only search, plain text replies); ⌘↑↓ moves between sessions;
/// ⌘⏎ expands the session full-height.
struct CommandView: View {
    @Environment(AppModel.self) private var appModel
    @State private var route: Route = .list
    @State private var query: String = ""
    @State private var selection: Int = 0             // home cursor (over orderedSessions)
    @State private var jumpSelection: Int = 0         // cursor inside the @ jump results
    @State private var status: String?
    @State private var pendingKill: Session?          // session awaiting a kill confirmation
    @State private var showQuickCommand = false       // ⌘P quick command (hidden by default)
    @State private var newSessionMode = false         // ⌘N: results are PROJECTS, ⏎ starts a session
    @State private var terminal: TerminalController?  // live client attached to the selected session
    @State private var terminalTarget: String?        // which session the home terminal shows
    @State private var pool = TerminalPool()          // recent clients stay attached → instant switching
    @FocusState private var omniboxFocused: Bool
    @AppStorage("homeMode") private var homeModeRaw = HomeMode.stack.rawValue
    @AppStorage(TerminalTheme.storageKey) private var terminalThemeRaw = TerminalTheme.classic.rawValue
    @AppStorage("sessionDetailReadableMode") private var readableMode = false
    // Which agent ⌘N starts. Chosen from the dropdown in the new-session bar; remembered so the
    // next ⌘N defaults to your last pick.
    @AppStorage("newSessionAgent") private var newSessionAgentRaw = AgentKind.claude.rawValue

    enum Route: Equatable {
        case list
        case detail(String)                  // a session's full-height terminal (back → list)
        case specs(String?)                  // spec documents, optionally pinned to a project
        case specSession(String, String)     // session opened FROM specs (name, projectRoot)
        case features
        case feature(projectRoot: String, id: String)
        case featureSession(name: String, projectRoot: String, id: String)
    }

    private var homeMode: HomeMode { HomeMode(rawValue: homeModeRaw) ?? .stack }
    private var newSessionAgent: AgentKind { AgentKind(rawValue: newSessionAgentRaw) ?? .claude }
    private var sessions: [Session] { appModel.sessions?.sessions ?? [] }
    private var projects: [Project] { appModel.projects?.projects ?? [] }
    /// Anything typed in the quick command searches — no `@` needed (a leading `@` still works
    /// and is simply stripped). `+branch` starts a worktree; `>command` narrows to extensions.
    private var isJumpMode: Bool { !query.isEmpty && !query.hasPrefix("+") && !query.hasPrefix(">") }
    /// `>` prefix (VS Code's command convention) — the results are extension commands; ⏎ runs
    /// the selected one. NOT `/`: slash-prefixed text must keep flowing to the agent session
    /// (`/compact`, `/clear`, or any message starting with a path).
    /// (⌘N new-session mode keeps its project list even if the filter starts with '>'.)
    private var isCommandMode: Bool { query.hasPrefix(">") && !newSessionMode }

    // A jump query is `<token> <message>`: the token (up to the first space) filters/selects a
    // session; anything after the first space is a message to send to it. Tab completes the token.
    private var jumpRaw: String {
        guard isJumpMode else { return "" }
        return query.hasPrefix("@") ? String(query.dropFirst()) : query
    }
    private var jumpToken: String {
        let r = jumpRaw
        return r.firstIndex(of: " ").map { String(r[..<$0]) } ?? r
    }
    private var jumpMessage: String? {
        let r = jumpRaw
        guard let sp = r.firstIndex(of: " ") else { return nil }
        return String(r[r.index(after: sp)...])
    }
    private var jumpMessageIsReady: Bool {
        (jumpMessage?.trimmingCharacters(in: .whitespaces).isEmpty == false)
    }
    /// The centered quick command is up: summoned with ⌘P, or forced when there's no session
    /// yet (creating one is the only possible action). It hides after sending a message, or
    /// with another ⌘P, or with Esc (the panel itself never closes on Esc).
    private var showsCommandBar: Bool { showQuickCommand || sessions.isEmpty }
    /// The quick command currently owns the keyboard (otherwise the terminal does).
    private var typingInBar: Bool { showsCommandBar && omniboxFocused }

    private var selectedSession: Session? {
        guard orderedSessions.indices.contains(selection) else { return nil }
        return orderedSessions[selection]
    }

    /// The jump result list and its own selection — kept separate from the home cursor so
    /// filtering doesn't yank the terminal around behind the bar. With nothing typed yet, the
    /// live sessions are offered; registered projects join once a filter narrows things down
    /// (there are far too many to list unfiltered).
    private var jumpItems: [PaletteItem] {
        // `>` mode: extension commands only (from enabled, valid extensions).
        if isCommandMode {
            let needle = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
            return matchingExtensionCommands(needle).map { .command($0) }
        }
        let needle = jumpToken.trimmingCharacters(in: .whitespaces)
        // ⌘N mode: the list is PROJECTS to start a session in (all of them until you type).
        if newSessionMode {
            return projects
                .filter { needle.isEmpty || Fuzzy.matches(needle, $0.name) }
                .map { .project($0) }
        }
        if needle.isEmpty { return orderedSessions.map { .session($0) } }
        return filteredItems(needle)
    }
    private var jumpSelectedItem: PaletteItem? {
        jumpItems.indices.contains(jumpSelection) ? jumpItems[jumpSelection] : nil
    }

    /// The session order the home renders — chat-room style in every mode: sessions you need to
    /// respond to cluster at the BOTTOM, nearest the terminal/input. The oldest-waiting one sits
    /// at the very bottom (next to handle); newer arrivals stack above it; the rest stay up top
    /// by recency. Handling one drops it back up top.
    private var orderedSessions: [Session] {
        let waiting = sessions.filter { $0.needsUser }.sorted { pendingSince($0) > pendingSince($1) }
        let rest = sessions.filter { !$0.needsUser }
        return rest + waiting
    }

    private func pendingSince(_ s: Session) -> Date {
        if case .pending(let a) = s.attention { return a.receivedAt }
        return s.lastActivity
    }

    /// New rows slide up in from the bottom + fade; removed rows fade + collapse — so create/kill
    /// read as motion, not a jump.
    private var rowTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity.combined(with: .scale(scale: 0.9))
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if appModel.extensions?.activeExtensions.isEmpty == false {
                ExtensionLauncherBar(contextSession: extensionContextSession)
                Divider()
            }
            content
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .onChange(of: appModel.focusToken) { _, _ in
                query = ""
                showQuickCommand = false // fresh summon lands in the terminal, not the bar
                newSessionMode = false
                if appModel.pendingOpenSpecs {
                    appModel.pendingOpenSpecs = false // menu bar asked for the specs screen
                    route = .specs(selectedSession?.projectRoot) // land on the current project
                } else {
                    route = .list
                    focusSoon()
                }
            }
            .onChange(of: appModel.backToken) { _, _ in
                switch route {
                case .specSession(_, let root): route = .specs(root) // ⌘[ steps back one level
                case .feature(let root, let id), .featureSession(_, let root, let id):
                    route = .feature(projectRoot: root, id: id)
                case .specs, .features, .detail:
                    route = .list; focusSoon()
                case .list:
                    break
                }
            }
            .onChange(of: appModel.forceOpenSession) { _, s in
                // Consume the request so the SAME session can be force-opened again later
                // (onChange only fires on a value change).
                if let s { route = .detail(s); appModel.forceOpenSession = nil }
            }
            // Keep `selection` on the same session when the home list reorders (e.g. one becomes
            // pending and drops to the bottom cluster) — so the terminal never silently switches
            // to a different session mid-interaction.
            .onChange(of: orderedSessions.map(\.id)) { old, new in
                pool.prune(keeping: Set(new)) // clients for vanished sessions
                guard old.indices.contains(selection) else { return }
                let name = old[selection]
                selection = new.firstIndex(of: name) ?? min(selection, max(0, new.count - 1))
            }
            .onAppear { appModel.keyHandler = handleNav }
            .confirmationDialog(
                "Kill session?",
                isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
                presenting: pendingKill,   // the exact session is passed to the buttons — no stale capture
                actions: { session in
                    Button("Kill \(session.displayName)", role: .destructive) {
                        pool.drop(session.name) // its attach client dies with the session
                        appModel.killSession(session.name)
                        pendingKill = nil
                    }
                    Button("Cancel", role: .cancel) { pendingKill = nil }
                },
                message: { _ in
                    Text("Ends the tmux session and the agent running in it. This can't be undone.")
                }
            )
    }

    /// Plain Up/Down/Return/Escape, routed from SummonPanel.performKeyEquivalent (AppKit-level
    /// — reliable regardless of which control currently holds focus). Returns false to let the
    /// key fall through the responder chain — which is now the DEFAULT: the embedded terminal
    /// is first responder, and plain keys (arrows, ⏎, Esc, Tab, digits…) belong to the TUI
    /// running in the session. Only ⌘-chords and message-bar editing are handled here.
    private func handleNav(_ e: PanelNavEvent) -> Bool {
        // Browser keys work wherever a session workspace is on screen —
        // the home terminal AND the detail view — so they're routed before the list guard.
        switch e.key {
        case .toggleBrowser:
            guard let name = workspaceSessionName else { return true }
            appModel.toggleBrowser(for: name)
            return true
        case .focusAddress:
            guard let name = workspaceSessionName else { return true }
            appModel.focusBrowserAddress(for: name)
            return true
        case .expandBrowser:
            guard let name = workspaceSessionName,
                  appModel.browser?.visibleTab(for: name) != nil else { return true }
            appModel.browser?.expanded.toggle()
            return true
        case .browserZoomIn:
            guard let name = workspaceSessionName,
                  appModel.browser?.visibleTab(for: name) != nil else { return false }
            appModel.zoomBrowser(for: name, action: .zoomIn)
            return true
        case .browserZoomOut:
            guard let name = workspaceSessionName,
                  appModel.browser?.visibleTab(for: name) != nil else { return false }
            appModel.zoomBrowser(for: name, action: .zoomOut)
            return true
        case .browserZoomReset:
            guard let name = workspaceSessionName,
                  appModel.browser?.visibleTab(for: name) != nil else { return false }
            appModel.zoomBrowser(for: name, action: .reset)
            return true
        case .markChecked:
            guard let name = workspaceSessionName else { return true }
            appModel.markSessionChecked(name)
            return true
        default:
            break
        }
        guard route == .list else { return false }
        switch e.key {
        case .toggleInput:
            toggleQuickCommand()
            return true
        case .openSpecs:
            // ⌘D — the selected session's project document.
            guard let s = selectedSession else { return true }
            route = .specs(s.projectRoot)
            return true
        case .newSession:
            // ⌘N — pick a project, ⏎ starts a session in it.
            status = nil
            query = ""
            newSessionMode = true
            showQuickCommand = true
            jumpSelection = 0
            refocusField()
            return true
        case .newWorktree:
            // ⌘T — worktree session off the selected session, branch name prefilled: just ⏎.
            guard let s = selectedSession else { return true }
            beginWorktreeSession(from: s)
            return true
        case .up:
            if e.command { navMove(-1); return true }
            if isJumpMode || isCommandMode || (newSessionMode && typingInBar) { moveJump(-1); return true }
            return false // terminal (or the bar's text cursor) gets plain arrows
        case .down:
            if e.command { navMove(1); return true }
            if isJumpMode || isCommandMode || (newSessionMode && typingInBar) { moveJump(1); return true }
            return false
        case .tab:
            // Tab autocompletes the '@' token to the top match, then leaves a trailing space so
            // you can keep typing a message: "@iv" → "@ivma " → "@ivma xx 작업 부탁해". While
            // typing in the bar, swallow it (no responder-chain hop); otherwise the terminal
            // gets real Tabs (TUI completion).
            if isJumpMode || isCommandMode { completeJump(); return true }
            return typingInBar
        case .nextWaiting:
            // ⇧⇧ — hop to the next session waiting on you (cycling). Inert while typing a
            // query — moving the selection would silently retarget a session-context command.
            guard !isJumpMode, !isCommandMode else { return true }
            return jumpToNextWaiting()
        case .returnKey:
            if isCommandMode {
                if case .command(let c)? = jumpSelectedItem { runExtensionCommand(c) }
                return true
            }
            if newSessionMode {
                if case .project(let p)? = jumpSelectedItem {
                    appModel.createSession(projectDir: p.rootPath, agent: newSessionAgent)
                    hideQuickCommand()
                }
                return true
            }
            if isJumpMode {
                // First word matched nothing → it wasn't a session name; send the whole text
                // to the selected session instead.
                if jumpItems.isEmpty { sendReplyToSelected(jumpRaw); return true }
                guard let item = jumpSelectedItem else { return true }
                switch item {
                case .session(let s):
                    if e.command { route = .detail(s.name) }        // ⌘⏎ dive into the terminal
                    else if jumpMessageIsReady { sendJumpMessage(to: s) } // "name msg" ⏎ → send
                    else { jumpToSession(s) }                        // "name" ⏎ → focus its terminal
                case .project(let p):
                    // Agent choice lives in the menu bar (New session ▸) — rarely needed, so the
                    // fast path here always starts the default agent.
                    appModel.createSession(projectDir: p.rootPath) // ⏎ start it
                    query = ""
                    hideQuickCommand() // action done — watch the new session arrive
                case .command(let c):
                    runExtensionCommand(c)
                }
                return true
            }
            if e.command { openSelectedTerminal(); return true }
            guard typingInBar else { return false } // plain ⏎ goes into the terminal
            if query.hasPrefix("+") { createWorktreeFromInput() } // confirms + closes (errors reopen)
            else if !sessions.isEmpty { hideQuickCommand() } // empty ⏎ → back to the terminal
            return true
        case .delete:
            // ⌘⌫ → confirm killing the selected session.
            if let s = selectedSession { pendingKill = s }
            return true
        case .markChecked:
            return true // handled before the route guard
        case .escape:
            if pendingKill != nil { pendingKill = nil; return true }
            if typingInBar {
                if !sessions.isEmpty { hideQuickCommand() } // Esc closes the ⌘P bar
                return true
            }
            // The terminal owns Esc (interrupting the agent). Use the selected global shortcut.
            return false
        case .toggleBrowser, .focusAddress, .expandBrowser,
             .browserZoomIn, .browserZoomOut, .browserZoomReset:
            return true // handled above, before the route guard
        }
    }

    /// The session whose workspace (terminal │ browser) is on screen — browser keys target it.
    private var workspaceSessionName: String? {
        switch route {
        case .detail(let name), .specSession(let name, _), .featureSession(let name, _, _):
            return name
        case .list: return selectedSession?.name
        case .specs, .features, .feature: return nil
        }
    }

    /// Context used by a plugin launched from the top bar. Detail routes target the session
    /// actually on screen; the home targets its selected card; specs have no session context.
    private var extensionContextSession: Session? {
        switch route {
        case .detail(let name), .specSession(let name, _), .featureSession(let name, _, _):
            return sessions.first { $0.name == name }
        case .list:
            return selectedSession
        case .specs, .features, .feature:
            return nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .list:
            listMode
        case .features:
            if PassConfig.enableFeatureDocuments {
                FeatureLibraryView(
                    onBack: { route = .list; focusSoon() },
                    onOpen: { root, id in route = .feature(projectRoot: root, id: id) }
                )
            } else {
                listMode.onAppear { route = .list; focusSoon() }
            }
        case .feature(let projectRoot, let id):
            if !PassConfig.enableFeatureDocuments {
                listMode.onAppear { route = .list; focusSoon() }
            } else if let document = appModel.features?.document(projectRoot: projectRoot, id: id) {
                FeatureDetailView(
                    projectRoot: projectRoot,
                    document: document,
                    onBack: { route = .features },
                    onOpenSession: {
                        route = .featureSession(name: $0, projectRoot: projectRoot, id: id)
                    }
                )
            } else {
                FeatureLibraryView(
                    onBack: { route = .list; focusSoon() },
                    onOpen: { root, id in route = .feature(projectRoot: root, id: id) }
                )
                .onAppear { appModel.features?.reload(projectRoot: projectRoot) }
            }
        case .featureSession(let name, let projectRoot, let id):
            if !PassConfig.enableFeatureDocuments {
                listMode.onAppear { route = .list; focusSoon() }
            } else if let session = sessions.first(where: { $0.name == name }) {
                SessionDetailView(session: session) {
                    route = .feature(projectRoot: projectRoot, id: id)
                }
            } else {
                Color.clear.onAppear { route = .feature(projectRoot: projectRoot, id: id) }
            }
        case .detail(let name):
            if let session = sessions.first(where: { $0.name == name }) {
                SessionDetailView(session: session) { route = .list; focusSoon() }
            } else {
                // session vanished while open
                listMode.onAppear { route = .list }
            }
        case .specs(let root):
            SpecsView(
                initialRoot: root,
                onBack: { route = .list; focusSoon() },
                onOpenSession: { name, root in route = .specSession(name, root) }
            )
        case .specSession(let name, let root):
            if let session = sessions.first(where: { $0.name == name }) {
                SessionDetailView(session: session) { route = .specs(root) }
            } else {
                listMode.onAppear { route = .specs(root) } // session vanished — back to the doc
            }
        }
    }

    // MARK: List mode

    private var listMode: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                if appModel.needsHookInstall { hookBanner }
                HStack {
                    Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                    Text("Sessions").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    FeedbackButton()
                    if PassConfig.enableFeatureDocuments {
                        Button {
                            query = ""
                            route = .features
                        } label: {
                            Label("Features", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Executable software feature documents")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                Divider()
                if homeMode == .sidebar {
                    // Rows on the LEFT, the live terminal filling the right side.
                    HStack(spacing: 0) {
                        listBody
                            .frame(width: min(max(geo.size.width * 0.34, 210), 320))
                        Divider()
                        if selectedSession != nil {
                            terminalPanel
                        } else {
                            Spacer().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } else {
                    listBody
                    // List mode: rows on TOP, the selected session's live terminal below,
                    // chat-style (stack mode embeds it in the focused card instead).
                    if homeMode == .list && selectedSession != nil {
                        Divider()
                        terminalPanel
                            .frame(height: min(max(geo.size.height * 0.52, 200), 480))
                    }
                }
            }
            // ⌘P — the quick command floats centered over the home (Spotlight-style).
            // The home (and its attached terminal) stays mounted behind it.
            .overlay {
                if showsCommandBar {
                    commandBarOverlay(maxWidth: geo.size.width)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(.easeOut(duration: 0.12), value: showsCommandBar)
        }
        .onAppear { focusSoon() }
        .onChange(of: selectedSession?.name) { _, _ in syncTerminalTarget() }
        .onChange(of: selectedSession?.launching) { _, _ in syncTerminalTarget() }
        // A needs-you request landing on the session whose live terminal is on screen is
        // already "checked" — clear the border immediately instead of leaving it stuck.
        .onChange(of: selectedSession?.unacknowledged) { _, unacked in
            if unacked == true, appModel.panelVisible,
               let s = selectedSession, s.name == terminalTarget {
                appModel.sessions?.acknowledge(s.name)
            }
        }
        .task(id: terminalKey) { await runTerminal() }
    }

    // MARK: Centered quick command (⌘P)

    private func commandBarOverlay(maxWidth: CGFloat) -> some View {
        ZStack {
            // Dim the home behind; click outside dismisses (unless it's the only UI).
            Color.black.opacity(0.22)
                .contentShape(Rectangle())
                .onTapGesture { if !sessions.isEmpty { hideQuickCommand() } }
            commandBar
                .frame(width: min(540, maxWidth - 48))
                .shadow(color: .black.opacity(0.35), radius: 28, y: 10)
        }
    }

    private var commandBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: newSessionMode ? "plus.circle"
                        : query.hasPrefix("+") ? "arrow.triangle.branch"
                        : isCommandMode ? "puzzlepiece.extension" : "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundStyle(newSessionMode || isJumpMode || isCommandMode || query.hasPrefix("+")
                                     ? Color.accentColor : .secondary)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($omniboxFocused)
                    .onChange(of: query) { old, new in handleQueryChange(old: old, new: new) }
                    // Tab completes the @-token here — the field editor eats Tab before
                    // performKeyEquivalent sees it, so intercept it at the SwiftUI layer.
                    .onKeyPress(.tab) {
                        if isJumpMode || isCommandMode { completeJump(); return .handled }
                        return .ignored
                    }
                    .onAppear { refocusField() } // grab focus the instant this field mounts
                if newSessionMode { newSessionAgentPicker }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)

            Divider()
            Group {
                if let status {
                    Text(status).foregroundStyle(.orange)
                } else {
                    Text(hint).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 6)

            // Results live inside the bar, Spotlight-style — the live sessions when nothing
            // is typed yet, the filtered matches once you type.
            if !query.hasPrefix("+") {
                Divider()
                jumpResults
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    /// ⌘N agent dropdown — pick which CLI the new session launches (claude/codex/pi). Sits at the
    /// top-right of the new-session bar; the choice is remembered for next time.
    private var newSessionAgentPicker: some View {
        Menu {
            ForEach(AgentKind.launchable, id: \.self) { agent in
                Button {
                    newSessionAgentRaw = agent.rawValue
                    refocusField() // keep typing the project name after choosing
                } label: {
                    Text("\(agent == newSessionAgent ? "✓ " : "")\(agent.glyph)  \(agent.rawValue)")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(newSessionAgent.glyph)
                Text(newSessionAgent.rawValue).font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var jumpResults: some View {
        if jumpItems.isEmpty {
            Text(isCommandMode
                 ? "No extension commands — install & enable extensions in Settings."
                 : selectedSession.map { "No matches — ⏎ sends this to \($0.displayName)" }
                 ?? "No matches — try a different name.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(jumpItems.enumerated()), id: \.element.id) { idx, item in
                            PaletteRow(item: item, selected: idx == jumpSelection)
                                .contentShape(Rectangle())
                                .onTapGesture { jumpSelection = idx; activate(item) }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 280)
                // Scroll by element id (stable) — indices shift as the filter narrows.
                .onChange(of: jumpSelection) { _, sel in
                    guard jumpItems.indices.contains(sel) else { return }
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(jumpItems[sel].id, anchor: .center) }
                }
            }
        }
    }

    private var placeholder: String {
        newSessionMode ? "new session — project name" : "search — session name, then your message"
    }

    private var hint: String {
        if newSessionMode {
            if case .project(let p)? = jumpSelectedItem { return "⏎ new \(newSessionAgent.rawValue) session in \(p.name)" }
            return "type a project name · ⏎ start a \(newSessionAgent.rawValue) session · Esc close"
        }
        if query.hasPrefix("+") {
            let branch = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
            return branch.isEmpty ? "⏎ new git worktree + session (name the branch)"
                                  : "⏎ create worktree “\(branch)” + session"
        }
        if isCommandMode {
            if case .command(let c)? = jumpSelectedItem {
                return commandHint(c)
            }
            return "extension commands · ⏎ run · Esc close"
        }
        if isJumpMode {
            if jumpItems.isEmpty, let s = selectedSession {
                return "no matches — ⏎ sends this to \(s.displayName)"
            }
            if case .command(let c)? = jumpSelectedItem { return commandHint(c) }
            if case .project(let p)? = jumpSelectedItem { return "⏎ new session in \(p.name)" }
            if jumpMessageIsReady, case .session(let s)? = jumpSelectedItem {
                return "⏎ send to \(s.displayName)"
            }
            return "Tab complete · ⏎ go to session · keep typing to message it"
        }
        return "type to search sessions, projects, commands · +branch · >command"
    }

    @ViewBuilder
    private var listBody: some View {
        if appModel.sessions?.tmuxMissing == true {
            message("exclamationmark.triangle", "tmux not found",
                    "Install tmux (brew install tmux) and reopen pass.")
        } else if orderedSessions.isEmpty {
            message("bubble.left.and.bubble.right", "No sessions yet",
                    "@ to start one, or use New session… from the menu bar.")
        } else if homeMode != .stack {
            // Compact rows (list & sidebar modes): every session is a uniform row; the selected
            // one is highlighted and its live terminal shows beside/below. ⌘↑↓ / clicks move
            // the selection.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(orderedSessions.enumerated()), id: \.element.id) { idx, s in
                            CompactSessionCard(session: s, selected: idx == selection,
                                               onSelect: { selection = idx },
                                               onMarkChecked: { appModel.markSessionChecked(s.name) },
                                               onNewWorktree: { beginWorktreeSession(from: s) },
                                               onDelete: { pendingKill = s },
                                               browserUnseen: appModel.browser?.hasUnseen(s.name) ?? false)
                                .transition(rowTransition)
                        }
                    }
                    .padding(8)
                    .animation(.spring(response: 0.34, dampingFraction: 0.82), value: orderedSessions.map(\.id))
                }
                .onChange(of: selection) { _, sel in
                    guard orderedSessions.indices.contains(sel) else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(orderedSessions[sel].id, anchor: .center) }
                }
            }
        } else {
            // Home: one big focused card (the session's live terminal) + small rows for the
            // rest. ⌘↑↓ or a click move focus. Plain VStack (not Lazy) — LazyVStack fails to
            // re-layout a row whose size changes purely from `selection` (external state).
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(orderedSessions.enumerated()), id: \.element.id) { idx, s in
                            Group {
                                if idx == selection {
                                    FocusedSessionCard(
                                        session: s,
                                        terminal: (displayedTerminal?.sessionName == s.name) ? displayedTerminal : nil,
                                        onMarkChecked: { appModel.markSessionChecked(s.name) },
                                        onNewWorktree: { beginWorktreeSession(from: s) },
                                        onDelete: { pendingKill = s }
                                    )
                                } else {
                                    CompactSessionCard(session: s, onSelect: { selection = idx },
                                                       onMarkChecked: { appModel.markSessionChecked(s.name) },
                                                       onNewWorktree: { beginWorktreeSession(from: s) },
                                                       browserUnseen: appModel.browser?.hasUnseen(s.name) ?? false)
                                }
                            }
                            .transition(rowTransition)
                        }
                    }
                    .padding(8)
                    .animation(.spring(response: 0.34, dampingFraction: 0.82), value: orderedSessions.map(\.id))
                }
                .onChange(of: selection) { _, sel in
                    guard orderedSessions.indices.contains(sel) else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(orderedSessions[sel].id, anchor: .center) }
                }
            }
        }
    }

    private func message(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 15, weight: .medium))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    // MARK: Live terminal (home)

    /// Restarts the attach task when the target or panel visibility changes. Empty = no client.
    private var terminalKey: String {
        guard appModel.panelVisible, let t = terminalTarget else { return "" }
        return t
    }

    /// The client the home should render RIGHT NOW: the switch task's controller once it has
    /// caught up, else the already-attached pooled client — so flipping between warmed
    /// sessions never shows a spinner frame.
    private var displayedTerminal: TerminalController? {
        if let terminal, terminal.sessionName == terminalTarget { return terminal }
        return pool.peek(terminalTarget)
    }

    /// Point the home terminal at the selected session. A launching placeholder has no tmux
    /// session yet, so it shows a spinner instead.
    private func syncTerminalTarget() {
        if let s = selectedSession { terminalTarget = s.launching ? nil : s.name }
        else { terminalTarget = nil }
    }

    /// Show the target session's live client, reusing a pooled (still-attached) one when we
    /// have it — switching back to a recent session is instant, with no re-attach repaint.
    /// The pool survives panel hide/show (re-attaching would make every reopen repaint every
    /// session top-to-bottom); clients are dropped when their session dies.
    private func runTerminal() async {
        guard !terminalKey.isEmpty else {
            terminal = nil
            appModel.focusedSessionName = nil // no workspace on screen
            return
        }
        let name = terminalKey
        // The session whose workspace is on screen — a CLI browser open targeting it may
        // show immediately; any other session only gets the 🌐 badge (never steal focus).
        appModel.focusedSessionName = name
        // Warm clients for the sessions you're likely to hop to next (waiting ones first, for
        // ⇧⇧) BEFORE touching the current one, so the LRU never evicts the session on screen.
        // They're sized like the on-screen terminal so tmux never reflows to a phantom 80×25.
        let refSize = displayedTerminal?.terminalView.frame.size
        let warmable = orderedSessions.filter { $0.name != name && !$0.launching }
        pool.warm((warmable.filter(\.needsUser) + warmable.filter { !$0.needsUser }).map(\.name),
                  size: refSize)
        let controller = pool.controller(for: name, size: refSize)
        terminal = controller
        // Its live terminal is on screen — that counts as checking the session (clears the
        // needs-you border, reconciles stale pending state), same as opening the detail view.
        if let s = sessions.first(where: { $0.name == name }) { appModel.reconcileOnOpen(s) }
        if !showQuickCommand && !readableMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { controller.focus() }
        }
    }

    /// The compact-list mode terminal strip: the selected session's live client + a key hint.
    private var terminalPanel: some View {
        // Edge-to-edge: the terminal's BACKGROUND fills the whole section; the text is inset
        // by same-color padding so it can breathe. A hairline key-hint strip sits under it.
        VStack(alignment: .leading, spacing: 0) {
            if let live = displayedTerminal, let s = selectedSession {
                HStack {
                    Text(s.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    MiniTerminalButton(session: s)
                    SessionPresentationPicker(readableMode: $readableMode) {
                        DispatchQueue.main.async { live.focus() }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                Divider()
                // Workspace = terminal │ (optional) browser split for the selected session.
                SessionWorkspaceView(session: s) {
                    Group {
                        if readableMode {
                            ConversationPaneView(session: s)
                        } else {
                            TerminalPaneView(controller: live)
                                .id(live.sessionName) // new session → new NSView (updateNSView can't swap it)
                                .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 6)
                                .background(Color(nsColor: (TerminalTheme(rawValue: terminalThemeRaw) ?? .classic).nsBackground))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedSession?.launching == true {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("starting \(selectedSession?.agent.rawValue ?? "agent")…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            Text(readableMode
                 ? "select text · tools expand on click · ⇧⇧ next waiting · ⌘P quick command · ⌘B browser · ⌘J/K sessions · ⌘⏎ expand"
                 : "drag select · ⌘C copy · ⌥drag tmux · ⇧⇧ next waiting · ⌘M checked · ⌘P quick command · ⌘B browser · ⌘J/K sessions · ⌘⏎ expand · ⌘⌫ kill")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.horizontal, 8).padding(.vertical, 3)
        }
    }

    // MARK: Filtered items

    private func filteredItems(_ needleRaw: String) -> [PaletteItem] {
        let needle = needleRaw.trimmingCharacters(in: .whitespaces)

        var out: [PaletteItem] = sessions.compactMap { s in
            guard needle.isEmpty || Fuzzy.matches(needle, s.displayName) || Fuzzy.matches(needle, s.name)
            else { return nil }
            return .session(s)
        }
        // Also offer registered projects without a live session (jump / create).
        let liveRoots = Set(sessions.map(\.projectRoot))
        for p in projects where !liveRoots.contains(p.rootPath) {
            if needle.isEmpty || Fuzzy.matches(needle, p.name) { out.append(.project(p)) }
        }
        out.append(contentsOf: matchingExtensionCommands(needle).map { .command($0) })
        return out
    }

    private func matchingExtensionCommands(_ needleRaw: String) -> [ExtensionStore.PaletteCommand] {
        let needle = needleRaw.trimmingCharacters(in: .whitespaces)
        return (appModel.extensions?.paletteCommands ?? []).filter { command in
            needle.isEmpty || commandMatches(needle, command)
        }
    }

    private func commandMatches(_ needle: String, _ command: ExtensionStore.PaletteCommand) -> Bool {
        Fuzzy.matches(needle, command.command.id)
            || Fuzzy.matches(needle, command.command.title)
            || Fuzzy.matches(needle, command.extensionName)
            || Fuzzy.matches(needle, command.token)
    }

    private func commandHint(_ c: ExtensionStore.PaletteCommand) -> String {
        // Everything but "global" runs against the selected session (runtime rule).
        let target = c.command.contextKind == "global" ? ""
            : (selectedSession.map { " on \($0.displayName)" } ?? " — select a session first")
        return "⏎ run \(c.token)\(target) · \(c.extensionName)"
    }

    // MARK: Keyboard

    /// ↑↓ inside the @ jump results.
    private func moveJump(_ delta: Int) {
        guard !jumpItems.isEmpty else { return }
        jumpSelection = max(0, min(jumpItems.count - 1, jumpSelection + delta))
    }

    /// ⌘↑↓ session navigation. Abandon an in-progress message draft when moving to another
    /// session; in @ jump / > command mode, keep the filter text (plain arrows move the cursor).
    private func navMove(_ delta: Int) {
        if !isJumpMode && !isCommandMode { query = "" }
        guard !orderedSessions.isEmpty else { return }
        selection = max(0, min(orderedSessions.count - 1, selection + delta))
    }

    /// ⇧⇧: cycle to the next session that needs input (downward, wrapping). Returns false
    /// when no OTHER session is waiting.
    private func jumpToNextWaiting() -> Bool {
        let list = orderedSessions
        guard !list.isEmpty else { return false }
        for offset in 1...list.count {
            let idx = (selection + offset) % list.count
            if list[idx].needsUser, idx != selection {
                selection = idx
                return true
            }
        }
        return false
    }

    private func handleQueryChange(old: String, new: String) {
        status = nil
        // Worktree (branch) names can't contain spaces — typing one becomes '-' as you type.
        if new.hasPrefix("+"), new.contains(" ") {
            query = new.replacingOccurrences(of: " ", with: "-")
            return
        }
        if isJumpMode || isCommandMode { jumpSelection = 0 } // filtering always re-selects the top match
    }

    /// ⌘P — show/hide the quick command. Hiding it hands the keyboard back to the terminal.
    private func toggleQuickCommand() {
        if showQuickCommand { hideQuickCommand() }
        else { status = nil; showQuickCommand = true; refocusField() }
    }

    private func hideQuickCommand() {
        showQuickCommand = false
        newSessionMode = false
        query = ""
        omniboxFocused = false
        terminal?.focus()
    }

    private func openSelectedTerminal() {
        guard let s = selectedSession else { return }
        omniboxFocused = false
        route = .detail(s.name)
    }

    /// Leave the quick command and land on the chosen session — its live terminal takes over.
    private func jumpToSession(_ s: Session) {
        if let idx = orderedSessions.firstIndex(where: { $0.name == s.name }) { selection = idx }
        hideQuickCommand()
    }

    /// Tab: replace the '@' token with the top match's name, keep any typed message, add a
    /// trailing space so typing continues into the message.
    private func completeJump() {
        guard let top = jumpItems.first else { return }
        let token: String
        switch top {
        case .session(let s): token = jumpCompletionToken(s)
        case .project(let p): token = Slug.make(p.name)
        case .command(let c): token = c.token
        }
        let msg = jumpMessage ?? ""
        query = token + " " + msg
        jumpSelection = 0
        FieldEditorFix.cursorToEnd() // keep typing at the end of the message
    }

    /// A session's short '@' token: its tmux name minus the "pass-" prefix (e.g. pass-ivma → ivma).
    private func jumpCompletionToken(_ s: Session) -> String {
        s.name.hasPrefix(PassConfig.sessionPrefix)
            ? String(s.name.dropFirst(PassConfig.sessionPrefix.count))
            : s.name
    }

    /// "@name message" + ⏎ → send the message straight to that session, land on it, and close
    /// the quick command (watch the terminal react). If delivery fails, the quick command
    /// pops back up with the warning — a silent failed send would be worse than the surprise.
    private func sendJumpMessage(to s: Session) {
        let text = (jumpMessage ?? "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { jumpToSession(s); return }
        if let idx = orderedSessions.firstIndex(where: { $0.name == s.name }) { selection = idx }
        hideQuickCommand()
        Task {
            let r = await appModel.reply(to: s.name, text: text)
            if case .refusedShell = r {
                status = "⚠ \(s.displayName): agent not running — ⌘⏎ to open terminal"
                showQuickCommand = true
                refocusField()
            }
        }
    }

    /// ⏎ on a plain message → send and close the quick command (reopens with a warning if the
    /// send was refused).
    private func sendReplyToSelected(_ text: String) {
        guard let s = selectedSession, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        hideQuickCommand()
        Task {
            let r = await appModel.reply(to: s.name, text: text)
            if case .refusedShell = r {
                status = "⚠ \(s.displayName): agent not running — ⌘⏎ to open terminal"
                showQuickCommand = true
                refocusField()
            }
        }
    }

    /// Open the existing `+branch` flow for a specific session. Context menus can belong to an
    /// unfocused row, so move the home cursor first; submitting the prefilled branch will then
    /// inherit that session's project and agent.
    private func beginWorktreeSession(from session: Session) {
        if let idx = orderedSessions.firstIndex(where: { $0.name == session.name }) {
            selection = idx
        }
        let root = session.git?.projectRoot ?? session.projectRoot
        let existing = sessions.filter {
            $0.projectRoot == root && $0.git?.isLinkedWorktree == true
        }.count
        status = nil
        newSessionMode = false
        showQuickCommand = true
        jumpSelection = 0
        query = "+wt-\(existing + 1)"
        refocusField()
    }

    /// A `+branch` entry spins off a git worktree of the focused session's project and starts
    /// a new session in it (same agent). ⏎ confirms and CLOSES the quick command — the new
    /// session card appears in the home; a failure reopens the bar with the error.
    private func createWorktreeFromInput() {
        guard let s = selectedSession else { return }
        let branch = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard !branch.isEmpty else { return }
        let root = s.git?.projectRoot ?? s.projectRoot
        hideQuickCommand()
        Task {
            let err = await appModel.createWorktreeSession(fromProjectRoot: root, branch: branch, agent: s.agent)
            if let err {
                status = "⚠ worktree: \(err)"
                showQuickCommand = true // a silent failure would be worse than the surprise
                refocusField()
            }
        }
    }

    private func activate(_ item: PaletteItem) {
        switch item {
        case .session(let s):
            jumpToSession(s)
        case .project(let p):
            // In ⌘N the dropdown chooses the agent; a project tap in @-jump uses the default.
            appModel.createSession(projectDir: p.rootPath, agent: newSessionMode ? newSessionAgent : .claude)
            query = ""
        case .command(let c):
            runExtensionCommand(c)
        }
    }

    /// Run an extension's `/command` against the selected session. The bar closes on success
    /// (a terminal-mode command opens its report session); a failure reopens it with the error.
    private func runExtensionCommand(_ c: ExtensionStore.PaletteCommand) {
        let session = selectedSession
        hideQuickCommand()
        Task {
            if let err = await appModel.extensionRuntime?.run(c, session: session) {
                status = "⚠ \(c.token): \(err)"
                showQuickCommand = true
                refocusField()
            }
        }
    }

    private var hookBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.badge.a").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude hooks not installed").font(.system(size: 12, weight: .medium))
                Text("pass can't hear about sessions until you install them.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Install") { appModel.installHooks() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    private func focusSoon() {
        selection = initialSelection()
        syncTerminalTarget()
        refocusField()
    }

    /// Where the cursor lands when the panel opens: an explicitly requested session first
    /// (notification click, CLI browser open — `pendingPreselect`, consumed here), else the
    /// waiting session nearest the input (bottom of the queue), else the top.
    private func initialSelection() -> Int {
        let target = appModel.pendingPreselect
        appModel.pendingPreselect = nil
        if let target, let i = orderedSessions.firstIndex(where: { $0.name == target }) { return i }
        if let i = orderedSessions.lastIndex(where: { $0.needsUser }) { return i }
        return 0
    }

    /// Route the keyboard to whichever input is active: the message bar when it's up,
    /// otherwise the embedded terminal. (Forces a false→true transition on the FocusState —
    /// setting it true while already true is a no-op and focus wouldn't move.)
    private func refocusField() {
        guard showsCommandBar else { terminal?.focus(); return }
        omniboxFocused = false
        DispatchQueue.main.async {
            omniboxFocused = true
            FieldEditorFix.cursorToEnd()
        }
    }
}

/// Programmatically focusing a text field selects its whole text (standard macOS behavior),
/// so the next keystroke REPLACES it — e.g. typing after "@" would wipe the "@", silently
/// exiting jump mode and dumping the keystroke into the session reply field. After moving
/// focus, put the insertion point at the end instead.
@MainActor
enum FieldEditorFix {
    static func cursorToEnd() {
        DispatchQueue.main.async { // one more hop: run after FocusState has actually landed
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)
        }
    }
}

/// The focused session in the home stack — its LIVE terminal embedded in the card: a real
/// tmux client (full colors/styles), so keystrokes go straight into the agent's TUI. The
/// quick command (⌘P) handles send-without-focus; the card itself is all terminal.
struct FocusedSessionCard: View {
    let session: Session
    var terminal: TerminalController?
    var onMarkChecked: (() -> Void)? = nil
    var onNewWorktree: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @Environment(AppModel.self) private var appModel
    @State private var renaming = false
    @AppStorage(TerminalTheme.storageKey) private var terminalThemeRaw = TerminalTheme.classic.rawValue
    @AppStorage("sessionDetailReadableMode") private var readableMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .padding(.horizontal, 12).padding(.top, 10)
            terminalBody // full-bleed: the terminal spans the card edge-to-edge
            Text(readableMode
                 ? "select text · tools expand on click · ⇧⇧ next waiting · ⌘P quick command · ⌘B browser · ⌘J/K sessions"
                 : "keys go to the session · ⇧⇧ next waiting · ⌘M checked · ⌘P quick command · ⌘B browser · ⌘J/K sessions · ⌘⏎ expand · ⌘⌫ kill")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            // This is the focused session, so selection wins over needs-you coloring.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(session.needsUser || session.unacknowledged
                              ? Color.accentColor : Color.accentColor.opacity(0.6),
                              lineWidth: session.needsUser || session.unacknowledged ? 2 : 1.5)
        )
        .contextMenu { sessionMenu(rename: { renaming = true }) }
    }

    @ViewBuilder
    private var terminalBody: some View {
        if session.launching {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("starting \(session.agent.rawValue)…").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        } else if let terminal {
            // Full-bleed background, inset text: the same-color padding keeps the terminal
            // reading as edge-to-edge while the content breathes. The workspace wrapper adds
            // the browser split when this session has a visible tab.
            SessionWorkspaceView(session: session) {
                Group {
                    if readableMode {
                        ConversationPaneView(session: session)
                    } else {
                        TerminalPaneView(controller: terminal)
                            .id(terminal.sessionName) // new session → new NSView (updateNSView can't swap it)
                            .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 6)
                            .background(Color(nsColor: (TerminalTheme(rawValue: terminalThemeRaw) ?? .classic).nsBackground))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 340)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .frame(height: 340)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            EmojiBadgeButton(session: session, size: 17)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayName).font(.system(size: 14, weight: .semibold))
                HStack(spacing: 6) {
                    AgentTag(agent: session.agent)
                    if session.customName != nil {
                        // Aliased → keep the real repo · branch visible as context.
                        Text(session.defaultDisplayName)
                            .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            Spacer()
            attentionBadge
            MiniTerminalButton(session: session)
            SessionPresentationPicker(readableMode: $readableMode) {
                DispatchQueue.main.async { terminal?.focus() }
            }
            SessionRenameButton(session: session, show: $renaming)
            if let onDelete {
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .font(.system(size: 11)).help("Kill session (⌘⌫)")
            }
            Text(RelativeTime.short(waitTime)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var attentionBadge: some View {
        switch session.attention {
        case .working: Text("● working").font(.system(size: 11)).foregroundStyle(.blue)
        case .idle: EmptyView()
        case .pending(let a):
            Text(a.kind == .decision ? "⚡ needs decision" : a.kind == .input ? "✎ needs input" : "✓ finished")
                .font(.system(size: 11)).foregroundStyle(.orange)
        }
    }

    private var waitTime: Date {
        if case .pending(let a) = session.attention { return a.receivedAt }
        return session.lastActivity
    }

    @ViewBuilder
    private func sessionMenu(rename: @escaping () -> Void) -> some View {
        if let onMarkChecked {
            Button("Mark Checked") { onMarkChecked() }
                .keyboardShortcut("m", modifiers: .command)
        }
        Button("Rename...") { rename() }
        if let onNewWorktree {
            Button("New Session in Worktree...") { onNewWorktree() }
        }
        Button("Open Mini Terminal") { appModel.miniTerminals.open(for: session) }
        ConfigURLContextMenu(session: session)
        if onDelete != nil { Divider() }
        if let onDelete {
            Button("Delete", role: .destructive) { onDelete() }
                .keyboardShortcut(.delete, modifiers: .command)
        }
    }
}

/// Pencil button + popover for giving a session a custom display name (alias). The alias only
/// changes what pass shows — the folder and tmux session name stay as they are. `show` lives in
/// the row so the hover-revealed button doesn't unmount (closing the popover) when the mouse
/// moves onto the popover itself.
struct SessionRenameButton: View {
    let session: Session
    @Binding var show: Bool
    @Environment(AppModel.self) private var appModel
    @State private var text = ""

    var body: some View {
        Button {
            text = session.customName ?? ""
            show = true
        } label: { Image(systemName: "pencil") }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .font(.system(size: 11))
        .help("Rename (display only)")
        .onChange(of: show) { _, visible in
            if visible { text = session.customName ?? "" }
        }
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Display name").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                TextField(session.defaultDisplayName, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .frame(width: 230)
                    .onChange(of: text) { _, new in appModel.renameSession(session.name, to: new) } // live
                    .onSubmit { show = false }
                HStack {
                    Button("Reset") {
                        text = ""
                        appModel.renameSession(session.name, to: "")
                        show = false
                    }.controlSize(.small)
                    Spacer()
                    Text("pass에서만 표시 · 폴더/tmux 그대로")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            .padding(12)
        }
    }
}

/// A collapsed session row — title + one-line summary + agent tag. Used both as an unfocused
/// row in stack mode and as every row in compact-list mode (where `selected` highlights one).
struct CompactSessionCard: View {
    let session: Session
    var selected: Bool = false
    var onSelect: () -> Void = {}
    var onMarkChecked: (() -> Void)? = nil
    var onNewWorktree: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    /// An agent opened/updated this session's browser page and the user hasn't seen it yet.
    var browserUnseen: Bool = false

    @State private var hovering = false
    @State private var renaming = false
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(spacing: 6) {
            EmojiBadgeButton(session: session, size: 14)
            // Focus-on-tap covers only the text/time area — the badge (a button) owns its own
            // tap, so clicking the emoji opens the picker instead of also moving focus.
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    secondLine
                    AgentTag(agent: session.agent)
                }
                Spacer()
                // Keep the buttons mounted while the rename popover is open — otherwise moving
                // the mouse onto the popover ends the hover and tears the popover down.
                if hovering || renaming {
                    MiniTerminalButton(session: session)
                    SessionRenameButton(session: session, show: $renaming)
                    if let onDelete {
                        Button(action: onDelete) { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .font(.system(size: 11)).help("Kill session (⌘⌫)")
                    }
                }
                if browserUnseen {
                    Image(systemName: "globe").font(.system(size: 10)).foregroundStyle(.blue)
                        .help("Agent opened a page — select the session to view it")
                }
                Text(RelativeTime.short(waitTime)).font(.system(size: 10)).foregroundStyle(urgencyColor)
            }
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
            .onHover { hovering = $0 }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            // Selected rows use the accent border even while waiting; unselected waiting rows
            // keep the needs-you border until the input is answered.
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor :
                              (session.needsUser || session.unacknowledged ? Color.orange : Color.accentColor),
                              lineWidth: session.needsUser || session.unacknowledged ? 1.5 : 1)
                .opacity(selected || session.needsUser || session.unacknowledged ? 1 : 0)
        )
        .contextMenu { sessionMenu(rename: { renaming = true }) }
    }

    @ViewBuilder
    private var secondLine: some View {
        if session.launching {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text("starting \(session.agent.rawValue)…").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } else if case .pending(let a) = session.attention, !isGenericPreview(a.preview) {
            Text(oneLine(a.preview)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        } else if case .pending = session.attention, let tail = session.paneTail, !tail.isEmpty {
            // Generic "needs your input" → show the actual question from the transcript.
            Text(oneLine(tail)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        } else if let tail = session.liveTail, !tail.isEmpty {
            // Streaming right now — show what it's doing (dimmed + a spinner glyph).
            HStack(spacing: 4) {
                Image(systemName: "ellipsis").font(.system(size: 9)).foregroundStyle(.blue)
                Text(oneLine(tail)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        } else if let msg = session.lastMessage, !msg.isEmpty {
            Text(oneLine(msg)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        } else if let tail = session.paneTail, !tail.isEmpty {
            Text(oneLine(tail)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        } else {
            Text("waiting for input").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    private var waitTime: Date {
        if case .pending(let a) = session.attention { return a.receivedAt }
        return session.lastActivity
    }

    @ViewBuilder
    private func sessionMenu(rename: @escaping () -> Void) -> some View {
        if let onMarkChecked {
            Button("Mark Checked") { onMarkChecked() }
                .keyboardShortcut("m", modifiers: .command)
        }
        Button("Rename...") { rename() }
        if let onNewWorktree {
            Button("New Session in Worktree...") { onNewWorktree() }
        }
        Button("Open Mini Terminal") { appModel.miniTerminals.open(for: session) }
        ConfigURLContextMenu(session: session)
        if onDelete != nil { Divider() }
        if let onDelete {
            Button("Delete", role: .destructive) { onDelete() }
                .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    private var urgencyColor: Color {
        guard case .pending(let a) = session.attention, a.kind != .finished else { return .secondary }
        let mins = Date().timeIntervalSince(a.receivedAt) / 60
        if mins > 10 { return .red }
        if mins > 2 { return .orange }
        return .secondary
    }
}

private struct ConfigURLContextMenu: View {
    let session: Session
    @Environment(AppModel.self) private var appModel

    private var items: [PassConfigStore.URLItem] {
        _ = appModel.configRevision
        return PassConfigStore.urls(projectRoot: session.projectRoot)
    }

    var body: some View {
        Menu("URLs") {
            if items.isEmpty {
                Button("No URLs") {}
                    .disabled(true)
            } else {
                ForEach(items) { item in
                    Button(item.label) {
                        appModel.openConfiguredURL(item.url, for: session.name)
                    }
                }
                Divider()
            }
            Button("Add URL...") {
                ConfigURLDialog.addURL(for: session, appModel: appModel)
            }
        }
    }
}

enum PaletteItem: Identifiable {
    case session(Session)
    case project(Project)
    case command(ExtensionStore.PaletteCommand)

    var id: String {
        switch self {
        case .session(let s): return "s:" + s.name
        case .project(let p): return "p:" + p.rootPath
        case .command(let c): return "c:" + c.id
        }
    }
}

struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        Group {
            switch item {
            case .session(let s): sessionRow(s)
            case .project(let p): projectRow(p)
            case .command(let c): commandRow(c)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func sessionRow(_ s: Session) -> some View {
        HStack(spacing: 10) {
            Circle().fill(ProjectColor.color(for: s.projectRoot)).frame(width: 8, height: 8)
            Text(s.agent.glyph).font(.system(size: 13)).frame(width: 16).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                secondLine(s)
            }
            Spacer()
            if s.isAttached {
                Image(systemName: "link").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(RelativeTime.short(waitTime(s))).font(.system(size: 11)).foregroundStyle(urgencyColor(s))
        }
    }

    @ViewBuilder
    private func secondLine(_ s: Session) -> some View {
        if case .pending(let a) = s.attention, !isGenericPreview(a.preview) {
            Text(oneLine(a.preview))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        } else if case .pending = s.attention, let tail = s.paneTail, !tail.isEmpty {
            Text(oneLine(tail))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        } else if let msg = s.lastMessage, !msg.isEmpty {
            Text(oneLine(msg))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        } else if let tail = s.paneTail, !tail.isEmpty {
            Text(oneLine(tail))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        } else {
            Text("waiting for input")
                .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    private func waitTime(_ s: Session) -> Date {
        if case .pending(let a) = s.attention { return a.receivedAt }
        return s.lastActivity
    }

    private func urgencyColor(_ s: Session) -> Color {
        guard case .pending(let a) = s.attention, a.kind != .finished else { return .secondary }
        let mins = Date().timeIntervalSince(a.receivedAt) / 60
        if mins > 10 { return .red }
        if mins > 2 { return .orange }
        return .secondary
    }

    private func projectRow(_ p: Project) -> some View {
        HStack(spacing: 10) {
            Circle().fill(ProjectColor.color(for: p.rootPath)).frame(width: 8, height: 8)
            Image(systemName: "plus.circle").font(.system(size: 12)).frame(width: 16).foregroundStyle(.secondary)
            Text(p.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer()
            Text("new session").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private func commandRow(_ c: ExtensionStore.PaletteCommand) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 12)).frame(width: 16).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.token).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(c.command.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(c.extensionName).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

/// Hook previews like "Claude needs your input" carry no information — cards fall through to
/// the transcript's actual last message instead.
func isGenericPreview(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespaces).lowercased()
    return t.isEmpty || t.contains("needs your input") || t.contains("waiting for your input")
        || t.contains("agent needs input")
}

enum RelativeTime {
    static func short(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
