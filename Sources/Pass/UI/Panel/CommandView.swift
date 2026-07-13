import SwiftUI

/// Root of the floating panel — a chat-style home: a feed of every session with its last
/// response on top, and one input pinned at the bottom. Plain text replies to the selected
/// session; `@` jumps to a project/session; ⏎ on an empty box (or ⌘⏎) opens its terminal.
struct CommandView: View {
    @Environment(AppModel.self) private var appModel
    @State private var route: Route = .list
    @State private var query: String = ""
    @State private var selection: Int = 0
    @State private var status: String?
    @State private var options: [DecisionOption] = []
    @State private var optionPrompt: String = ""  // the question text above a numbered menu
    @State private var paneMirror: String = ""    // live tmux snapshot for the awaiting session
    @State private var mirrorCols: Int = 92       // terminal columns that fit the mirror's width
    @State private var pendingKill: Session?      // session awaiting a kill confirmation
    @FocusState private var omniboxFocused: Bool
    @AppStorage("homeMode") private var homeModeRaw = HomeMode.stack.rawValue

    enum Route: Equatable {
        case list
        case features
        case feature(projectRoot: String, id: String)
        case featureSession(name: String, projectRoot: String, id: String)
        case detail(String)
    }

    private var homeMode: HomeMode { HomeMode(rawValue: homeModeRaw) ?? .stack }
    private var sessions: [Session] { appModel.sessions?.sessions ?? [] }
    private var projects: [Project] { appModel.projects?.projects ?? [] }
    private var isJumpMode: Bool { query.hasPrefix("@") }

    // A jump query is `@<token> <message>`: the token (up to the first space) filters/selects a
    // session; anything after the first space is a message to send to it. Tab completes the token.
    private var jumpRaw: String { isJumpMode ? String(query.dropFirst()) : "" }
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
    /// A numbered menu is genuinely on the selected session's screen (the ❯ cursor marks a real
    /// menu, not a numbered list in prose) → arrow keys and ⏎ drive it. Keyed off the live pane,
    /// not hook state, so it works even when a Notification hook was missed.
    private var menuActive: Bool {
        guard !isJumpMode, selectedSession != nil else { return false }
        return options.contains(where: \.highlighted)
    }
    /// The bottom omnibox is shown for @ jump, when there's no session to attach a card input
    /// to, and in compact-list mode (where the single input lives at the bottom).
    private var showsBottomInput: Bool { isJumpMode || sessions.isEmpty || homeMode == .list }

    private var selectedSession: Session? {
        guard items.indices.contains(selection), case .session(let s) = items[selection] else { return nil }
        return s
    }

    private var selectedProject: Project? {
        guard items.indices.contains(selection), case .project(let p) = items[selection] else { return nil }
        return p
    }

    /// The session order the home renders — chat-room style in every mode: sessions you need to
    /// respond to cluster at the BOTTOM, nearest the input. The oldest-waiting one sits at the
    /// very bottom (next to handle); newer arrivals stack above it; the rest stay up top by
    /// recency. Handling one drops it back up top.
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
                route = .list
                query = ""
                focusSoon()
            }
            .onChange(of: appModel.backToken) { _, _ in
                switch route {
                case .feature(let root, let id), .featureSession(_, let root, let id):
                    route = .feature(projectRoot: root, id: id)
                case .features, .detail:
                    route = .list; focusSoon()
                case .list:
                    break
                }
            }
            .onChange(of: appModel.forceOpenSession) { _, s in
                if let s { route = .detail(s) }
            }
            // Keep `selection` on the same session when the home list reorders (e.g. one becomes
            // pending and drops to the bottom cluster in list mode) — so the input never silently
            // retargets to a different session mid-reply.
            .onChange(of: orderedSessions.map(\.id)) { old, new in
                guard !isJumpMode, old.indices.contains(selection) else { return }
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
    /// — reliable regardless of which SwiftUI control currently holds focus; SwiftUI's
    /// `.onKeyPress` alone can miss events after a mouse click moves real first-responder
    /// status away from what FocusState thinks is focused). Returns false to let the key fall
    /// through — e.g. so a real terminal (route == .detail) gets its own arrow keys, or so
    /// Escape can still close the panel.
    private func handleNav(_ e: PanelNavEvent) -> Bool {
        guard route == .list else { return false }
        switch e.key {
        // Key scheme: ⌘↑↓ moves between sessions; PLAIN ↑↓ drives the awaiting session's menu
        // (falling through to the text cursor when no menu is up). Jump mode keeps plain arrows
        // for its result list, Spotlight-style.
        case .up:
            if e.command || isJumpMode { navMove(-1); return true }
            if menuActive, let s = selectedSession { appModel.sendMenuKey(s.name, "Up"); return true }
            return false // no menu → let the text field move its cursor
        case .down:
            if e.command || isJumpMode { navMove(1); return true }
            if menuActive, let s = selectedSession { appModel.sendMenuKey(s.name, "Down"); return true }
            return false
        case .tab:
            // Tab autocompletes the '@' token to the top match, then leaves a trailing space so
            // you can keep typing a message: "@iv" → "@ivma " → "@ivma xx 작업 부탁해". Outside
            // jump mode, swallow it so focus stays in the input (no responder-chain hop).
            if isJumpMode { completeJump() }
            return true
        case .returnKey:
            if isJumpMode {
                guard items.indices.contains(selection) else { return true }
                switch items[selection] {
                case .session(let s):
                    if e.command { route = .detail(s.name) }        // ⌘⏎ dive into the terminal
                    else if jumpMessageIsReady { sendJumpMessage(to: s) } // "@name msg" ⏎ → send
                    else { jumpToSession(s) }                        // "@name" ⏎ → focus in stack
                case .project(let p):
                    // Agent choice lives in the menu bar (New session ▸) — rarely needed, so the
                    // fast path here always starts the default agent.
                    appModel.createSession(projectDir: p.rootPath); query = ""  // ⏎ start it
                }
                return true
            }
            if e.command { openSelectedTerminal(); return true }
            if query.hasPrefix("+") { createWorktreeFromInput() }
            else if !query.isEmpty { sendReplyToSelected() }
            else if menuActive, let s = selectedSession { appModel.sendMenuKey(s.name, "Enter") } // confirm menu choice
            else { openSelectedTerminal() }
            return true
        case .delete:
            // ⌘⌫ → confirm killing the selected session.
            if let s = selectedSession { pendingKill = s }
            return true
        case .escape:
            if pendingKill != nil { pendingKill = nil; return true }
            if !query.isEmpty { query = ""; return true }
            return false // let the panel close
        }
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .list:
            listMode
        case .features:
            FeatureLibraryView(
                onBack: { route = .list; focusSoon() },
                onOpen: { root, id in route = .feature(projectRoot: root, id: id) }
            )
        case .feature(let projectRoot, let id):
            if let document = appModel.features?.document(projectRoot: projectRoot, id: id) {
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
            if let session = sessions.first(where: { $0.name == name }) {
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
        }
    }

    // MARK: List mode

    private var listMode: some View {
        VStack(spacing: 0) {
            if appModel.needsHookInstall { hookBanner }
            HStack {
                Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                Text("Sessions").font(.system(size: 13, weight: .semibold))
                Spacer()
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
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            listBody
            // In stack mode the input lives inside the focused card (moves with focus/click,
            // since selection often happens by mouse). Otherwise the input sits at the bottom.
            if showsBottomInput {
                // Compact-list mode has no big card, so surface the selected session's numbered
                // choices right above the input (number key / click still pick them).
                if homeMode == .list && !isJumpMode && !paneMirror.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        PaneMirror(text: paneMirror, onWidth: { mirrorCols = colsFor(width: $0) })
                            .frame(maxHeight: 280)
                        Text(menuActive
                             ? "↑↓ ⏎ drive the menu · number picks · ⌘↑↓ sessions · ⌘⏎ open"
                             : "mirroring terminal · type to reply · ⌘⏎ to open")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14).padding(.top, 8)
                }
                Divider()
                omnibox
            }
        }
        .onAppear { focusSoon() }
        // Scrape numbered choices for the focused/selected session while it's waiting on you —
        // runs in both home modes (stack card + list strip both read `options`).
        .task(id: optionPollKey) { await pollOptions() }
    }

    private var omnibox: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: isJumpMode ? "at.circle.fill" : "arrow.turn.down.right")
                    .foregroundStyle(isJumpMode ? Color.accentColor : .secondary)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
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
            if let status {
                Text(status).font(.system(size: 10)).foregroundStyle(.orange)
            } else {
                Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var placeholder: String {
        if isJumpMode { return "jump — Tab to complete, then type a message" }
        if let s = selectedSession { return "reply to \(s.displayName) · ⏎ to send" }
        return "@ to jump · type to reply"
    }

    private var hint: String {
        if isJumpMode {
            if let p = selectedProject { return "⏎ new session in \(p.name)" }
            if jumpMessageIsReady, let s = selectedSession { return "⏎ send to \(s.displayName)" }
            return "Tab complete · ⏎ go to session · ⌘⏎ terminal"
        }
        if selectedSession != nil { return "⏎ send reply · ⌘↑↓ sessions · ⌘⏎ terminal · @ jump · +branch" }
        return "@ jump to a project"
    }

    @ViewBuilder
    private var listBody: some View {
        if appModel.sessions?.tmuxMissing == true {
            message("exclamationmark.triangle", "tmux not found",
                    "Install tmux (brew install tmux) and reopen pass.")
        } else if items.isEmpty {
            message("bubble.left.and.bubble.right",
                    isJumpMode ? "No matches" : "No sessions yet",
                    isJumpMode ? "Try a different name." : "@ to start one, or use New session… from the menu bar.")
        } else if isJumpMode {
            // Jump mode: uniform filtered rows (sessions + creatable projects).
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            PaletteRow(item: item, selected: idx == selection)
                                .contentShape(Rectangle())
                                .onTapGesture { selection = idx; activate(item) }
                        }
                    }
                    .padding(8)
                }
                // Scroll by element id (stable) — indices shift when the list reorders.
                .onChange(of: selection) { _, sel in
                    guard items.indices.contains(sel) else { return }
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(items[sel].id, anchor: .center) }
                }
            }
        } else if homeMode == .list {
            // Compact list: every session is a uniform row; the selected one is highlighted and
            // the single bottom omnibox replies to it. Arrow keys / clicks move the selection.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(orderedSessions.enumerated()), id: \.element.id) { idx, s in
                            CompactSessionCard(session: s, selected: idx == selection,
                                               onSelect: { selection = idx },
                                               onDelete: { pendingKill = s })
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
            // Home: one big focused card (full last response + its own reply input) + small
            // rows for the rest. Arrow keys or a click move focus. Plain VStack (not Lazy) —
            // LazyVStack fails to re-layout a row whose size changes purely from `selection`
            // (external state), not from the row's own data changing.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(orderedSessions.enumerated()), id: \.element.id) { idx, s in
                            Group {
                                if idx == selection {
                                    FocusedSessionCard(
                                        session: s, query: $query, status: status,
                                        options: options, optionPrompt: optionPrompt,
                                        mirror: paneMirror,
                                        onMirrorWidth: { mirrorCols = colsFor(width: $0) },
                                        fieldFocus: $omniboxFocused,
                                        onQueryChange: handleQueryChange,
                                        onPick: { appModel.pickOption(s.name, $0) },
                                        onDelete: { pendingKill = s }
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
                    // NOTE: do NOT clear `query` here — this fires for programmatic selection
                    // changes too (e.g. jump mode resets selection=0), which would wipe the
                    // "@…" filter and kick you out of search. Drafts are cleared explicitly on
                    // stack arrow-nav instead (handleNav).
                    // The focused card is a fresh view instance (its own TextField), so real
                    // AppKit focus doesn't carry over — re-assert it.
                    refocusField()
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

    // MARK: Filtered items

    /// Home feed shows ALL sessions (each with its last response). `@` switches to jump/filter
    /// mode over sessions + registered projects.
    private var items: [PaletteItem] {
        isJumpMode ? filteredItems(jumpToken) : orderedSessions.map { .session($0) }
    }

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

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = max(0, min(items.count - 1, selection + delta))
    }

    /// Arrow-key navigation. In the home stack, abandon an in-progress reply draft when moving
    /// to another card; in @ jump mode, keep the filter text (arrows move the result cursor).
    private func navMove(_ delta: Int) {
        if !isJumpMode { query = "" }
        move(delta)
    }

    /// The omnibox is always focused, so it swallows printable keys before onKeyPress sees an
    /// empty query. Detect the empty→single-char transition here: a digit picks a shown option,
    /// y/n answer a plain permission; everything else becomes reply/jump text.
    private func handleQueryChange(old: String, new: String) {
        if old.isEmpty, new.count == 1, let ch = new.first, let s = selectedSession {
            // Number key → pick the matching option shown on the card.
            if let n = ch.wholeNumberValue, options.contains(where: { $0.number == n }) {
                appModel.pickOption(s.name, n)
                query = ""
                return
            }
            // y/n → answer a plain permission prompt (when no explicit option list is shown).
            if options.isEmpty, ch == "y" || ch == "n",
               case .pending(let a) = s.attention, a.kind == .decision {
                appModel.decide(s.name, ch == "y" ? .allowOnce : .deny)
                query = ""
                return
            }
        }
        status = nil
        // Entering/leaving @ jump mode swaps which input is on screen (the focused card's
        // reply field ↔ the bottom filter field). onAppear on each field grabs focus, but
        // fire refocus here too as a backup for the transition.
        if old.hasPrefix("@") != new.hasPrefix("@") { refocusField() }
        if isJumpMode {
            selection = 0 // filtering always re-selects the top match
        } else if new.isEmpty {
            selection = min(selection, max(0, items.count - 1))
        }
    }

    // MARK: Option polling (numbered choices on the focused card)

    /// Restarts the poll when the focused session changes. Polls WHICHEVER session is selected —
    /// mirror/menu detection reads the live pane, so a session that's really waiting shows its
    /// terminal even if a Notification hook was dropped and pass's state is stale.
    private var optionPollKey: String {
        guard !isJumpMode, let s = selectedSession else { return "idle" }
        return s.name
    }

    private func pollOptions() async {
        guard optionPollKey != "idle", let name = selectedSession?.name else {
            options = []; optionPrompt = ""; paneMirror = ""; return
        }
        // Render the TUI at exactly the width that fits the mirror (no-op while a real terminal
        // is attached — the attached client's size wins). Re-applied whenever the panel is
        // resized so the mirrored TUI always fills the card edge-to-edge.
        var sizedCols = 0
        while !Task.isCancelled {
            if sizedCols != mirrorCols {
                await TmuxClient.shared.resizeWindow(name, cols: mirrorCols, rows: 30)
                sizedCols = mirrorCols
            }
            let pane = await TmuxClient.shared.capturePane(name, colors: false)
            let parsed = DecisionParser.parse(pane)
            options = parsed
            optionPrompt = parsed.isEmpty ? "" : (DecisionParser.prompt(pane) ?? "")
            // Mirror when the session needs the user (hook state) OR a real menu is on screen
            // (❯-marked) — reality wins over possibly-stale hook state.
            let waiting = sessions.first(where: { $0.name == name })?.needsUser == true
            let menuOnScreen = parsed.contains(where: \.highlighted)
            paneMirror = (waiting || menuOnScreen) ? mirrorText(pane) : ""
            try? await Task.sleep(for: .milliseconds(250)) // snappy so arrow moves reflect quickly
        }
    }

    /// How many terminal columns fit a given mirror width — drives the tmux resize so the
    /// mirrored TUI renders exactly as wide as the card.
    private func colsFor(width: CGFloat) -> Int {
        max(40, min(400, Int((width - 18) / PaneMirror.charWidth)))
    }

    /// The whole visible pane (blank edges trimmed) — a live mirror of the agent's terminal
    /// while it waits on you. The view pins to the bottom; scroll up for earlier context.
    private func mirrorText(_ pane: String) -> String {
        var lines = pane.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return lines.suffix(40).joined(separator: "\n") // bound size if an attached client made it huge
    }

    private func openSelectedTerminal() {
        guard let s = selectedSession else { return }
        omniboxFocused = false
        route = .detail(s.name)
    }

    /// Leave @ jump mode and focus the chosen session's card in the home stack.
    private func jumpToSession(_ s: Session) {
        query = "" // exits jump mode
        if let idx = orderedSessions.firstIndex(where: { $0.name == s.name }) { selection = idx }
        refocusField()
    }

    /// Tab: replace the '@' token with the top match's name, keep any typed message, add a
    /// trailing space so typing continues into the message.
    private func completeJump() {
        guard let top = items.first else { return }
        let token: String
        switch top {
        case .session(let s): token = jumpCompletionToken(s)
        case .project(let p): token = Slug.make(p.name)
        }
        let msg = jumpMessage ?? ""
        query = "@" + token + " " + msg
        selection = 0
        FieldEditorFix.cursorToEnd() // keep typing at the end of the message
    }

    /// A session's short '@' token: its tmux name minus the "pass-" prefix (e.g. pass-ivma → ivma).
    private func jumpCompletionToken(_ s: Session) -> String {
        s.name.hasPrefix(PassConfig.sessionPrefix)
            ? String(s.name.dropFirst(PassConfig.sessionPrefix.count))
            : s.name
    }

    /// "@name message" + ⏎ → send the message straight to that session, then land on it.
    private func sendJumpMessage(to s: Session) {
        let text = (jumpMessage ?? "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { jumpToSession(s); return }
        query = "" // exits jump mode
        if let idx = orderedSessions.firstIndex(where: { $0.name == s.name }) { selection = idx }
        Task {
            let r = await appModel.reply(to: s.name, text: text)
            if case .refusedShell = r { status = "⚠ \(s.displayName): agent not running — ⌘⏎ to open terminal" }
        }
        refocusField()
    }

    private func sendReplyToSelected() {
        guard let s = selectedSession else { return }
        let text = query
        query = ""
        Task {
            let r = await appModel.reply(to: s.name, text: text)
            if case .refusedShell = r { status = "⚠ \(s.displayName): agent not running — ⌘⏎ to open terminal" }
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
            omniboxFocused = false
            route = .detail(s.name)
        case .project(let p):
            appModel.createSession(projectDir: p.rootPath); query = ""
        }
    }

    private func newFromSelected() {
        if case .project(let p)? = items.indices.contains(selection) ? items[selection] : nil {
            appModel.createSession(projectDir: p.rootPath); query = ""
        } else if let s = selectedSession {
            appModel.createSession(projectDir: s.projectRoot); query = ""
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
        refocusField()
    }

    /// Where the cursor lands when the panel opens: on the waiting session nearest the input
    /// (bottom of the queue) so you can act on it immediately, else the top.
    private func initialSelection() -> Int {
        if let i = orderedSessions.lastIndex(where: { $0.needsUser }) { return i }
        return 0
    }

    /// Move keyboard focus to the (possibly freshly mounted) focused card's input. Forces a
    /// false→true transition: setting `omniboxFocused = true` when it is ALREADY true is a
    /// no-op, so after arrowing/clicking between cards SwiftUI wouldn't move focus to the new
    /// card's newly-mounted TextField without this reset.
    private func refocusField() {
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

/// The focused session in the home stack — shown large, with its full pending ask or last
/// response readable at a glance, PLUS its own reply/jump input pinned to the card (the input
/// travels with focus — including mouse clicks between cards — rather than staying fixed at
/// the window bottom). Highlighted border marks it as keyboard-focused.
struct FocusedSessionCard: View {
    let session: Session
    @Binding var query: String
    let status: String?
    var options: [DecisionOption] = []
    var optionPrompt: String = ""
    var mirror: String = ""
    var onMirrorWidth: (CGFloat) -> Void = { _ in }
    let fieldFocus: FocusState<Bool>.Binding
    let onQueryChange: (_ old: String, _ new: String) -> Void
    var onPick: (Int) -> Void = { _ in }
    var onDelete: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !mirror.isEmpty {
                // Awaiting you → mirror the agent's actual terminal instead of a GUI. Drive it with
                // the arrows/⏎ (or a number key); ⌘⏎ opens the real thing.
                PaneMirror(text: mirror, onWidth: onMirrorWidth).frame(maxHeight: 320)
                Text(options.isEmpty
                     ? "mirroring terminal · type below to reply · ⌘⏎ to open"
                     : "↑↓ ⏎ drive the menu · number picks · ⌘↑↓ sessions · ⌘⏎ open")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                content
                    .frame(minHeight: 70, maxHeight: 220, alignment: .top)
                if !options.isEmpty { OptionsView(options: options, onPick: onPick) }
            }
            Divider()
            inputRow
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

    // While this card is visible, query never starts with '@' — typing '@' flips the whole
    // home view to jump mode (a flat filtered list with its own bottom omnibox), unmounting
    // this card. A leading '+' stays here though: it means "spin off a worktree" — the icon and
    // hint switch to reflect that.
    private var isWorktree: Bool { query.hasPrefix("+") }

    private var inputRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: isWorktree ? "arrow.triangle.branch" : "arrow.turn.down.right")
                    .foregroundStyle(isWorktree ? Color.accentColor : .secondary)
                    .font(.system(size: 12))
                TextField("reply · ⏎ to send", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused(fieldFocus)
                    .onChange(of: query) { old, new in onQueryChange(old, new) }
                    .onAppear {
                        // Grab focus when this card's input mounts (e.g. arrowing to a new
                        // card, or leaving @ jump mode). Force a false→true transition.
                        fieldFocus.wrappedValue = false
                        DispatchQueue.main.async {
                            fieldFocus.wrappedValue = true
                            FieldEditorFix.cursorToEnd()
                        }
                    }
            }
            Group {
                if let status {
                    Text(status).foregroundStyle(.orange)
                } else if isWorktree {
                    let branch = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
                    Text(branch.isEmpty ? "⏎ new git worktree + session (name the branch)"
                                        : "⏎ create worktree on branch “\(branch)” + session")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("⏎ send · ⌘↑↓ sessions · ⌘⏎ terminal · @ jump · +branch").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10))
        }
    }

    @State private var renaming = false

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
            Text(a.kind == .decision ? "⚡ y allow · n deny" : a.kind == .input ? "✎ needs input" : "✓ finished")
                .font(.system(size: 11)).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var content: some View {
        if session.launching {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("starting \(session.agent.rawValue)…").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                Text(bodyText)
                    .font(.system(size: 13))
                    .foregroundStyle(bodyText == placeholderText ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private var placeholderText: String { "no response yet — say something below" }

    private var bodyText: String {
        if !optionPrompt.isEmpty { return optionPrompt }                      // numbered-choice question
        if case .pending(let a) = session.attention, !a.preview.isEmpty { return a.preview }
        if let tail = session.liveTail, !tail.isEmpty { return "… " + tail }  // streaming now
        if let msg = session.lastMessage, !msg.isEmpty { return msg }
        if let tail = session.paneTail, !tail.isEmpty { return tail }         // pane fallback
        return placeholderText
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

/// A read-only mirror of the awaiting session's tmux pane — shows the agent's actual terminal
/// (question + options as rendered) instead of a reconstructed GUI. Monospaced; scrolls both
/// ways since the pane is wider than the card.
struct PaneMirror: View {
    let text: String
    /// Reports the mirror's rendered width so the poller can resize the tmux window to exactly
    /// as many columns as fit — the mirrored TUI then fills the card edge-to-edge.
    var onWidth: ((CGFloat) -> Void)? = nil

    /// Width of one monospaced cell at the mirror's font size.
    static let charWidth: CGFloat =
        ("M" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]).width

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize()               // don't wrap — scroll horizontally instead
                    .padding(8)
                    .id("mirror")
            }
            // Pin to the bottom (where the prompt/menu lives); re-pin only when content actually
            // changes, so reading scrolled-up context isn't yanked away while the pane is static.
            .onAppear { proxy.scrollTo("mirror", anchor: .bottom) }
            .onChange(of: text) { _, _ in proxy.scrollTo("mirror", anchor: .bottom) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.06)))
        .background(GeometryReader { g in
            Color.clear
                .onAppear { onWidth?(g.size.width) }
                .onChange(of: g.size.width) { _, w in onWidth?(w) }
        })
    }
}

/// Numbered choices scraped from a pending session's pane (permission dialog / AskUserQuestion)
/// — pick with a number key or a click, without opening the terminal. Shared by the focused
/// card (stack mode) and the strip above the omnibox (compact-list mode).
struct OptionsView: View {
    let options: [DecisionOption]
    var onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(options) { opt in
                Button { onPick(opt.number) } label: {
                    HStack(spacing: 8) {
                        Text("\(opt.number)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(opt.highlighted ? Color.accentColor : .secondary)
                            .frame(width: 16)
                        Text(opt.label)
                            .font(.system(size: 12))
                            .foregroundStyle(opt.highlighted ? .primary : .secondary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(opt.highlighted ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            Text("press a number to choose")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
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
            Text("no response yet").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
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
            if selected, case .pending(let a) = s.attention, a.kind == .decision {
                Text("y allow · n deny").font(.system(size: 10)).foregroundStyle(.orange)
            } else if s.isAttached {
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
            Text("no response yet")
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
