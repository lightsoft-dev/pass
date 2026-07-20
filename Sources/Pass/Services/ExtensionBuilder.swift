import Foundation
import Observation

/// One AI-assisted extension build. The extension folder remains the source of truth; this
/// record only keeps the human goal, the agent session, and review workflow state so Settings
/// can recover after it closes or the app restarts.
struct ExtensionBuild: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case generating
        case reworking
        case needsReview
        case approved

        var label: String {
            switch self {
            case .generating: return "Generating"
            case .reworking: return "Reworking"
            case .needsReview: return "Needs review"
            case .approved: return "Enabled"
            }
        }
    }

    var extensionId: String
    var goal: String
    var sessionName: String?
    var status: Status
    var summary: String?
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date

    var id: String { extensionId }
}

/// A bounded, read-only snapshot shown before the user enables generated code.
struct ExtensionBuildReview: Hashable, Sendable {
    struct File: Hashable, Identifiable, Sendable {
        var path: String
        var byteCount: Int
        var content: String?
        var note: String?
        var id: String { path }
    }

    var extensionId: String
    var name: String?
    var permissions: [String]
    var commands: [String]
    var eventTriggers: [String]
    var windows: [String]
    var namedActions: [String]
    var problems: [String]
    var files: [File]
    var fingerprint: String
    var canApprove: Bool { problems.isEmpty && name != nil }
}

/// Settings → natural-language goal → isolated Claude session → review → explicit enable.
/// The builder never enables an extension on the agent's behalf. Generated files are inert
/// until `approve` records a fingerprint through ExtensionStore's normal approval path.
@MainActor
@Observable
final class ExtensionBuilder {
    enum ActionResult: Equatable {
        case success(String)
        case failure(String)
    }

    private(set) var builds: [ExtensionBuild] = []
    private(set) var reviews: [String: ExtensionBuildReview] = [:]

    private let store: ExtensionStore
    private let sessions: SessionStore
    private let stateURL: URL
    private let fileManager: FileManager

    private struct Snapshot: Codable { var builds: [ExtensionBuild] }

    init(store: ExtensionStore, sessions: SessionStore,
         stateURL: URL = PassConfig.stateDirectory.appendingPathComponent("extension-builds.json"),
         fileManager: FileManager = .default) {
        self.store = store
        self.sessions = sessions
        self.stateURL = stateURL
        self.fileManager = fileManager
        load()
    }

    /// Create a new, still-disabled extension folder and start the normal pass-managed Claude
    /// agent inside it. No manifest is pre-trusted and no generated action can run at this stage.
    func create(extensionId rawId: String, goal rawGoal: String) async -> ActionResult {
        let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = rawGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ExtensionManifest.isValidIdentifier(id) else {
            return .failure("ID must use lowercase letters, digits, and '-' (and cannot start with '-').")
        }
        guard !goal.isEmpty else { return .failure("Describe what the extension should do.") }

        let root = store.revealDirectory()
        let directory = root.appendingPathComponent(id, isDirectory: true)
        guard !fileManager.fileExists(atPath: directory.path) else {
            return .failure("An extension folder named '\(id)' already exists.")
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch {
            return .failure("Could not create the extension folder: \(error.localizedDescription)")
        }

        let now = Date()
        builds.removeAll { $0.extensionId == id }
        builds.insert(ExtensionBuild(extensionId: id, goal: goal, status: .generating,
                                     createdAt: now, updatedAt: now), at: 0)
        persist()

        let name = await sessions.createSession(
            projectDir: directory.path,
            agent: .claude,
            initialPrompt: generationPrompt(extensionId: id, goal: goal, directory: directory),
            rememberProject: false)
        sessions.setAlias(name, "Build extension · \(id)")
        update(id) {
            $0.sessionName = name
            $0.updatedAt = Date()
        }
        return .success(name)
    }

    /// Stop is the reliable completion boundary for Claude sessions. A manual Refresh in the
    /// review UI calls the same path, covering missing hooks or a Stop received while pass was off.
    func attentionPending(sessionName: String, attention: Attention) {
        guard attention.kind == .finished,
              let build = builds.first(where: { $0.sessionName == sessionName }),
              build.status != .approved else { return }
        refreshReview(extensionId: build.extensionId)
    }

    /// Re-read every generated file and run the same manifest validation used by the runtime.
    /// Invalid output still enters review so the human can see the exact errors and ask for rework.
    func refreshReview(extensionId: String) {
        guard builds.contains(where: { $0.extensionId == extensionId }) else { return }
        let directory = store.revealDirectory().appendingPathComponent(extensionId, isDirectory: true)
        let manifestURL = directory.appendingPathComponent("extension.json")
        var manifest: ExtensionManifest?
        var problems: [String] = []
        let manifestAttributes = try? fileManager.attributesOfItem(atPath: manifestURL.path)
        let manifestBytes = (manifestAttributes?[.size] as? NSNumber)?.intValue ?? 0
        if manifestBytes > 1024 * 1024 {
            problems = ["extension.json is larger than 1 MB"]
        } else if let data = try? Data(contentsOf: manifestURL) {
            do {
                let decoded = try JSONDecoder().decode(ExtensionManifest.self, from: data)
                manifest = decoded
                problems = decoded.problems(directory: directory, fileManager: fileManager)
            } catch {
                problems = ["extension.json: \(error.localizedDescription)"]
            }
        } else {
            problems = ["extension.json is missing or unreadable"]
        }

        let inspection = Self.inspectFiles(in: directory, fileManager: fileManager)
        if inspection.truncated {
            problems.append("More than 500 generated files; review is intentionally limited")
        }
        let fingerprint = ExtensionStore.contentFingerprint(directory: directory,
                                                            fileManager: fileManager)
        reviews[extensionId] = ExtensionBuildReview(
            extensionId: extensionId,
            name: manifest?.name,
            permissions: (manifest?.permissions ?? []).sorted(),
            commands: (manifest?.contributes?.commands ?? []).map {
                ">\($0.id) — \($0.title) [\($0.contextKind)]"
            },
            eventTriggers: (manifest?.contributes?.rules ?? []).map { rule in
                let kinds = rule.filter?.kind?.joined(separator: ", ")
                return kinds.map { "\(rule.on) [\($0)]" } ?? rule.on
            },
            windows: (manifest?.contributes?.windows ?? []).map {
                "\($0.id) — \($0.title)"
            },
            namedActions: (manifest?.contributes?.actions ?? [:]).keys.sorted(),
            problems: problems,
            files: inspection.files,
            fingerprint: fingerprint)

        let summaryURL = directory.appendingPathComponent("SUMMARY.md")
        let summary = Self.readText(summaryURL, maximumBytes: 64 * 1024)
        let wasApproved = builds.first(where: { $0.extensionId == extensionId })?.status == .approved
        if wasApproved,
           store.loaded.first(where: { $0.id == extensionId })?.fingerprint != fingerprint {
            // This is no longer merely a draft: enforce ExtensionStore's normal change-disable
            // rule immediately and close any window that could be running the old approval.
            store.reload()
        }
        let remainsApproved = wasApproved
            && store.isEnabled(extensionId)
            && store.loaded.first(where: { $0.id == extensionId })?.fingerprint == fingerprint
        update(extensionId) {
            $0.status = remainsApproved ? .approved : .needsReview
            $0.summary = summary
            $0.lastError = problems.isEmpty ? nil : problems.joined(separator: "\n")
            $0.updatedAt = Date()
        }
    }

    /// Feed human review back into the same live conversation when possible. If its tmux
    /// session ended, a fresh agent receives the original goal plus the current validation state.
    func rework(extensionId: String, feedback rawFeedback: String) async -> ActionResult {
        let feedback = rawFeedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feedback.isEmpty else { return .failure("Describe what should change.") }
        guard let build = builds.first(where: { $0.extensionId == extensionId }) else {
            return .failure("Build not found.")
        }

        refreshReview(extensionId: extensionId)
        let prompt = reworkPrompt(build: build, feedback: feedback,
                                  problems: reviews[extensionId]?.problems ?? [])
        let sessionName: String
        if let existing = build.sessionName,
           let live = sessions.session(named: existing), live.agent != .shell {
            sessionName = existing
            let result = await deliver(prompt, to: existing, agent: live.agent)
            if case .failure(let message) = result {
                update(extensionId) { $0.lastError = message }
                return result
            }
        } else {
            let directory = store.revealDirectory().appendingPathComponent(extensionId, isDirectory: true)
            sessionName = await sessions.createSession(projectDir: directory.path, agent: .claude,
                                                       initialPrompt: prompt, rememberProject: false)
            sessions.setAlias(sessionName, "Rework extension · \(extensionId)")
        }
        update(extensionId) {
            $0.sessionName = sessionName
            $0.status = .reworking
            $0.lastError = nil
            $0.updatedAt = Date()
        }
        return .success(sessionName)
    }

    /// The only path from generated files to executable extension. ExtensionStore records the
    /// reviewed fingerprint here, so any later agent/manual edit disables it again on Reload.
    func approve(extensionId: String) async -> ActionResult {
        guard let review = reviews[extensionId], review.canApprove else {
            return .failure("Fix every validation problem before enabling this extension.")
        }
        // Freeze the generated tree before the fingerprint comparison. A manual "Check files"
        // can be used when hooks are unavailable, including while the agent is still alive;
        // ending its tmux session here prevents it from changing code after approval.
        if let sessionName = builds.first(where: { $0.extensionId == extensionId })?.sessionName,
           sessions.session(named: sessionName) != nil {
            await sessions.kill(sessionName)
        }
        store.reload()
        guard let loaded = store.loaded.first(where: { $0.id == extensionId && $0.isValid }) else {
            refreshReview(extensionId: extensionId)
            return .failure("The extension changed or no longer validates. Review it again.")
        }
        guard loaded.fingerprint == review.fingerprint else {
            refreshReview(extensionId: extensionId)
            return .failure("Files changed after the review was loaded. Review the new content before enabling.")
        }
        store.setEnabled(extensionId, true)
        guard store.isEnabled(extensionId) else {
            return .failure("The extension could not be enabled.")
        }
        update(extensionId) {
            $0.status = .approved
            $0.lastError = nil
            $0.updatedAt = Date()
        }
        return .success(extensionId)
    }

    func forget(extensionId: String) {
        builds.removeAll { $0.extensionId == extensionId }
        reviews[extensionId] = nil
        persist()
    }

    func review(for extensionId: String) -> ExtensionBuildReview? { reviews[extensionId] }

    /// Persisted build ownership complements SessionStore's runtime-only ephemeral marker after
    /// an app restart, so builder Stop/input hooks never feed extension automation recursively.
    func ownsSession(_ name: String) -> Bool {
        builds.contains { $0.sessionName == name }
    }

    private func deliver(_ text: String, to session: String, agent: AgentKind) async -> ActionResult {
        for _ in 0..<20 {
            switch await ReplyInjector.shared.sendText(session, agent: agent, text: text) {
            case .delivered:
                sessions.applyAttention(name: session, .working)
                return .success(session)
            case .refusedShell:
                try? await Task.sleep(for: .milliseconds(250))
            case .error(let message):
                return .failure(message)
            }
        }
        return .failure("The agent did not become ready — open the session and check its launch command.")
    }

    private func generationPrompt(extensionId: String, goal: String, directory: URL) -> String {
        [
            "Create a Pass extension in the current directory.",
            "",
            "Extension id: \(extensionId)",
            "Directory: \(directory.path)",
            "Human goal:",
            goal,
            "",
            "Read the complete extension API contract first:",
            apiDocumentURL.path,
            "",
            "Rules:",
            "- Work only inside the current extension directory.",
            "- Create extension.json and every script or HTML/CSS/JS asset it references.",
            "- The manifest id must be exactly \"\(extensionId)\" and must match this folder.",
            "- Declare only the permissions the implementation actually needs.",
            "- Prefer an apiVersion 2 HTML/CSS/JS window when the goal benefits from custom UI.",
            "- A web UI may call only pass.on, pass.getSnapshot, pass.runAction, and pass.closeWindow; put privileged work in declared named actions.",
            "- Do not enable the extension and do not modify pass settings.",
            "- Before finishing, run: \"$PASS_CLI\" extension validate .",
            "- Fix every validation error, then write SUMMARY.md describing behavior, files, permissions, and how to test it.",
            "- Finish your response and stop when the extension is ready for human review.",
        ].joined(separator: "\n")
    }

    private func reworkPrompt(build: ExtensionBuild, feedback: String, problems: [String]) -> String {
        var lines = [
            "Rework the Pass extension in the current directory.",
            "Original goal:", build.goal,
            "", "Human review feedback:", feedback,
        ]
        if !problems.isEmpty {
            lines += ["", "Current validator problems:"] + problems.map { "- \($0)" }
        }
        lines += [
            "", "Read the API contract again if needed: \(apiDocumentURL.path)",
            "Run \"$PASS_CLI\" extension validate . and fix every error.",
            "Update SUMMARY.md, then finish your response and stop for another human review.",
        ]
        return lines.joined(separator: "\n")
    }

    private var apiDocumentURL: URL {
        Bundle.main.url(forResource: "EXTENSION_API", withExtension: "md")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/EXTENSION_API.md")
    }

    private func update(_ id: String, _ edit: (inout ExtensionBuild) -> Void) {
        guard let index = builds.firstIndex(where: { $0.extensionId == id }) else { return }
        edit(&builds[index])
        builds.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        builds = snapshot.builds.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        do {
            try fileManager.createDirectory(at: stateURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Snapshot(builds: builds))
            try data.write(to: stateURL, options: .atomic)
        } catch {
            Log.ext.error("extension builder state save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func readText(_ url: URL, maximumBytes: Int) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumBytes,
              let data = try? Data(contentsOf: url), data.count <= maximumBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Review is intentionally bounded: a generated binary or giant fixture gets metadata,
    /// never enough content to freeze Settings or make the approval surface unusable.
    private static func inspectFiles(in directory: URL, fileManager: FileManager)
        -> (files: [ExtensionBuildReview.File], truncated: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: directory,
                                                      includingPropertiesForKeys: keys,
                                                      options: []) else { return ([], false) }
        var urls: [URL] = []
        var truncated = false
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".git" { enumerator.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true || values.isSymbolicLink == true else { continue }
            if urls.count == 500 {
                truncated = true
                break
            }
            urls.append(url)
        }
        let root = directory.standardizedFileURL.path + "/"
        let files: [ExtensionBuildReview.File] = urls.sorted { $0.path < $1.path }.map { url in
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            let bytes = values?.fileSize ?? 0
            if values?.isSymbolicLink == true {
                let destination = (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) ?? "unknown"
                return .init(path: relative, byteCount: bytes, content: nil,
                             note: "symbolic link → \(destination)")
            }
            guard bytes <= 256 * 1024,
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                return .init(path: relative, byteCount: bytes, content: nil,
                             note: bytes > 256 * 1024 ? "file is too large to preview" : "binary file")
            }
            return .init(path: relative, byteCount: bytes, content: text, note: nil)
        }
        return (files, truncated)
    }
}
