import SwiftUI
import WebKit

/// One tab's browser pane: a thin toolbar (◀ ▶ ⟳ · URL field · recents · open-external · ✕)
/// over the pooled WKWebView. Keyboard stays terminal-first — this pane takes keys only when
/// clicked or via ⌘L (address field).
struct BrowserPaneView: View {
    let tab: BrowserTab

    @Environment(AppModel.self) private var appModel
    @State private var address = ""
    @State private var addressError: String?
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let addressError {
                Text(addressError)
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.bottom, 4)
            }
            Divider()
            WebViewRepresentable(tab: tab, pool: appModel.webViews)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .onAppear {
            address = displayAddress
            // A blank tab exists to be typed into (⌘B with no page yet) — take the keyboard.
            if address.isEmpty { addressFocused = true }
        }
        // Follow live navigation unless the user is mid-edit in the field.
        .onChange(of: tab.url) { _, _ in if !addressFocused { address = displayAddress } }
        // ⌘L — take the keyboard into the address field (select-all comes free on focus).
        .onChange(of: appModel.browserFocusToken) { _, _ in
            addressFocused = true
        }
    }

    private var displayAddress: String {
        tab.url.absoluteString == "about:blank" ? "" : tab.url.absoluteString
    }

    private var webView: WKWebView? { appModel.webViews?.peek(tab.id) }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { webView?.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(tab.canGoBack ? .primary : .tertiary)
                .disabled(!tab.canGoBack).help("Back")
            Button { webView?.goForward() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain).foregroundStyle(tab.canGoForward ? .primary : .tertiary)
                .disabled(!tab.canGoForward).help("Forward")
            Button { webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Reload")

            TextField("localhost:5173 · foo.com · ./index.html", text: $address)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .focused($addressFocused)
                .onSubmit { commitAddress() }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            if !recents.isEmpty {
                Menu {
                    ForEach(recents, id: \.absoluteString) { url in
                        Button(url.absoluteString) {
                            appModel.browser?.open(url: url, session: tab.sessionName)
                        }
                    }
                } label: {
                    Image(systemName: "clock").font(.system(size: 11))
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Recent pages")
            }
            Button {
                appModel.browser?.expanded.toggle()
            } label: {
                Image(systemName: appModel.browser?.expanded == true
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(appModel.browser?.expanded == true ? "Back to split (⌘⇧B)" : "Expand browser (⌘⇧B)")
            Button {
                if tab.url.absoluteString != "about:blank" { NSWorkspace.shared.open(tab.url) }
            } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Open in default browser")
            Button {
                appModel.browser?.close(session: tab.sessionName)
            } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Close browser (⌘B hides without closing)")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var recents: [URL] {
        appModel.browser?.recentURLs(for: tab.sessionName) ?? []
    }

    private func commitAddress() {
        let cwd = appModel.sessions?.session(named: tab.sessionName)?.cwd
        switch URLNormalizer.normalize(address, fileBase: cwd) {
        case .success(let url):
            addressError = nil
            appModel.browser?.open(url: url, session: tab.sessionName)
            addressFocused = false
        case .failure(let failure):
            addressError = failure.message
        }
    }
}

/// Embeds the pooled webview. `makeNSView` hands out the long-lived view; loads are driven
/// exclusively by BrowserStore.open → WebViewPool.load, never by rendering. Use with
/// `.id(tab.id)` so a different tab mounts a fresh NSView (updateNSView can't swap it —
/// same rule as TerminalPaneView).
struct WebViewRepresentable: NSViewRepresentable {
    let tab: BrowserTab
    let pool: WebViewPool?

    func makeNSView(context: Context) -> WKWebView {
        pool?.webView(for: tab) ?? WKWebView()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
