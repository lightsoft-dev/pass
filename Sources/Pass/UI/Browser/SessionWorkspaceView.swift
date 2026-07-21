import AppKit
import Foundation
import SwiftUI

/// A session's workspace: its terminal, plus — when the session has a visible browser tab —
/// the browser pane in a draggable split beside it (⌘⇧B expands the browser full-width).
/// Wraps every place a terminal renders (home stack card, list/sidebar panel, detail view)
/// so the browser follows the session everywhere. With no tab it IS the terminal — zero cost.
struct SessionWorkspaceView<Terminal: View>: View {
    let session: Session
    let terminal: Terminal

    @Environment(AppModel.self) private var appModel
    /// Browser's share of the width (0.2…0.8), persisted like the panel size.
    @AppStorage("browser.split") private var browserFraction = 0.45

    init(session: Session, @ViewBuilder terminal: () -> Terminal) {
        self.session = session
        self.terminal = terminal()
    }

    private var tab: BrowserTab? { appModel.browser?.visibleTab(for: session.name) }
    private var configuredURLs: [PassConfigStore.URLItem] {
        _ = appModel.configRevision
        return PassConfigStore.urls(projectRoot: session.projectRoot)
    }
    private var hasProjectConfig: Bool {
        _ = appModel.configRevision
        return PassConfigStore.exists(projectRoot: session.projectRoot)
    }

    var body: some View {
        if let tab {
            if appModel.browser?.expanded == true {
                BrowserPaneView(tab: tab).id(tab.id)
            } else {
                split(tab)
            }
        } else {
            terminalWithURLBar
        }
    }

    private func split(_ tab: BrowserTab) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                terminalWithURLBar
                    .frame(width: terminalWidth(total: geo.size.width))
                divider(total: geo.size.width)
                BrowserPaneView(tab: tab)
                    .id(tab.id) // different tab → fresh NSView (updateNSView can't swap it)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .coordinateSpace(name: "workspace")
        }
    }

    private func terminalWidth(total: CGFloat) -> CGFloat {
        max(120, total * (1 - browserFraction) - dividerWidth)
    }

    @ViewBuilder
    private var terminalWithURLBar: some View {
        let urls = configuredURLs
        if urls.isEmpty && !hasProjectConfig {
            terminal
        } else {
            VStack(spacing: 0) {
                ConfigURLBar(session: session, items: urls) { item in
                    appModel.openConfiguredURL(item.url, for: session.name)
                }
                terminal
            }
        }
    }

    private let dividerWidth: CGFloat = 7

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.05))
            .frame(width: dividerWidth)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.25))
                    .frame(width: 2, height: 28)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("workspace"))
                    .onChanged { value in
                        guard total > 0 else { return }
                        browserFraction = min(0.8, max(0.2, 1 - value.location.x / total))
                    }
            )
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}

private struct ConfigURLBar: View {
    let session: Session
    let items: [PassConfigStore.URLItem]
    let open: (PassConfigStore.URLItem) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ConfigURLAddButton(session: session)

                ForEach(items) { item in
                    Button {
                        open(item)
                    } label: {
                        HStack(spacing: 4) {
                            FaviconView(url: item.url)
                            Text(item.label)
                                .lineLimit(1)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .background(Color.primary.opacity(0.055))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .help(item.url.absoluteString)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 1)
        }
    }
}

private struct FaviconView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: url.isFileURL ? "doc" : "globe")
                    .font(.system(size: 9))
            }
        }
        .frame(width: 12, height: 12)
        .task(id: url.absoluteString) {
            guard !url.isFileURL else { return }
            image = await FaviconLoader.image(for: url)
        }
    }
}

@MainActor
private enum FaviconLoader {
    private static var images: [String: NSImage] = [:]
    private static var misses = Set<String>()

    static func image(for pageURL: URL) async -> NSImage? {
        guard let origin = originURL(for: pageURL) else { return nil }
        let key = origin.absoluteString
        if let image = images[key] { return image }
        if misses.contains(key) { return nil }

        for candidate in await candidates(for: pageURL, origin: origin) {
            if let image = await loadImage(from: candidate) {
                images[key] = image
                return image
            }
        }

        misses.insert(key)
        return nil
    }

    private static func candidates(for pageURL: URL, origin: URL) async -> [URL] {
        var result = await linkedIconURLs(from: pageURL)
        result.append(origin.appendingPathComponent("favicon.ico"))

        var seen = Set<String>()
        return result.filter { url in
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
            return seen.insert(url.absoluteString).inserted
        }
    }

    private static func linkedIconURLs(from pageURL: URL) async -> [URL] {
        guard let html = await fetchText(from: pageURL) else { return [] }
        return linkTags(in: html).compactMap { tag in
            guard tag.range(of: "icon", options: [.caseInsensitive]) != nil,
                  let href = attribute("href", in: tag) else { return nil }
            return URL(string: href, relativeTo: pageURL)?.absoluteURL
        }
    }

    private static func loadImage(from url: URL) async -> NSImage? {
        guard let data = await fetchData(from: url, maxBytes: 2_000_000) else { return nil }
        return NSImage(data: data)
    }

    private static func fetchText(from url: URL) async -> String? {
        guard let data = await fetchData(from: url, maxBytes: 500_000) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func fetchData(from url: URL, maxBytes: Int) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              data.count <= maxBytes,
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        return data
    }

    private static func originURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        return components.url
    }

    private static func linkTags(in html: String) -> [String] {
        matches(#"<link\b[^>]*>"#, in: html)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b\#(name)\s*=\s*["']([^"']+)["']"#
        return matches(pattern, in: tag, group: 1).first
    }

    private static func matches(_ pattern: String, in string: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.matches(in: string, range: range).compactMap { match in
            guard let matchRange = Range(match.range(at: group), in: string) else { return nil }
            return String(string[matchRange])
        }
    }
}
