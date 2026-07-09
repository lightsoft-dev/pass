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
    @FocusState private var omniboxFocused: Bool

    enum Route: Equatable { case list, detail(String) }

    private var sessions: [Session] { appModel.sessions?.sessions ?? [] }
    private var projects: [Project] { appModel.projects?.projects ?? [] }
    private var isJumpMode: Bool { query.hasPrefix("@") }

    private var selectedSession: Session? {
        guard items.indices.contains(selection), case .session(let s) = items[selection] else { return nil }
        return s
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
                if route != .list { route = .list; focusSoon() }
            }
            .onChange(of: appModel.forceOpenSession) { _, s in
                if let s { route = .detail(s) }
            }
            .onAppear { appModel.keyHandler = handleNav }
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
        case .up: navMove(-1); return true
        case .down: navMove(1); return true
        case .returnKey:
            if isJumpMode {
                guard items.indices.contains(selection) else { return true }
                switch items[selection] {
                case .session(let s):
                    if e.command { route = .detail(s.name) }  // ⌘⏎ dive into the terminal
                    else { jumpToSession(s) }                  // ⏎ focus it in the home stack
                case .project(let p):
                    appModel.createSession(projectDir: p.rootPath); query = ""  // ⏎/⌥⏎ start it
                }
                return true
            }
            if e.command { openSelectedTerminal(); return true }
            if !query.isEmpty { sendReplyToSelected() } else { openSelectedTerminal() }
            return true
        case .escape:
            if !query.isEmpty { query = ""; return true }
            return false // let the panel close
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
        }
    }

    // MARK: List mode

    private var listMode: some View {
        VStack(spacing: 0) {
            if appModel.needsHookInstall { hookBanner }
            listBody
            // In stack mode the input lives inside the focused card (moves with focus/click,
            // since selection often happens by mouse). This bottom bar only appears for jump
            // mode (@ search) or when there's no session yet to attach an input to.
            if isJumpMode || sessions.isEmpty {
                Divider()
                omnibox
            }
        }
        .onAppear { focusSoon() }
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
        if isJumpMode { return "jump to a project or session" }
        if let s = selectedSession { return "reply to \(s.displayName) · ⏎ to send" }
        return "@ to jump · type to reply"
    }

    private var hint: String {
        if isJumpMode { return "⏎ go to session · ⌘⏎ open terminal · ⌥⏎ new" }
        if selectedSession != nil { return "⏎ send reply · ⌘⏎ open terminal · @ jump" }
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
                                .id(idx)
                                .contentShape(Rectangle())
                                .onTapGesture { selection = idx; activate(item) }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selection) { _, s in withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(s, anchor: .center) } }
            }
        } else {
            // Home: one big focused card (full last response + its own reply input) + small
            // rows for the rest. Arrow keys or a click move focus. Plain VStack (not Lazy) —
            // LazyVStack fails to re-layout a row whose size changes purely from `selection`
            // (external state), not from the row's own data changing.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { idx, s in
                            if idx == selection {
                                FocusedSessionCard(
                                    session: s, query: $query, status: status,
                                    options: options,
                                    fieldFocus: $omniboxFocused,
                                    onQueryChange: handleQueryChange,
                                    onPick: { appModel.pickOption(s.name, $0) }
                                )
                                .id(idx)
                            } else {
                                CompactSessionCard(session: s)
                                    .id(idx)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selection = idx }
                            }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selection) { _, s in
                    // NOTE: do NOT clear `query` here — this fires for programmatic selection
                    // changes too (e.g. jump mode resets selection=0), which would wipe the
                    // "@…" filter and kick you out of search. Drafts are cleared explicitly on
                    // stack arrow-nav instead (handleNav).
                    // The focused card is a fresh view instance (its own TextField), so real
                    // AppKit focus doesn't carry over — re-assert it.
                    refocusField()
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(s, anchor: .center) }
                }
                // Scrape numbered choices for the focused session while it's waiting on you,
                // so you can pick from the card (number key / click) without opening a terminal.
                .task(id: optionPollKey) { await pollOptions() }
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
        isJumpMode ? filteredItems(query) : sessions.map { .session($0) }
    }

    private func filteredItems(_ query: String) -> [PaletteItem] {
        let needle = (query.hasPrefix("@") ? String(query.dropFirst()) : query)
            .trimmingCharacters(in: .whitespaces)

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

    /// Restarts the poll when the focused session — or whether it's awaiting you — changes.
    private var optionPollKey: String {
        guard let s = selectedSession, case .pending(let a) = s.attention, a.kind != .finished
        else { return "idle" }
        return s.name
    }

    private func pollOptions() async {
        guard let name = selectedSession?.name, optionPollKey != "idle" else {
            options = []; return
        }
        while !Task.isCancelled {
            let pane = await TmuxClient.shared.capturePane(name, colors: false)
            options = DecisionParser.parse(pane)
            try? await Task.sleep(for: .milliseconds(600))
        }
    }

    private func openSelectedTerminal() {
        guard let s = selectedSession else { return }
        omniboxFocused = false
        route = .detail(s.name)
    }

    /// Leave @ jump mode and focus the chosen session's card in the home stack.
    private func jumpToSession(_ s: Session) {
        query = "" // exits jump mode
        if let idx = sessions.firstIndex(where: { $0.name == s.name }) { selection = idx }
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
        selection = 0
        refocusField()
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
    let fieldFocus: FocusState<Bool>.Binding
    let onQueryChange: (_ old: String, _ new: String) -> Void
    var onPick: (Int) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
                .frame(minHeight: 70, maxHeight: 220, alignment: .top)
            if !options.isEmpty { optionList }
            Divider()
            inputRow
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
        )
    }

    /// Numbered choices scraped from the pane (permission dialog / AskUserQuestion) — pick with
    /// a number key or a click, without opening the terminal.
    private var optionList: some View {
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

    // While this card is visible, query never starts with '@' — typing '@' flips the whole
    // home view to jump mode (a flat filtered list with its own bottom omnibox), unmounting
    // this card. So this input only ever needs to speak "reply" placeholder/hint.
    private var inputRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(.secondary)
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
                } else {
                    Text("⏎ send reply · ⌘⏎ open terminal · @ jump").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            SessionBadge(session: session, size: 17).frame(width: 20)
            Text(session.agent.glyph).font(.system(size: 14)).foregroundStyle(.secondary)
            Text(session.displayName).font(.system(size: 14, weight: .semibold))
            Spacer()
            attentionBadge
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
        ScrollView {
            Text(bodyText)
                .font(.system(size: 13))
                .foregroundStyle(bodyText == placeholderText ? .tertiary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var placeholderText: String { "no response yet — say something below" }

    private var bodyText: String {
        if case .pending(let a) = session.attention, !a.preview.isEmpty { return a.preview }
        if let tail = session.liveTail, !tail.isEmpty { return "… " + tail }  // streaming now
        if let msg = session.lastMessage, !msg.isEmpty { return msg }
        return placeholderText
    }

    private var waitTime: Date {
        if case .pending(let a) = session.attention { return a.receivedAt }
        return session.lastActivity
    }
}

/// A collapsed, unfocused session in the home stack — title + one-line summary.
struct CompactSessionCard: View {
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            SessionBadge(session: session, size: 14).frame(width: 18)
            Text(session.agent.glyph).font(.system(size: 12)).frame(width: 14).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                secondLine
            }
            Spacer()
            Text(RelativeTime.short(waitTime)).font(.system(size: 10)).foregroundStyle(urgencyColor)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var secondLine: some View {
        if case .pending(let a) = session.attention {
            Text(oneLine(a.preview)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        } else if let tail = session.liveTail, !tail.isEmpty {
            // Streaming right now — show what it's doing (dimmed + a spinner glyph).
            HStack(spacing: 4) {
                Image(systemName: "ellipsis").font(.system(size: 9)).foregroundStyle(.blue)
                Text(oneLine(tail)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        } else if let msg = session.lastMessage, !msg.isEmpty {
            Text(oneLine(msg)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
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
