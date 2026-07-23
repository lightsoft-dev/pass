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

    /// Opaque ownership of one update attempt. The store, rather than an individual Settings
    /// row, owns this state so a recycled row or another caller cannot re-enable code while Git
    /// is checking or changing it.
    struct UpdateSession {
        fileprivate var id: String
        fileprivate var nonce: UUID
    }

    struct ExecutionLease {
        fileprivate var nonce: UUID
    }

    enum UpdateCompletion: Equatable {
        /// The update was applied and the extension remains disabled for review.
        case applied
        /// Applying failed without changing reviewed files, so the prior approval was restored.
        case restored
        /// Files changed (or could no longer be verified), so the extension remains disabled.
        case changed
    }

    /// One `>command` the palette offers — carries everything the runtime needs to execute it
    /// (folder + declared permissions), so execution never re-reads the store.
    struct PaletteCommand: Identifiable, Hashable {
        var extensionId: String
        var extensionName: String
        var directory: URL
        var permissions: Set<String>
        var command: ExtensionManifest.Command
        var fingerprint: String
        var id: String { extensionId + "." + command.id }
        var token: String { ">" + command.id }
    }

    private(set) var loaded: [Loaded] = []
    private(set) var loadErrors: [LoadError] = []
    private(set) var enabledIds: Set<String>
    private(set) var changedIds: Set<String>
    private(set) var updatingIds: Set<String> = []
    /// Example extensions shipped inside the app that aren't installed yet. Cached (bundle
    /// contents can't change mid-run) — computing it does disk I/O, and Settings reads it
    /// from its body.
    private(set) var bundledInstallable: [String] = []

    private let directory: URL
    private let defaults: UserDefaults
    private static let enabledKey = "extensions.enabled"
    private static let fingerprintsKey = "extensions.approvedFingerprints"
    private static let changedKey = "extensions.changedSinceApproval"
    private static let terminalExecutionsKey = "extensions.terminalExecutions"
    private var approvedFingerprints: [String: String]
    /// Terminal-mode actions outlive the async call that launches them because tmux owns the
    /// process. Persist their session names so an app restart cannot make an in-flight action
    /// invisible to the Git update guard.
    private var terminalExecutions: [String: String]
    private struct UpdateState {
        var nonce: UUID
        var directory: URL
        var fingerprint: String
        var wasEnabled: Bool
        var approvedFingerprint: String?
        var wasChanged: Bool
    }
    private var updateStates: [String: UpdateState] = [:]
    private var executionLeases: [UUID: String] = [:]
    /// Names persisted just before tmux creation. A concurrent inventory cannot release these
    /// until the launcher confirms its own create+reconcile sequence has completed.
    private var pendingTerminalLaunches: Set<String> = []

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
        terminalExecutions = defaults.dictionary(forKey: Self.terminalExecutionsKey) as? [String: String] ?? [:]
        // A process can terminate between clone and atomic installation. At startup no install
        // can still be active, so remove every abandoned sibling before the first scan.
        ExtensionSharingService.cleanupStaleInstallations(in: directory, olderThan: 0)
        reload()
    }

    /// Re-scan the extensions directory. Folders without an extension.json are ignored
    /// (they're not extensions); manifests that fail to parse become LoadErrors.
    func reload() {
        let fm = FileManager.default
        var found: [Loaded] = []
        var errors: [LoadError] = []
        var pendingReviewIDs: Set<String> = []
        var pendingReviewMarkers: [URL] = []
        let dirs = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter {
                !$0.lastPathComponent.hasPrefix(".install-")
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in dirs {
            let reviewMarker = dir.appendingPathComponent(".git", isDirectory: true)
                .appendingPathComponent(ExtensionSharingService.pendingReviewMarkerName)
            let hasPendingReview = fm.fileExists(atPath: reviewMarker.path)
            if hasPendingReview {
                pendingReviewIDs.insert(dir.lastPathComponent)
                pendingReviewMarkers.append(reviewMarker)
            }
            let file = dir.appendingPathComponent("extension.json")
            guard fm.fileExists(atPath: file.path) else { continue }
            do {
                let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: file))
                if hasPendingReview { pendingReviewIDs.insert(manifest.id) }
                found.append(Loaded(manifest: manifest, directory: dir,
                                    problems: manifest.problems(directory: dir, fileManager: fm),
                                    fingerprint: Self.contentFingerprint(directory: dir, fileManager: fm)))
            } catch {
                errors.append(LoadError(folder: dir.lastPathComponent,
                                        message: "extension.json: \(error.localizedDescription)"))
            }
        }
        loaded = found
        loadErrors = errors
        for id in pendingReviewIDs {
            enabledIds.remove(id)
            approvedFingerprints.removeValue(forKey: id)
            changedIds.remove(id)
        }
        var changed: Set<String> = []
        for ext in found where enabledIds.contains(ext.id) {
            if let approved = approvedFingerprints[ext.id] {
                if approved != ext.fingerprint {
                    enabledIds.remove(ext.id)
                    changed.insert(ext.id)
                }
            } else {
                // Fail closed for legacy/stale ids. Auto-approving an unknown fingerprint would
                // let a newly created folder inherit an old enabled preference.
                enabledIds.remove(ext.id)
                changed.insert(ext.id)
            }
        }
        changedIds.formUnion(changed)
        persistApprovals()
        // State is durable before the marker disappears: a crash repeats the safe clear.
        for marker in pendingReviewMarkers { try? fm.removeItem(at: marker) }
        bundledInstallable = computeBundledInstallable()
        onReload?()
        Log.ext.info("loaded \(found.count) extension(s), \(errors.count) broken")
    }

    func isEnabled(_ id: String) -> Bool { enabledIds.contains(id) }

    func isUpdating(_ id: String) -> Bool { updatingIds.contains(id) }

    func setEnabled(_ id: String, _ on: Bool) {
        // UI disabling is not a security boundary: a stale SwiftUI binding or another caller may
        // still arrive while an update is in flight. Never allow enabling in that interval. A
        // defensive disable is allowed and becomes the state restored if the update fails.
        guard !on || !updatingIds.contains(id) else { return }
        if !on, var update = updateStates[id] {
            update.wasEnabled = false
            updateStates[id] = update
        }
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

    /// Reserve an extension for an update check without stopping it yet. `git fetch` only changes
    /// `.git`, so executable content may remain enabled until `prepareUpdate` immediately before
    /// the fast-forward. The reservation prevents enable state changes in that interval.
    func beginUpdate(_ id: String) -> UpdateSession? {
        guard updateStates[id] == nil,
              !executionLeases.values.contains(id),
              !terminalExecutions.values.contains(id),
              let ext = loaded.first(where: { $0.id == id }) else { return nil }
        let nonce = UUID()
        updateStates[id] = UpdateState(
            nonce: nonce,
            directory: ext.directory,
            fingerprint: ext.fingerprint,
            wasEnabled: enabledIds.contains(id),
            approvedFingerprint: approvedFingerprints[id],
            wasChanged: changedIds.contains(id))
        updatingIds.insert(id)
        return UpdateSession(id: id, nonce: nonce)
    }

    /// Disable reviewed code immediately before Git may change the worktree. If something else
    /// changed it during the network check, refuse the update and keep it disabled for review.
    func prepareUpdate(_ session: UpdateSession) -> Bool {
        guard let state = updateStates[session.id], state.nonce == session.nonce else { return false }
        let current = Self.contentFingerprint(directory: state.directory)
        guard current == state.fingerprint else {
            updateStates.removeValue(forKey: session.id)
            updatingIds.remove(session.id)
            enabledIds.remove(session.id)
            changedIds.insert(session.id)
            persistApprovals()
            onDisabled?(session.id)
            reload()
            return false
        }
        enabledIds.remove(session.id)
        changedIds.insert(session.id)
        persistApprovals()
        if state.wasEnabled { onDisabled?(session.id) }
        return true
    }

    /// End an update attempt and re-check the actual worktree. A failed apply restores the exact
    /// previous enable/approval state only when every reviewed file still has the same digest.
    /// Any partial or external change stays disabled and visibly requires review.
    @discardableResult
    func finishUpdate(_ session: UpdateSession, didApply: Bool) -> UpdateCompletion? {
        guard let state = updateStates[session.id], state.nonce == session.nonce else { return nil }
        updateStates.removeValue(forKey: session.id)
        updatingIds.remove(session.id)

        let current = Self.contentFingerprint(directory: state.directory)
        if didApply {
            enabledIds.remove(session.id)
            changedIds.insert(session.id)
            persistApprovals()
            reload()
            return .applied
        }
        if current == state.fingerprint {
            if state.wasEnabled {
                enabledIds.insert(session.id)
            } else {
                enabledIds.remove(session.id)
            }
            if let approved = state.approvedFingerprint {
                approvedFingerprints[session.id] = approved
            } else {
                approvedFingerprints.removeValue(forKey: session.id)
            }
            if state.wasChanged {
                changedIds.insert(session.id)
            } else {
                changedIds.remove(session.id)
            }
            persistApprovals()
            return .restored
        }

        enabledIds.remove(session.id)
        changedIds.insert(session.id)
        persistApprovals()
        onDisabled?(session.id)
        reload()
        return .changed
    }

    /// Stop an extension before an external updater changes its files in place and leave a
    /// visible review marker. This closes extension windows through the same disable hook.
    func requireReview(_ id: String) {
        if var update = updateStates[id] {
            update.wasEnabled = false
            update.wasChanged = true
            updateStates[id] = update
        }
        enabledIds.remove(id)
        changedIds.insert(id)
        persistApprovals()
        onDisabled?(id)
    }

    /// A freshly cloned folder must never inherit a stale enabled id or the legacy approval
    /// migration. Clear all prior approval state before the first reload discovers its files.
    func prepareNewInstallation(_ id: String) {
        enabledIds.remove(id)
        approvedFingerprints.removeValue(forKey: id)
        changedIds.remove(id)
        persistApprovals()
        onDisabled?(id)
    }

    /// Extensions that actually run: enabled AND valid.
    private var active: [Loaded] {
        loaded.filter { $0.isValid && enabledIds.contains($0.id) }
    }

    /// Enabled + valid extensions shown in the panel/menu-bar launcher. This intentionally
    /// includes event-only extensions with no commands so activation is visible to the user.
    var activeExtensions: [Loaded] { active }

    func activeExtension(id: String) -> Loaded? {
        active.first { $0.id == id }
    }

    /// Hold reviewed files stable for the lifetime of one action. Update reservation and action
    /// start are both MainActor operations, so neither can cross the other's boundary.
    func beginExecution(extensionId: String, fingerprint: String,
                        directory: URL) -> ExecutionLease? {
        guard !updatingIds.contains(extensionId),
              let ext = activeExtension(id: extensionId),
              ext.fingerprint == fingerprint,
              ext.directory.standardizedFileURL == directory.standardizedFileURL
        else { return nil }
        let nonce = UUID()
        executionLeases[nonce] = extensionId
        return ExecutionLease(nonce: nonce)
    }

    func endExecution(_ lease: ExecutionLease) {
        executionLeases.removeValue(forKey: lease.nonce)
    }

    /// Transfer a short-lived launch lease to the durable tmux session that now owns the
    /// action. This is called before tmux is created; persisting first makes both a launch crash
    /// and an app restart fail closed until a reliable tmux inventory proves the session absent.
    func promoteExecution(_ lease: ExecutionLease, toTerminalSession sessionName: String) -> Bool {
        guard !sessionName.isEmpty,
              terminalExecutions[sessionName] == nil,
              !pendingTerminalLaunches.contains(sessionName),
              let extensionId = executionLeases.removeValue(forKey: lease.nonce)
        else { return false }
        terminalExecutions[sessionName] = extensionId
        pendingTerminalLaunches.insert(sessionName)
        persistTerminalExecutions()
        return true
    }

    func finishTerminalLaunch(_ sessionName: String) {
        pendingTerminalLaunches.remove(sessionName)
    }

    /// A successful tmux inventory is authoritative even when empty. Transient command or parse
    /// failures never call this method, so they cannot accidentally release an execution lock.
    func reconcileTerminalExecutions(liveSessionNames: Set<String>) {
        let reconciled = terminalExecutions.filter {
            pendingTerminalLaunches.contains($0.key) || liveSessionNames.contains($0.key)
        }
        guard reconciled != terminalExecutions else { return }
        terminalExecutions = reconciled
        persistTerminalExecutions()
    }

    func wasDisabledAfterChange(_ id: String) -> Bool { changedIds.contains(id) }

    /// Commands the ⌘P palette offers. `token` keeps the explicit `>id` spelling, while the
    /// palette can also find commands by id, title, or extension name in normal search.
    var paletteCommands: [PaletteCommand] {
        active.flatMap { ext in
            (ext.manifest.contributes?.commands ?? []).map {
                PaletteCommand(extensionId: ext.id, extensionName: ext.manifest.name,
                               directory: ext.directory,
                               permissions: Set(ext.manifest.permissions ?? []), command: $0,
                               fingerprint: ext.fingerprint)
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
            prepareNewInstallation(id)
            try fm.copyItem(at: src, to: dst)
        }
        reload()
    }

    private func persistApprovals() {
        defaults.set(Array(enabledIds).sorted(), forKey: Self.enabledKey)
        defaults.set(approvedFingerprints, forKey: Self.fingerprintsKey)
        defaults.set(Array(changedIds).sorted(), forKey: Self.changedKey)
    }

    private func persistTerminalExecutions() {
        defaults.set(terminalExecutions, forKey: Self.terminalExecutionsKey)
    }

    /// Stable digest of every non-.git file. Approval follows reviewed content, not just an id;
    /// changing HTML/JS/scripts/manifest disables the extension on the next reload.
    static func contentFingerprint(directory: URL, fileManager: FileManager = .default) -> String {
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
            let isSymbolicLink = (try? file.resourceValues(
                forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            hasher.update(data: Data(isSymbolicLink ? [0x4c] : [0x46])) // L(ink) / F(ile)
            if isSymbolicLink {
                let destination = (try? fileManager.destinationOfSymbolicLink(atPath: file.path)) ?? "?"
                hasher.update(data: Data(destination.utf8))
            } else if let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) {
                let attributes = try? fileManager.attributesOfItem(atPath: file.path)
                let mode = (attributes?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
                hasher.update(data: Data(String(mode).utf8))
                hasher.update(data: Data([0]))
                hasher.update(data: data)
            }
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
