import Foundation
import Observation

/// State of pass's embedded browser: which page each session has open, which sessions have an
/// unseen agent-opened page (🌐 badge), and the per-session recall list of recent URLs.
/// Tabs are pure data — the heavy WKWebViews live in WebViewPool (UI layer); AppModel wires
/// `onTabClosed` so closing/pruning here releases the webview there.
@MainActor
@Observable
final class BrowserStore {
    private(set) var tabs: [BrowserTab] = []
    /// Each session's active tab (v1: at most one).
    private(set) var activeTabBySession: [String: UUID] = [:]
    /// Sessions where an agent opened/updated a page the user hasn't looked at yet.
    private(set) var unseenBySession: Set<String> = []
    /// Sessions whose split the user explicitly hid with ⌘B (an open() un-hides).
    private(set) var hiddenSessions: Set<String> = []
    /// Recent URLs per session — the toolbar's recall menu (no tab strip in v1).
    private(set) var recentURLsBySession: [String: [URL]] = [:]
    /// ⌘⇧B — browser temporarily takes the whole workspace (terminal collapsed).
    var expanded = false

    /// Wired by AppModel to WebViewPool.drop — releases the webview of a closed tab.
    var onTabClosed: ((UUID) -> Void)?
    /// Wired by AppModel to WebViewPool.load — (re)navigates the webview after open().
    var onTabOpened: ((BrowserTab) -> Void)?

    private let persisting: Bool
    private var saveTask: Task<Void, Never>?
    private static let maxRecents = 20

    init(persisting: Bool = true) {
        self.persisting = persisting
        guard persisting else { return }
        // Restore each session's last page as a (not-unseen) tab; the webview loads lazily
        // when the split first renders. Dead sessions get pruned on the first reconcile.
        for (session, urlString) in SessionStatePersistence.load().browserURLs ?? [:] {
            guard let url = URL(string: urlString) else { continue }
            let tab = BrowserTab(id: UUID(), sessionName: session, url: url,
                                 title: nil, lastVisited: .distantPast)
            tabs.append(tab)
            activeTabBySession[session] = tab.id
        }
    }

    // MARK: Queries

    func tab(for session: String) -> BrowserTab? {
        guard let id = activeTabBySession[session] else { return nil }
        return tabs.first { $0.id == id }
    }

    func tab(id: UUID) -> BrowserTab? {
        tabs.first { $0.id == id }
    }

    /// The tab the workspace split should render — nil while the user has it hidden (⌘B).
    func visibleTab(for session: String) -> BrowserTab? {
        guard !hiddenSessions.contains(session) else { return nil }
        return tab(for: session)
    }

    func recentURLs(for session: String) -> [URL] {
        recentURLsBySession[session] ?? []
    }

    func hasUnseen(_ session: String) -> Bool {
        unseenBySession.contains(session)
    }

    // MARK: Mutations

    /// Open (or replace — v1 always reuses) the session's active tab. `markUnseen` is set by
    /// the CLI path when it decides not to surface (target not selected / --background).
    @discardableResult
    func open(url: URL, session: String, markUnseen: Bool = false) -> BrowserTab {
        var tab: BrowserTab
        if let id = activeTabBySession[session], let idx = tabs.firstIndex(where: { $0.id == id }) {
            tabs[idx].url = url
            tabs[idx].title = nil
            tabs[idx].lastVisited = Date()
            tab = tabs[idx]
        } else {
            tab = BrowserTab(id: UUID(), sessionName: session, url: url, title: nil, lastVisited: Date())
            tabs.append(tab)
            activeTabBySession[session] = tab.id
        }
        hiddenSessions.remove(session) // an explicit open always re-shows the split
        if markUnseen { unseenBySession.insert(session) } else { unseenBySession.remove(session) }
        rememberRecent(url, session: session)
        scheduleSave()
        onTabOpened?(tab)
        Log.app.info("browser open \(url.absoluteString, privacy: .public) session=\(session, privacy: .public)")
        return tab
    }

    /// Close the session's active tab (✕ button, `passcli browser close`, session death).
    func close(session: String) {
        guard let id = activeTabBySession.removeValue(forKey: session) else { return }
        tabs.removeAll { $0.id == id }
        unseenBySession.remove(session)
        hiddenSessions.remove(session)
        scheduleSave()
        onTabClosed?(id)
    }

    /// ⌘B — hide/show the split for a session that has a tab. Returns false when there is no
    /// tab yet (the caller opens a blank one and focuses the address bar instead).
    @discardableResult
    func toggleHidden(session: String) -> Bool {
        guard activeTabBySession[session] != nil else { return false }
        if hiddenSessions.contains(session) { hiddenSessions.remove(session) }
        else { hiddenSessions.insert(session) }
        return true
    }

    /// The user is looking at this session's workspace — clear its 🌐 badge.
    func markSeen(_ session: String) {
        unseenBySession.remove(session)
    }

    /// Un-hide the split without navigating (screenshot needs the pane mounted to render;
    /// unlike open() this doesn't touch the URL, the badge, or the recents).
    func reveal(_ session: String) {
        hiddenSessions.remove(session)
    }

    /// Mirror navigation facts from the live webview (didCommit/didFinish/KVO in WebViewPool).
    func mirror(tabId: UUID, url: URL?, title: String?, canGoBack: Bool, canGoForward: Bool) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        if let url { tabs[idx].url = url }
        tabs[idx].title = title
        tabs[idx].canGoBack = canGoBack
        tabs[idx].canGoForward = canGoForward
        tabs[idx].lastVisited = Date()
        if let url { rememberRecent(url, session: tabs[idx].sessionName) }
        scheduleSave()
    }

    /// Drop tabs whose sessions no longer exist (wired to SessionStore.onReconciled).
    func pruneSessions(alive: Set<String>) {
        let dead = activeTabBySession.keys.filter { !alive.contains($0) }
        for session in dead { close(session: session) }
        recentURLsBySession = recentURLsBySession.filter { alive.contains($0.key) }
    }

    // MARK: Recents + persistence

    private func rememberRecent(_ url: URL, session: String) {
        guard url.absoluteString != "about:blank" else { return }
        var list = recentURLsBySession[session] ?? []
        list.removeAll { $0 == url }
        list.insert(url, at: 0)
        if list.count > Self.maxRecents { list.removeLast(list.count - Self.maxRecents) }
        recentURLsBySession[session] = list
    }

    /// Debounced load-modify-save of the shared snapshot — only the browserURLs field is
    /// ours; everything else belongs to SessionStore and must pass through untouched.
    private func scheduleSave() {
        guard persisting else { return }
        saveTask?.cancel()
        var urls: [String: String] = [:]
        for (session, id) in activeTabBySession {
            if let t = tabs.first(where: { $0.id == id }), !t.url.absoluteString.isEmpty,
               t.url.absoluteString != "about:blank" {
                urls[session] = t.url.absoluteString
            }
        }
        saveTask = Task { [urls] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            var snap = SessionStatePersistence.load()
            snap.browserURLs = urls
            SessionStatePersistence.save(snap)
        }
    }
}
