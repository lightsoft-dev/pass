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
            Divider()
            omnibox
        }
        .onAppear { focusSoon() }
        .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape]) { press in
            handleListKey(press)
        }
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
        if isJumpMode { return "⏎ open · ⌥⏎ new session" }
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
        } else {
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

    private func handleListKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow: move(-1); return .handled
        case .downArrow: move(1); return .handled
        case .return:
            if press.modifiers.contains(.command) { openSelectedTerminal(); return .handled }
            if press.modifiers.contains(.option), isJumpMode { newFromSelected(); return .handled }
            if isJumpMode {
                if items.indices.contains(selection) { activate(items[selection]) }
            } else if !query.isEmpty {
                sendReplyToSelected()
            } else {
                openSelectedTerminal()
            }
            return .handled
        case .escape:
            if !query.isEmpty { query = ""; return .handled }
            return .ignored // let the panel close
        default:
            return .ignored
        }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = max(0, min(items.count - 1, selection + delta))
    }

    /// The omnibox is always focused, so it swallows printable keys before onKeyPress sees an
    /// empty query. Detect the empty→single-char transition here: y/n answer a selected
    /// decision (fast path); everything else becomes reply/jump text.
    private func handleQueryChange(old: String, new: String) {
        if old.isEmpty, new.count == 1, let cmd = new.first, cmd == "y" || cmd == "n",
           let s = selectedSession, case .pending(let a) = s.attention, a.kind == .decision {
            appModel.decide(s.name, cmd == "y" ? .allowOnce : .deny)
            query = ""
            return
        }
        status = nil
        if isJumpMode || new.isEmpty { selection = min(selection, max(0, items.count - 1)) }
    }

    private func openSelectedTerminal() {
        guard let s = selectedSession else { return }
        omniboxFocused = false
        route = .detail(s.name)
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
        DispatchQueue.main.async { omniboxFocused = true; selection = 0 }
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
