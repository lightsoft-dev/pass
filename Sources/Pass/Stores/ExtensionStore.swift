import Foundation
import Observation

/// Loads extensions from `~/.pass/extensions/<id>/extension.json`. The disk is the source of
/// truth (SpecStore rule): reload re-reads everything, a broken manifest surfaces as an error
/// row instead of silently disappearing, and pass persists only the enabled-ids set.
@MainActor
@Observable
final class ExtensionStore {
    /// One discovered extension: its manifest, folder, and validation problems. A non-empty
    /// `problems` blocks enabling — the messages show in Settings.
    struct Loaded: Identifiable {
        var manifest: ExtensionManifest
        var directory: URL
        var problems: [String]
        var id: String { manifest.id }
        var isValid: Bool { problems.isEmpty }
    }

    /// A folder whose extension.json didn't even parse (JSON error) — shown in Settings.
    struct LoadError: Identifiable {
        var folder: String
        var message: String
        var id: String { folder }
    }

    /// One `>command` the palette offers — carries everything the runtime needs to execute it
    /// (folder + declared permissions), so execution never re-reads the store.
    struct PaletteCommand: Identifiable, Hashable {
        var extensionId: String
        var extensionName: String
        var directory: URL
        var permissions: Set<String>
        var command: ExtensionManifest.Command
        var id: String { extensionId + "." + command.id }
        var token: String { ">" + command.id }
    }

    private(set) var loaded: [Loaded] = []
    private(set) var loadErrors: [LoadError] = []
    private(set) var enabledIds: Set<String>
    /// Example extensions shipped inside the app that aren't installed yet. Cached (bundle
    /// contents can't change mid-run) — computing it does disk I/O, and Settings reads it
    /// from its body.
    private(set) var bundledInstallable: [String] = []

    private let directory: URL
    private let defaults: UserDefaults
    private static let enabledKey = "extensions.enabled"

    static var defaultDirectory: URL {
        PassConfig.stateDirectory.appendingPathComponent("extensions", isDirectory: true)
    }

    init(directory: URL = ExtensionStore.defaultDirectory, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
        enabledIds = Set(defaults.stringArray(forKey: Self.enabledKey) ?? [])
        reload()
    }

    /// Re-scan the extensions directory. Folders without an extension.json are ignored
    /// (they're not extensions); manifests that fail to parse become LoadErrors.
    func reload() {
        let fm = FileManager.default
        var found: [Loaded] = []
        var errors: [LoadError] = []
        let dirs = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in dirs {
            let file = dir.appendingPathComponent("extension.json")
            guard fm.fileExists(atPath: file.path) else { continue }
            do {
                let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: file))
                found.append(Loaded(manifest: manifest, directory: dir,
                                    problems: manifest.problems(directory: dir, fileManager: fm)))
            } catch {
                errors.append(LoadError(folder: dir.lastPathComponent,
                                        message: "extension.json: \(error.localizedDescription)"))
            }
        }
        loaded = found
        loadErrors = errors
        bundledInstallable = computeBundledInstallable()
        Log.ext.info("loaded \(found.count) extension(s), \(errors.count) broken")
    }

    func isEnabled(_ id: String) -> Bool { enabledIds.contains(id) }

    func setEnabled(_ id: String, _ on: Bool) {
        if on { enabledIds.insert(id) } else { enabledIds.remove(id) }
        defaults.set(Array(enabledIds).sorted(), forKey: Self.enabledKey)
    }

    /// Extensions that actually run: enabled AND valid.
    private var active: [Loaded] {
        loaded.filter { $0.isValid && enabledIds.contains($0.id) }
    }

    /// Commands the ⌘P palette offers (`>id`).
    var paletteCommands: [PaletteCommand] {
        active.flatMap { ext in
            (ext.manifest.contributes?.commands ?? []).map {
                PaletteCommand(extensionId: ext.id, extensionName: ext.manifest.name,
                               directory: ext.directory,
                               permissions: Set(ext.manifest.permissions ?? []), command: $0)
            }
        }
    }

    /// Rules the runtime matches events against, with their owning extension.
    var activeRules: [(ext: Loaded, rule: ExtensionManifest.Rule)] {
        active.flatMap { ext in (ext.manifest.contributes?.rules ?? []).map { (ext, $0) } }
    }

    /// Ensure the extensions folder exists and return it (for "Open folder…" in Settings).
    @discardableResult
    func revealDirectory() -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: Bundled examples (app bundle → Resources/Extensions/<id>)

    static var bundledDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Extensions", isDirectory: true)
    }

    private func computeBundledInstallable() -> [String] {
        guard let dir = Self.bundledDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let present = Set(loaded.map(\.id)).union(loadErrors.map(\.folder))
        return names.sorted().filter { name in
            !present.contains(name)
                && FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent(name).appendingPathComponent("extension.json").path)
        }
    }

    /// Copy a bundled example into ~/.pass/extensions (never overwrites an existing folder —
    /// the user's copy is theirs to edit) and reload. Installing does NOT enable it.
    func installBundled(id: String) throws {
        guard let src = Self.bundledDirectory?.appendingPathComponent(id, isDirectory: true) else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dst = directory.appendingPathComponent(id, isDirectory: true)
        if !fm.fileExists(atPath: dst.path) {
            try fm.copyItem(at: src, to: dst)
        }
        reload()
    }
}
