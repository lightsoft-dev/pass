import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Bridge JSON (mirror of the app's ShareAPI — keep in sync)

struct ShareTargets: Codable {
    struct SessionTarget: Codable, Identifiable {
        var name: String
        var display: String
        var agent: String
        var id: String { name }
    }
    struct ProjectTarget: Codable, Identifiable {
        var root: String
        var name: String
        var id: String { root }
    }
    var sessions: [SessionTarget]
    var projects: [ProjectTarget]
}

struct ShareSendRequest: Codable {
    var session: String?
    var projectRoot: String?
    var note: String?
    var text: String?
    var files: [String]?
}

struct ShareSendResponse: Codable {
    var ok: Bool
    var error: String?
}

/// Must match PassConfig.hookPort in the main app.
private let passPort = 49817

// MARK: - Principal class

/// The OS share sheet target. Collects the shared text/URL/images, lets the user add a note
/// and pick a session (or a project → new session), then hands everything to the running pass
/// app over its loopback server.
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 400))
        preferredContentSize = view.frame.size
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let model = ShareModel(items: items)
        let host = NSHostingController(rootView: ShareComposeView(model: model) { [weak self] ok in
            if ok {
                self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            } else {
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            }
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.width, .height]
        view.addSubview(host.view)
    }
}

// MARK: - Model

@MainActor
final class ShareModel: ObservableObject {
    @Published var text = ""             // shared text and/or URL(s)
    @Published var files: [String] = []  // file paths saved into the pass inbox
    @Published var note = ""
    @Published var targets: ShareTargets?
    @Published var selection = ""        // "s:<session>" or "p:<root>"
    @Published var filter = ""           // live text filter over the target list
    @Published var status: String?
    @Published var sending = false
    @Published var loadFailed = false

    /// Sessions matching the filter (all of them when the filter is empty).
    var filteredSessions: [ShareTargets.SessionTarget] {
        guard let t = targets else { return [] }
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return t.sessions }
        return t.sessions.filter { matches(needle, $0.display) || matches(needle, $0.name) }
    }

    /// Projects (→ new session) only join once a filter narrows them — there are too many
    /// to list unfiltered in a small sheet.
    var filteredProjects: [ShareTargets.ProjectTarget] {
        guard let t = targets else { return [] }
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return Array(t.projects.filter { matches(needle, $0.name) }.prefix(10))
    }

    /// Keep the selection on the top match while typing (Enter-friendly), unless the current
    /// selection still matches.
    func filterChanged() {
        let sessionIDs = filteredSessions.map { "s:" + $0.name }
        let projectIDs = filteredProjects.map { "p:" + $0.root }
        if (sessionIDs + projectIDs).contains(selection) { return }
        selection = sessionIDs.first ?? projectIDs.first ?? ""
    }

    /// Case-insensitive subsequence match ("dpc" hits "dolphin-crm").
    private func matches(_ needle: String, _ hay: String) -> Bool {
        let n = Array(needle.lowercased()), h = Array(hay.lowercased())
        var i = 0
        for ch in h where i < n.count {
            if ch == n[i] { i += 1 }
        }
        return i == n.count
    }

    init(items: [NSExtensionItem]) {
        Task {
            await loadItems(items)
            await loadTargets()
        }
    }

    var canSend: Bool {
        !sending && !selection.isEmpty &&
        !(text.isEmpty && files.isEmpty && note.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: shared items

    private func loadItems(_ items: [NSExtensionItem]) async {
        for item in items {
            for provider in item.attachments ?? [] {
                // Order matters: a shared file is also a URL; a URL is also text.
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    if let url = await loadURL(provider, type: UTType.fileURL.identifier) {
                        stash(fileURL: url)
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let data = await loadData(provider, type: UTType.image.identifier) {
                        stash(data: data, suggested: provider.suggestedName ?? "image.png")
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let url = await loadURL(provider, type: UTType.url.identifier) {
                        appendText(url.absoluteString)
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let s = await loadString(provider) { appendText(s) }
                }
            }
        }
    }

    private func appendText(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        text = text.isEmpty ? t : text + "\n" + t
    }

    /// Copy a shared file into pass's inbox so the path stays valid after the share sheet
    /// (and the source app's temp file) goes away. The agent reads it from there.
    private func stash(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        stash(data: data, suggested: fileURL.lastPathComponent)
    }

    private func stash(data: Data, suggested: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/pass/shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(stamp)-\(suggested)")
        guard (try? data.write(to: url)) != nil else { return }
        files.append(url.path)
    }

    // MARK: item provider plumbing

    private func loadRaw(_ provider: NSItemProvider, type: String) async -> Any? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                cont.resume(returning: item)
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider, type: String) async -> URL? {
        let item = await loadRaw(provider, type: type)
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let s = item as? String { return URL(string: s) }
        return nil
    }

    private func loadString(_ provider: NSItemProvider) async -> String? {
        let item = await loadRaw(provider, type: UTType.plainText.identifier)
        if let s = item as? String { return s }
        if let data = item as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }

    private func loadData(_ provider: NSItemProvider, type: String) async -> Data? {
        let item = await loadRaw(provider, type: type)
        if let data = item as? Data { return data }
        if let url = item as? URL { return try? Data(contentsOf: url) }
        if let image = item as? NSImage { return image.tiffRepresentation }
        return nil
    }

    // MARK: pass bridge

    func loadTargets() async {
        loadFailed = false
        guard let url = URL(string: "http://127.0.0.1:\(passPort)/share/targets") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let t = try? JSONDecoder().decode(ShareTargets.self, from: data) else {
            loadFailed = true
            status = "pass 앱이 실행 중이 아닙니다 — 실행 후 다시 시도하세요"
            return
        }
        targets = t
        status = nil
        if selection.isEmpty {
            if let s = t.sessions.first { selection = "s:" + s.name }
            else if let p = t.projects.first { selection = "p:" + p.root }
        }
    }

    /// Launch pass and retry the target list (the extension can outlive the app).
    func launchPassAndRetry() {
        let url = URL(fileURLWithPath: "/Applications/Pass.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await loadTargets()
        }
    }

    /// POST the payload. Returns true when pass accepted it.
    func send() async -> Bool {
        guard canSend, let url = URL(string: "http://127.0.0.1:\(passPort)/share/send") else { return false }
        sending = true
        defer { sending = false }
        var body = ShareSendRequest(note: note, text: text.isEmpty ? nil : text,
                                    files: files.isEmpty ? nil : files)
        if selection.hasPrefix("s:") { body.session = String(selection.dropFirst(2)) }
        else if selection.hasPrefix("p:") { body.projectRoot = String(selection.dropFirst(2)) }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(body)
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let resp = try? JSONDecoder().decode(ShareSendResponse.self, from: data) else {
            status = "전송 실패 — pass 앱이 실행 중인지 확인하세요"
            return false
        }
        if !resp.ok { status = "⚠ " + (resp.error ?? "전송 실패") }
        return resp.ok
    }
}

// MARK: - UI

struct ShareComposeView: View {
    @ObservedObject var model: ShareModel
    var onDone: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send to pass").font(.headline)

            if !model.text.isEmpty {
                ScrollView {
                    Text(model.text)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 90)
                .padding(8)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if !model.files.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.files, id: \.self) { path in
                        Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "paperclip")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }

            TextField("부가 설명 (선택)", text: $model.note)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))

            picker

            if let status = model.status {
                HStack(spacing: 8) {
                    Text(status).font(.system(size: 11)).foregroundStyle(.orange)
                    if model.loadFailed {
                        Button("pass 실행") { model.launchPassAndRetry() }.controlSize(.small)
                    }
                }
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { onDone(false) }.keyboardShortcut(.cancelAction)
                Button(model.sending ? "Sending…" : "Send") {
                    Task { if await model.send() { onDone(true) } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSend)
            }
        }
        .padding(16)
        .frame(width: 480, height: 400, alignment: .topLeading)
    }

    @ViewBuilder
    private var picker: some View {
        if model.targets != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("세션 검색 — 이름 일부만 쳐도 됩니다", text: $model.filter)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .onChange(of: model.filter) { _, _ in model.filterChanged() }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.filteredSessions) { s in
                            targetRow(id: "s:" + s.name,
                                      title: s.display, subtitle: s.agent, icon: "terminal")
                        }
                        ForEach(model.filteredProjects) { p in
                            targetRow(id: "p:" + p.root,
                                      title: p.name, subtitle: "새 세션", icon: "plus.circle")
                        }
                        if model.filteredSessions.isEmpty && model.filteredProjects.isEmpty {
                            Text("일치하는 대상 없음")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                                .padding(6)
                        }
                    }
                }
                .frame(maxHeight: 130)
            }
        } else if !model.loadFailed {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("세션 목록 불러오는 중…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func targetRow(id: String, title: String, subtitle: String, icon: String) -> some View {
        Button { model.selection = id } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(title).font(.system(size: 12)).lineLimit(1)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                if model.selection == id {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(model.selection == id ? Color.accentColor.opacity(0.14) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
