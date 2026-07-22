import Foundation
import Observation

/// Registered projects — a dumb MRU list of root paths persisted to projects.json.
/// The palette needs "no session yet" rows, so we remember every project pass has seen.
@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []

    /// Remote control-plane tap. AppModel wires this to the same debounced full-snapshot
    /// publisher as session changes so mobile project pickers do not go stale.
    var onRemoteStateChanged: (@MainActor () -> Void)?

    private let fileURL: URL

    /// `fileURL` is injectable so tests can point at a temp file instead of the real
    /// projects.json. Production passes nil → the app-support location.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("pass", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.fileURL = support.appendingPathComponent("projects.json")
        }
        load()
    }

    /// Register a project (or move it to the front if already known).
    func remember(rootPath: String) {
        let existingEmoji = projects.first { $0.rootPath == rootPath }?.emoji
        projects.removeAll { $0.rootPath == rootPath }
        projects.insert(Project(rootPath: rootPath, emoji: existingEmoji), at: 0)
        save()
        onRemoteStateChanged?()
    }

    /// Register only if not already known — no reorder, no save when present. Safe to call
    /// on every reconcile tick.
    func rememberIfNew(rootPath: String) {
        guard !projects.contains(where: { $0.rootPath == rootPath }) else { return }
        projects.append(Project(rootPath: rootPath))
        save()
        onRemoteStateChanged?()
    }

    func forget(rootPath: String) {
        let previousCount = projects.count
        projects.removeAll { $0.rootPath == rootPath }
        save()
        if projects.count != previousCount { onRemoteStateChanged?() }
    }

    /// Assign (or clear, with nil/empty) the emoji shown at the front of a project's cards.
    func setEmoji(rootPath: String, _ emoji: String?) {
        guard let idx = projects.firstIndex(where: { $0.rootPath == rootPath }) else { return }
        let trimmed = emoji?.trimmingCharacters(in: .whitespaces)
        let emoji = (trimmed?.isEmpty == false) ? String(trimmed!.prefix(2)) : nil
        let changed = projects[idx].emoji != emoji
        projects[idx].emoji = emoji
        save()
        if changed { onRemoteStateChanged?() }
    }

    func emoji(forRoot root: String) -> String? {
        projects.first { $0.rootPath == root }?.emoji
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Project].self, from: data) else { return }
        projects = list
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("projects.json save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
