import Foundation
import Observation

/// Registered projects plus the directories explicitly chosen as project discovery roots.
/// Projects remain an MRU list for launchers; `projectDirectories` is the user-facing source
/// list shown in Settings so it is clear which parts of disk Pass is syncing from.
@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []
    private(set) var projectDirectories: [String] = []

    /// Remote control-plane tap. AppModel wires this to the same debounced full-snapshot
    /// publisher as session changes so mobile project pickers do not go stale.
    var onRemoteStateChanged: (@MainActor () -> Void)?

    private let fileURL: URL
    private let directoriesFileURL: URL

    /// `fileURL` is injectable so tests can point at a temp file instead of the real
    /// projects.json. Production passes nil → the app-support location.
    init(fileURL: URL? = nil, directoriesFileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            self.directoriesFileURL = directoriesFileURL
                ?? fileURL.deletingLastPathComponent()
                    .appendingPathComponent("\(fileURL.deletingPathExtension().lastPathComponent)-directories.json")
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("pass", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.fileURL = support.appendingPathComponent("projects.json")
            self.directoriesFileURL = directoriesFileURL
                ?? support.appendingPathComponent("project-directories.json")
        }
        load()
    }

    /// Remember an exact folder selected in the project picker. Returns true when it was new.
    @discardableResult
    func rememberDirectory(path: String) -> Bool {
        let path = Self.normalized(path)
        guard !path.isEmpty, !projectDirectories.contains(path) else { return false }
        projectDirectories.append(path)
        projectDirectories.sort {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        saveDirectories()
        return true
    }

    func forgetDirectory(path: String) {
        let path = Self.normalized(path)
        let previousCount = projectDirectories.count
        projectDirectories.removeAll { $0 == path }
        if projectDirectories.count != previousCount {
            saveDirectories()
        }
    }

    func projectCount(inDirectory path: String) -> Int {
        let path = Self.normalized(path)
        let descendantPrefix = path == "/" ? "/" : path + "/"
        return projects.count {
            let root = Self.normalized($0.rootPath)
            return root == path || root.hasPrefix(descendantPrefix)
        }
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
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([Project].self, from: data) {
            projects = list
        }

        if let data = try? Data(contentsOf: directoriesFileURL),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            projectDirectories = Array(Set(list.map(Self.normalized)))
                .filter { !$0.isEmpty }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return
        }

        // Existing installs only persisted individual projects. Seed the new directory list
        // from their parent folders once; an intentionally emptied list persists as [] and
        // therefore does not get repopulated on later launches.
        projectDirectories = Array(Set(projects.map {
            Self.normalized(
                URL(fileURLWithPath: $0.rootPath, isDirectory: true)
                    .deletingLastPathComponent().path
            )
        }))
        .filter { !$0.isEmpty }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if !projects.isEmpty {
            saveDirectories()
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("projects.json save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveDirectories() {
        do {
            let data = try JSONEncoder().encode(projectDirectories)
            try data.write(to: directoriesFileURL, options: .atomic)
        } catch {
            Log.app.error("project-directories.json save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func normalized(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}
