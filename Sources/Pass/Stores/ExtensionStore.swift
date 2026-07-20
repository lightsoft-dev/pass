import CryptoKit
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
        var fingerprint: String
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
    private(set) var changedIds: Set<String>
    /// Example extensions shipped inside the app that aren't installed yet. Cached (bundle
    /// contents can't change mid-run) — computing it does disk I/O, and Settings reads it
    /// from its body.
    private(set) var bundledInstallable: [String] = []

    private let directory: URL
    private let defaults: UserDefaults
    private static let enabledKey = "extensions.enabled"
    private static let fingerprintsKey = "extensions.approvedFingerprints"
    private static let changedKey = "extensions.changedSinceApproval"
    private var approvedFingerprints: [String: String]

    /// UI windows hold executable web content. Reloading or disabling an extension invalidates
    /// those windows so reviewed content can never be silently replaced underneath a live view.
    var onReload: (() -> Void)?
    var onDisabled: ((String) -> Void)?

    nonisolated static var defaultDirectory: URL {
        PassConfig.stateDirectory.appendingPathComponent("extensions", isDirectory: true)
    }

    init(directory: URL = ExtensionStore.defaultDirectory, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
        enabledIds = Set(defaults.stringArray(forKey: Self.enabledKey) ?? [])
        changedIds = Set(defaults.stringArray(forKey: Self.changedKey) ?? [])
        approvedFingerprints = defaults.dictionary(forKey: Self.fingerprintsKey) as? [String: String] ?? [:]
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
                                    problems: manifest.problems(directory: dir, fileManager: fm),
                                    fingerprint: Self.fingerprint(directory: dir, fileManager: fm)))
            } catch {
                errors.append(LoadError(folder: dir.lastPathComponent,
                                        message: "extension.json: \(error.localizedDescription)"))
            }
        }
        loaded = found
        loadErrors = errors
        var changed: Set<String> = []
        for ext in found where enabledIds.contains(ext.id) {
            if let approved = approvedFingerprints[ext.id] {
                if approved != ext.fingerprint {
                    enabledIds.remove(ext.id)
                    changed.insert(ext.id)
                }
            } else {
                // One-time migration for extensions enabled before content approvals existed.
                approvedFingerprints[ext.id] = ext.fingerprint
            }
        }
        changedIds.formUnion(changed)
        persistApprovals()
        bundledInstallable = computeBundledInstallable()
        onReload?()
        Log.ext.info("loaded \(found.count) extension(s), \(errors.count) broken")
    }

    func isEnabled(_ id: String) -> Bool { enabledIds.contains(id) }

    func setEnabled(_ id: String, _ on: Bool) {
        if on {
            guard let ext = loaded.first(where: { $0.id == id && $0.isValid }) else { return }
            approvedFingerprints[id] = ext.fingerprint
            changedIds.remove(id)
            enabledIds.insert(id)
        } else {
            enabledIds.remove(id)
        }
        persistApprovals()
        if !on { onDisabled?(id) }
    }

    /// Extensions that actually run: enabled AND valid.
    private var active: [Loaded] {
        loaded.filter { $0.isValid && enabledIds.contains($0.id) }
    }

    func activeExtension(id: String) -> Loaded? {
        active.first { $0.id == id }
    }

    func wasDisabledAfterChange(_ id: String) -> Bool { changedIds.contains(id) }

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

    private func persistApprovals() {
        defaults.set(Array(enabledIds).sorted(), forKey: Self.enabledKey)
        defaults.set(approvedFingerprints, forKey: Self.fingerprintsKey)
        defaults.set(Array(changedIds).sorted(), forKey: Self.changedKey)
    }

    /// Stable digest of every non-.git file. Approval follows reviewed content, not just an id;
    /// changing HTML/JS/scripts/manifest disables the extension on the next reload.
    private static func fingerprint(directory: URL, fileManager: FileManager) -> String {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(at: directory,
                                                      includingPropertiesForKeys: keys,
                                                      options: []) else { return "unreadable" }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            if let values = try? url.resourceValues(forKeys: Set(keys)),
               values.isRegularFile == true || values.isSymbolicLink == true {
                files.append(url)
            }
        }
        files.sort { $0.path < $1.path }
        var hasher = SHA256()
        let root = directory.standardizedFileURL.path + "/"
        for file in files {
            let path = file.standardizedFileURL.path
            let relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                let destination = (try? fileManager.destinationOfSymbolicLink(atPath: file.path)) ?? "?"
                hasher.update(data: Data(destination.utf8))
            } else if let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) {
                hasher.update(data: data)
            }
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
