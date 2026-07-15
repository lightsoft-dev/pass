import AppKit
import WebKit

/// WKWebView that behaves inside the non-activating, movable-by-background summon panel:
/// first-mouse clicks must reach the page (the app is usually "inactive" while the panel is
/// used — same rule as IMETerminalView), and drags on the page must not move the window.
final class BrowserWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Keeps the heavy WKWebViews alive for the tabs most recently on screen (LRU, small cap) —
/// the same principle as TerminalPool: tabs are cheap data in BrowserStore, webviews are
/// processes. Evicted webviews reload from the tab's URL next time they're shown (back/forward
/// history is lost — documented in BROWSER.md §7.2).
@MainActor
final class WebViewPool {
    /// One process pool for all webviews; the app-scoped persistent data store (separate from
    /// Safari) so logins survive relaunches. Settings offers "clear website data".
    private static let processPool = WKProcessPool()

    private var views: [UUID: WKWebView] = [:]
    private var coordinators: [UUID: WebViewCoordinator] = [:]
    private var order: [UUID] = [] // LRU — most recently used last
    private let capacity = 4

    weak var store: BrowserStore?

    /// The live webview for a tab, creating (and starting its load) if needed.
    func webView(for tab: BrowserTab) -> WKWebView {
        if let wv = views[tab.id] {
            touch(tab.id)
            return wv
        }
        let config = WKWebViewConfiguration()
        config.processPool = Self.processPool
        config.websiteDataStore = .default()
        let wv = BrowserWebView(frame: .zero, configuration: config)
        wv.isInspectable = true // right-click → Inspect Element (dev tool, not automation)
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        let coordinator = WebViewCoordinator(tabId: tab.id, pool: self)
        wv.navigationDelegate = coordinator
        wv.uiDelegate = coordinator
        coordinator.observe(wv)
        views[tab.id] = wv
        coordinators[tab.id] = coordinator
        touch(tab.id)
        while order.count > capacity, let victim = order.first(where: { $0 != tab.id }) {
            drop(victim)
        }
        navigate(wv, to: tab.url)
        return wv
    }

    /// Ensure the tab's webview exists and shows the tab's commanded URL. Called by
    /// BrowserStore.onTabOpened — the ONLY thing that triggers loads; rendering just attaches.
    func load(_ tab: BrowserTab) {
        let existed = views[tab.id] != nil
        let wv = webView(for: tab) // creating already starts the load
        // The webview may sit elsewhere (user clicked links) — an explicit open always
        // (re)navigates; re-opening the page already on screen is a no-op (no flicker).
        if existed, wv.url != tab.url {
            navigate(wv, to: tab.url)
        }
    }

    /// The pooled webview, if alive — no creation, no LRU touch.
    func peek(_ id: UUID?) -> WKWebView? {
        guard let id else { return nil }
        return views[id]
    }

    func drop(_ id: UUID) {
        order.removeAll { $0 == id }
        views.removeValue(forKey: id)?.stopLoading()
        coordinators.removeValue(forKey: id)
    }

    func prune(keeping live: Set<UUID>) {
        for id in views.keys where !live.contains(id) { drop(id) }
    }

    // MARK: Observation verbs (the /cli endpoints — BROWSER.md §5.4)

    /// Wait until the tab's webview finished loading (bounded). Polling keeps this trivially
    /// leak-free versus juggling continuations in the delegate.
    func awaitLoaded(_ id: UUID, timeoutMs: Int = 5000) async {
        guard let wv = views[id] else { return }
        try? await Task.sleep(for: .milliseconds(150)) // let a just-issued load() land
        var waited = 150
        while wv.isLoading, waited < timeoutMs {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 100
        }
    }

    /// Viewport PNG of the tab (S6.2: a hidden panel may yield stale/blank output — the CLI
    /// path surfaces the panel before calling this).
    func snapshotPNG(_ id: UUID) async -> Data? {
        guard let wv = views[id] else { return nil }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let image: NSImage? = await withCheckedContinuation { cont in
            wv.takeSnapshot(with: config) { image, error in
                if let error {
                    Log.app.error("browser snapshot failed: \(error.localizedDescription, privacy: .public)")
                }
                cont.resume(returning: image)
            }
        }
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = image.size
        return rep.representation(using: .png, properties: [:])
    }

    /// The page as text (innerText) or markup (outerHTML) — read-only observation; pass has
    /// no JS-injection verb by design (BROWSER.md §1 non-goals).
    func readContent(_ id: UUID, html: Bool) async -> String? {
        guard let wv = views[id] else { return nil }
        let js = html ? "document.documentElement.outerHTML" : "document.body.innerText"
        return await withCheckedContinuation { cont in
            wv.evaluateJavaScript(js) { result, error in
                if let error {
                    Log.app.error("browser read failed: \(error.localizedDescription, privacy: .public)")
                }
                cont.resume(returning: result as? String)
            }
        }
    }

    /// Settings → "Clear browser website data" (cookies, storage, caches of the app store).
    static func clearWebsiteData() async {
        await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) { cont.resume() }
        }
    }

    // MARK: internals

    fileprivate func mirrorFromWebView(_ id: UUID) {
        guard let wv = views[id] else { return }
        store?.mirror(tabId: id, url: wv.url, title: wv.title,
                      canGoBack: wv.canGoBack, canGoForward: wv.canGoForward)
    }

    private func navigate(_ wv: WKWebView, to url: URL) {
        if url.isFileURL {
            // Directory read access so relative assets (css/js next to the file) resolve.
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            wv.load(URLRequest(url: url))
        }
    }

    private func touch(_ id: UUID) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}

/// Per-webview delegate: mirrors navigation facts into BrowserStore, keeps the pane
/// http/https/file-only (other schemes → the OS), sends non-renderable responses and
/// target=_blank to sane places, and answers JS dialogs natively. Deliberately NOT the
/// panel's key-event path — the terminal keeps keyboard ownership (BROWSER.md §4.3).
private final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let tabId: UUID
    private weak var pool: WebViewPool?
    private var observations: [NSKeyValueObservation] = []

    init(tabId: UUID, pool: WebViewPool) {
        self.tabId = tabId
        self.pool = pool
    }

    func observe(_ wv: WKWebView) {
        observations = [
            wv.observe(\.title, options: [.new]) { [weak self] _, _ in self?.mirror() },
            wv.observe(\.url, options: [.new]) { [weak self] _, _ in self?.mirror() },
            wv.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.mirror() },
            wv.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.mirror() },
        ]
    }

    /// KVO and delegate callbacks all arrive on the main thread for WKWebView — hop the
    /// isolation checker accordingly.
    private func mirror() {
        MainActor.assumeIsolated { pool?.mirrorFromWebView(tabId) }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        // mailto:, vscode://, zoommtg:// … → hand to the OS; the pane stays web-only.
        if !["http", "https", "file", "about", "blob", "data"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // v1 has no download UI — anything the webview can't render goes to the default browser.
        if !navigationResponse.canShowMIMEType, let url = navigationResponse.response.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { mirror() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { mirror() }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        Log.app.error("browser load failed: \(error.localizedDescription, privacy: .public)")
        mirror()
    }

    // MARK: WKUIDelegate

    /// target=_blank — v1 has one page per session: load it in place.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
}
