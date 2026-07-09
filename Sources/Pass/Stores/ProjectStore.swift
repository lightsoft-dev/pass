import Foundation
import Observation

/// Registered projects — a dumb MRU list of root paths persisted to projects.json.
/// The palette needs "no session yet" rows, so we remember every project pass has seen.
@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []

    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pass", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.fileURL = support.appendingPathComponent("projects.json")
        load()
    }

    /// Register a project (or move it to the front if already known).
    func remember(rootPath: String) {
        projects.removeAll { $0.rootPath == rootPath }
        projects.insert(Project(rootPath: rootPath), at: 0)
        save()
    }

    /// Register only if not already known — no reorder, no save when present. Safe to call
    /// on every reconcile tick.
    func rememberIfNew(rootPath: String) {
        guard !projects.contains(where: { $0.rootPath == rootPath }) else { return }
        projects.append(Project(rootPath: rootPath))
        save()
    }

    func forget(rootPath: String) {
        projects.removeAll { $0.rootPath == rootPath }
        save()
    }

    /// Assign (or clear, with nil/empty) the emoji shown at the front of a project's cards.
    func setEmoji(rootPath: String, _ emoji: String?) {
        guard let idx = projects.firstIndex(where: { $0.rootPath == rootPath }) else { return }
        let trimmed = emoji?.trimmingCharacters(in: .whitespaces)
        projects[idx].emoji = (trimmed?.isEmpty == false) ? String(trimmed!.prefix(2)) : nil
        save()
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
