import SwiftUI

/// Root of the floating panel — a chat-style home over every session, with the SELECTED
/// session shown as a live terminal: a real `tmux attach` client (colors, styles, cursor),
/// so every keystroke goes straight into the agent's TUI and all of its features work.
/// ⌘J summons a centered message bar (`@` jump, `+branch` worktree, plain text replies);
/// ⌘↑↓ moves between sessions; ⌘⏎ expands the session full-height.
struct CommandView: View {
    @Environment(AppModel.self) private var appModel
    @State private var route: Route = .list
    @State private var query: String = ""
    @State private var selection: Int = 0             // home cursor (over orderedSessions)
    @State private var jumpSelection: Int = 0         // cursor inside the @ jump results
    @State private var status: String?
    @State private var pendingKill: Session?          // session awaiting a kill confirmation
    @State private var showQuickCommand = false       // ⌘J quick command (hidden by default)
    @State private var newSessionMode = false         // ⌘N: results are PROJECTS, ⏎ starts a session
    @State private var terminal: TerminalController?  // live client attached to the selected session
    @State private var terminalTarget: String?        // which session the home terminal shows
    @State private var pool = TerminalPool()          // recent clients stay attached → instant switching
    @FocusState private var omniboxFocused: Bool
    @AppStorage("homeMode") private var homeModeRaw = HomeMode.stack.rawValue

    enum Route: Equatable {
        case list
        case detail(String)                  // a session's full-height terminal (back → list)
        case specs(String?)                  // spec documents, optionally pinned to a project
        case specSession(String, String)     // session opened FROM specs (name, projectRoot)
    }

    private var homeMode: HomeMode { HomeMode(rawValue: homeModeRaw) ?? .stack }
    private var sessions: [Session] { appModel.sessions?.sessions ?? [] }
    private var projects: [Project] { appModel.projects?.projects ?? [] }
    /// Anything typed in the quick command searches — no `@` needed (a leading `@` still works
    /// and is simply stripped). Only `+branch` (worktree) opts out.
    private var isJumpMode: Bool { !query.isEmpty && !query.hasPrefix("+") }

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
    /// The centered quick command is up: summoned with ⌘J, or forced when there's no session
    /// yet (creating one is the only possible action). It hides after sending a message, or
    /// with another ⌘J — Esc never dismisses it (nor the panel).
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
        content
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
                case .specs, .detail: route = .list; focusSoon()
                case .list: break
                }
            }
            .onChange(of: appModel.forceOpenSession) { _, s in
                if let s { route = .detail(s) }
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
            let root = s.git?.projectRoot ?? s.projectRoot
            let existing = sessions.filter { $0.projectRoot == root && $0.git?.isLinkedWorktree == true }.count
            status = nil
            newSessionMode = false
            showQuickCommand = true
            query = "+wt-\(existing + 1)"
            refocusField()
            return true
        case .up:
            if e.command { navMove(-1); return true }
            if isJumpMode || (newSessionMode && typingInBar) { moveJump(-1); return true }
            return false // terminal (or the bar's text cursor) gets plain arrows
        case .down:
            if e.command { navMove(1); return true }
            if isJumpMode || (newSessionMode && typingInBar) { moveJump(1); return true }
            return false
        case .tab:
            // Tab autocompletes the '@' token to the top match, then leaves a trailing space so
            // you can keep typing a message: "@iv" → "@ivma " → "@ivma xx 작업 부탁해". While
            // typing in the bar, swallow it (no responder-chain hop); otherwise the terminal
            // gets real Tabs (TUI completion).
            if isJumpMode { completeJump(); return true }
            return typingInBar
        case .nextWaiting:
            // ⇧⇧ — hop to the next session waiting on you (cycling).
            guard !isJumpMode else { return true }
            return jumpToNextWaiting()
        case .returnKey:
            if newSessionMode {
                if case .project(let p)? = jumpSelectedItem {
                    appModel.createSession(projectDir: p.rootPath)
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
                }
                return true
            }
            if e.command { openSelectedTerminal(); return true }
            guard typingInBar else { return false } // plain ⏎ goes into the terminal
            if query.hasPrefix("+") { createWorktreeFromInput() } // stays up: shows progress/errors
            else if !sessions.isEmpty { hideQuickCommand() } // empty ⏎ → back to the terminal
            return true
        case .delete:
            // ⌘⌫ → confirm killing the selected session.
            if let s = selectedSession { pendingKill = s }
            return true
        case .escape:
            if pendingKill != nil { pendingKill = nil; return true }
            if typingInBar {
                if !query.isEmpty { query = "" } // clear the draft; the quick command stays up
                return true // Esc never closes the quick command (send a message or ⌘J)
            }
            // The terminal owns Esc (interrupting the agent). Close the panel with ⌘⌘/⌥Space.
            return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .list:
            listMode
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
            // ⌘J — the shared message bar floats centered over the home (Spotlight-style).
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

    // MARK: Centered message bar (⌘J)

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
                        : query.hasPrefix("+") ? "arrow.triangle.branch" : "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundStyle(newSessionMode || isJumpMode || query.hasPrefix("+")
                                     ? Color.accentColor : .secondary)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($omniboxFocused)
                    .onChange(of: query) { old, new in handleQueryChange(old: old, new: new) }
                    // Tab completes the @-token here — the field editor eats Tab before
                    // performKeyEquivalent sees it, so intercept it at the SwiftUI layer.
                    .onKeyPress(.tab) {
                        if isJumpMode { completeJump(); return .handled }
                        return .ignored
                    }
                    .onAppear { refocusField() } // grab focus the instant this field mounts
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

    @ViewBuilder
    private var jumpResults: some View {
        if jumpItems.isEmpty {
            Text(selectedSession.map { "No matches — ⏎ sends this to \($0.displayName)" }
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
            if case .project(let p)? = jumpSelectedItem { return "⏎ new session in \(p.name)" }
            return "type a project name · ⏎ start a session · Esc clear"
        }
        if query.hasPrefix("+") {
            let branch = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
            return branch.isEmpty ? "⏎ new git worktree + session (name the branch)"
                                  : "⏎ create worktree “\(branch)” + session"
        }
        if isJumpMode {
            if jumpItems.isEmpty, let s = selectedSession {
                return "no matches — ⏎ sends this to \(s.displayName)"
            }
            if case .project(let p)? = jumpSelectedItem { return "⏎ new session in \(p.name)" }
            if jumpMessageIsReady, case .session(let s)? = jumpSelectedItem {
                return "⏎ send to \(s.displayName)"
            }
            return "Tab complete · ⏎ go to session · keep typing to message it"
        }
        return "type to search · first word filters, the rest is the message · +branch"
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
                                               onDelete: { pendingKill = s },
                                               onSpecs: { route = .specs(s.projectRoot) })
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
                                        onDelete: { pendingKill = s },
                                        onSpecs: { route = .specs(s.projectRoot) }
                                    )
                                } else {
                                    CompactSessionCard(session: s, onSelect: { selection = idx })
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
            return
        }
        let name = terminalKey
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
        if !showQuickCommand {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { controller.focus() }
        }
    }

    /// The compact-list mode terminal strip: the selected session's live client + a key hint.
    private var terminalPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let live = displayedTerminal {
                TerminalPaneView(controller: live)
                    .id(live.sessionName) // new session → new NSView (updateNSView can't swap it)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
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
            Text("keys go to the session · ⇧⇧ next waiting · ⌘J quick command · ⌘↑↓ sessions · ⌘⏎ expand · ⌘⌫ kill")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
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
        return out
    }

    // MARK: Keyboard

    /// ↑↓ inside the @ jump results.
    private func moveJump(_ delta: Int) {
        guard !jumpItems.isEmpty else { return }
        jumpSelection = max(0, min(jumpItems.count - 1, jumpSelection + delta))
    }

    /// ⌘↑↓ session navigation. Abandon an in-progress message draft when moving to another
    /// session; in @ jump mode, keep the filter text (plain arrows move the result cursor).
    private func navMove(_ delta: Int) {
        if !isJumpMode { query = "" }
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
        if isJumpMode { jumpSelection = 0 } // filtering always re-selects the top match
    }

    /// ⌘J — show/hide the quick command. Hiding it hands the keyboard back to the terminal.
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

    /// A `+branch` message spins off a git worktree of the focused session's project and starts
    /// a new session in it (same agent). The rest of the text is the branch name.
    private func createWorktreeFromInput() {
        guard let s = selectedSession else { return }
        let branch = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard !branch.isEmpty else { return }
        let root = s.git?.projectRoot ?? s.projectRoot
        query = ""
        status = "⧉ creating worktree \(branch)…"
        Task {
            let err = await appModel.createWorktreeSession(fromProjectRoot: root, branch: branch, agent: s.agent)
            status = err.map { "⚠ worktree: \($0)" }  // nil → clears the status on success
        }
    }

    private func activate(_ item: PaletteItem) {
        switch item {
        case .session(let s):
            jumpToSession(s)
        case .project(let p):
            appModel.createSession(projectDir: p.rootPath); query = ""
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

    /// Where the cursor lands when the panel opens: on the waiting session nearest the input
    /// (bottom of the queue) so you can act on it immediately, else the top.
    private func initialSelection() -> Int {
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
/// shared message bar (⌘J) handles send-without-focus; the card itself is all terminal.
struct FocusedSessionCard: View {
    let session: Session
    var terminal: TerminalController?
    var onDelete: (() -> Void)? = nil
    var onSpecs: (() -> Void)? = nil

    @State private var renaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            terminalBody
            Text("keys go to the session · ⇧⇧ next waiting · ⌘J quick command · ⌘↑↓ sessions · ⌘⏎ expand · ⌘⌫ kill")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            // Focused → accent border. An unchecked needs-you request → a stronger orange one
            // takes over and stays until the user opens or acts on the session.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(session.unacknowledged ? Color.orange : Color.accentColor.opacity(0.6),
                              lineWidth: session.unacknowledged ? 2 : 1.5)
        )
    }

    @ViewBuilder
    private var terminalBody: some View {
        if session.launching {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("starting \(session.agent.rawValue)…").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        } else if let terminal {
            TerminalPaneView(controller: terminal)
                .id(terminal.sessionName) // new session → new NSView (updateNSView can't swap it)
                .frame(maxWidth: .infinity)
                .frame(height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.06)))
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
            if let onSpecs {
                Button(action: onSpecs) { Image(systemName: "doc.text") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .font(.system(size: 11)).help("Project spec document (⌘D)")
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
    var onDelete: (() -> Void)? = nil
    var onSpecs: (() -> Void)? = nil

    @State private var hovering = false
    @State private var renaming = false

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
                    if let onSpecs {
                        Button(action: onSpecs) { Image(systemName: "doc.text") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .font(.system(size: 11)).help("Project spec document (⌘D)")
                    }
                    SessionRenameButton(session: session, show: $renaming)
                    if let onDelete {
                        Button(action: onDelete) { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .font(.system(size: 11)).help("Kill session (⌘⌫)")
                    }
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
            // Unchecked needs-you request → orange border (even collapsed), until the user checks
            // it; else the selected row gets an accent border so you can see which the input targets.
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(session.unacknowledged ? Color.orange : Color.accentColor,
                              lineWidth: session.unacknowledged ? 1.5 : 1)
                .opacity(session.unacknowledged ? 1 : (selected ? 1 : 0))
        )
    }

    @ViewBuilder
    private var secondLine: some View {
        if session.launching {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text("starting \(session.agent.rawValue)…").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } else if case .pending(let a) = session.attention {
            Text(oneLine(a.preview)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
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

    private var urgencyColor: Color {
        guard case .pending(let a) = session.attention, a.kind != .finished else { return .secondary }
        let mins = Date().timeIntervalSince(a.receivedAt) / 60
        if mins > 10 { return .red }
        if mins > 2 { return .orange }
        return .secondary
    }
}

enum PaletteItem: Identifiable {
    case session(Session)
    case project(Project)

    var id: String {
        switch self {
        case .session(let s): return "s:" + s.name
        case .project(let p): return "p:" + p.rootPath
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
        if case .pending(let a) = s.attention {
            Text(oneLine(a.preview))
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
