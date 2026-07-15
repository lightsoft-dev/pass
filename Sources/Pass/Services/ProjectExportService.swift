import Foundation

/// Exports every registered project (+ Pass settings) into a single `.tar.gz` backup bundle
/// that can be moved to another machine and restored. Build artifacts (node_modules, …) are
/// excluded to shrink the archive; git repos with an `origin` remote can be *linked* by
/// URL+commit instead of copied (the "optimize" option) to shrink it further.
///
/// Convention-following (see `GitWorktreeService` / `ClaudeHooksInstaller`): an `enum` of
/// `static func`s, binaries resolved on the login PATH, work done via `Shell.run` (blocking —
/// call OFF the main thread), and user-facing errors surfaced through a nested `Failure` with
/// a short `message`. Pure decisions (mode selection, manifest encoding) are split into
/// side-effect-free helpers so they can be unit-tested without a subprocess.
enum ProjectExportService {
    private static let gitPath: String = Shell.resolveViaLoginShell("git") ?? "/usr/bin/git"
    private static let tarPath: String = Shell.resolveViaLoginShell("tar") ?? "/usr/bin/tar"
    private static let rsyncPath: String = Shell.resolveViaLoginShell("rsync") ?? "/usr/bin/rsync"

    /// Directory/file names excluded from folder-archive projects — common build outputs and
    /// caches. `.git` history is intentionally KEPT (this is a full-folder backup).
    static let excludedNames: [String] = [
        "node_modules", ".build", "DerivedData", "build", "dist", "out",
        ".next", ".nuxt", ".svelte-kit", "target", "__pycache__", ".pytest_cache",
        ".venv", "venv", ".gradle", "Pods", ".cxx", ".DS_Store", "*.xcuserstate",
    ]

    struct Options: Sendable {
        /// When true, a git repo that has an `origin` remote is recorded as URL+commit only
        /// (its folder is not copied). Everything else is archived as a folder regardless.
        var optimizeGitRepos: Bool
    }

    struct Summary: Sendable {
        var archiveURL: URL
        var total: Int        // projects written into the bundle
        var linkedByURL: Int  // recorded in `gitRemote` mode (folder omitted)
        var archived: Int     // copied in `archive` mode (folder included)
        var bytes: Int64      // size of the produced .tar.gz
    }

    enum Failure: Error {
        case noProjects
        case staging(String)
        case archive(String)

        /// Short, user-facing message.
        var message: String {
            switch self {
            case .noProjects:     return "No projects to back up."
            case .staging(let s): return s.isEmpty ? "Failed to stage projects." : s
            case .archive(let s): return s.isEmpty ? "Failed to create the archive." : s
            }
        }
    }

    /// Build the backup bundle for `projects` and write it as a `.tar.gz` to `destination`.
    /// Blocking + shells out — call from a background task, never the main thread.
    static func export(projects: [Project], options: Options, to destination: URL) -> Result<Summary, Failure> {
        guard !projects.isEmpty else { return .failure(.noProjects) }

        let fm = FileManager.default
        let workRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pass-export-\(UUID().uuidString)", isDirectory: true)
        let bundle = workRoot.appendingPathComponent("bundle", isDirectory: true)
        let projectsDir = bundle.appendingPathComponent("projects", isDirectory: true)
        let settingsDir = bundle.appendingPathComponent("settings", isDirectory: true)
        defer { try? fm.removeItem(at: workRoot) }

        do {
            try fm.createDirectory(at: projectsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        } catch {
            return .failure(.staging(error.localizedDescription))
        }

        var entries: [ManifestProject] = []
        var usedNames = Set<String>()
        var linked = 0, archived = 0

        for project in projects {
            let root = project.rootPath
            // A folder can disappear between registration and backup — skip it, don't abort.
            guard fm.fileExists(atPath: root) else { continue }

            // Disambiguate colliding basenames so two repos named "web" don't clobber each other.
            let name = uniqueName(project.name, in: &usedNames)
            let git = gitInfo(for: root)

            if mode(hasRemote: git?.remoteURL != nil, isGitRepo: git != nil, optimize: options.optimizeGitRepos) == .gitRemote,
               let git, let remote = git.remoteURL {
                entries.append(ManifestProject(
                    name: name, originalPath: root, emoji: project.emoji, mode: .gitRemote,
                    git: .init(remoteURL: remote, commit: git.commit, branch: git.branch),
                    archivePath: nil))
                linked += 1
            } else {
                let dest = projectsDir.appendingPathComponent(name, isDirectory: true)
                if let err = copyFolder(from: root, to: dest) { return .failure(.staging(err)) }
                entries.append(ManifestProject(
                    name: name, originalPath: root, emoji: project.emoji, mode: .archive,
                    git: git.map { .init(remoteURL: $0.remoteURL ?? "", commit: $0.commit, branch: $0.branch) },
                    archivePath: "projects/\(name)"))
                archived += 1
            }
        }

        guard !entries.isEmpty else { return .failure(.noProjects) }

        // Manifest, restore script, and a settings copy — the sources of truth for a restore.
        let manifest = Manifest(
            schemaVersion: 1, app: "pass", appVersion: appVersion,
            createdAt: iso8601(Date()), hostname: ProcessInfo.processInfo.hostName,
            projects: entries, settings: currentSettings())
        do {
            try encodedManifest(manifest).write(to: bundle.appendingPathComponent("manifest.json"))
            let script = bundle.appendingPathComponent("restore.sh")
            try restoreScript(for: entries).data(using: .utf8)!.write(to: script)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            try encodedProjects(projects).write(to: settingsDir.appendingPathComponent("projects.json"))
        } catch {
            return .failure(.staging(error.localizedDescription))
        }

        // Single archive: gzip the whole bundle directory.
        if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
        let tar = Shell.run(tarPath, ["-czf", destination.path, "-C", workRoot.path, "bundle"])
        guard tar.ok else { return .failure(.archive(lastLine(tar.stderr))) }

        let bytes = ((try? fm.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return .success(Summary(archiveURL: destination, total: entries.count,
                                linkedByURL: linked, archived: archived, bytes: bytes))
    }

    // MARK: - Pure helpers (unit-testable, no side effects)

    /// Which mode a project takes given its git state and the optimize option. A repo is linked
    /// by URL only when optimization is on AND it's a git repo with a remote; otherwise archived.
    static func mode(hasRemote: Bool, isGitRepo: Bool, optimize: Bool) -> ManifestProject.Mode {
        (optimize && isGitRepo && hasRemote) ? .gitRemote : .archive
    }

    /// A basename made unique within `used` by appending -2, -3, … on collision.
    static func uniqueName(_ base: String, in used: inout Set<String>) -> String {
        var name = base.isEmpty ? "project" : base
        var n = 2
        while used.contains(name) { name = "\(base)-\(n)"; n += 1 }
        used.insert(name)
        return name
    }

    // MARK: - Git

    struct GitInfo: Sendable {
        var remoteURL: String?
        var commit: String
        var branch: String?
    }

    /// Repo HEAD commit, `origin` URL (if any), and current branch — or nil when `root` isn't
    /// a git repo (or has no commits).
    static func gitInfo(for root: String) -> GitInfo? {
        let head = Shell.run(gitPath, ["-C", root, "rev-parse", "HEAD"])
        guard head.ok else { return nil }
        let commit = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commit.isEmpty else { return nil }

        let remote = Shell.run(gitPath, ["-C", root, "remote", "get-url", "origin"])
        let remoteURL = remote.ok ? remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""

        let br = Shell.run(gitPath, ["-C", root, "rev-parse", "--abbrev-ref", "HEAD"])
        let branchRaw = br.ok ? br.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let branch = (branchRaw == "HEAD" || branchRaw.isEmpty) ? nil : branchRaw

        return GitInfo(remoteURL: remoteURL.isEmpty ? nil : remoteURL, commit: commit, branch: branch)
    }

    // MARK: - Copy

    /// Snapshot-copy `src`'s contents into `dest`, dropping excluded build artifacts. Returns an
    /// error string on failure, nil on success.
    private static func copyFolder(from src: String, to dest: URL) -> String? {
        var args = ["-a"]
        for name in excludedNames { args.append("--exclude=\(name)") }
        args.append(src.hasSuffix("/") ? src : src + "/")   // trailing slash → copy contents
        args.append(dest.path + "/")
        let r = Shell.run(rsyncPath, args)
        // rsync exit 24 = "some files vanished during transfer" — benign for a live snapshot copy.
        guard r.ok || r.code == 24 else {
            let msg = lastLine(r.stderr)
            return msg.isEmpty ? "rsync failed (code \(r.code))" : msg
        }
        return nil
    }

    // MARK: - Settings snapshot

    private static func currentSettings() -> ManifestSettings {
        let d = UserDefaults.standard
        var launchCommands: [String: String] = [:]
        for agent in AgentKind.launchable {
            // Mirror LaunchCommands' key scheme ("launchCommand.<agent>"); only stored overrides.
            if let cmd = d.string(forKey: "launchCommand.\(agent.rawValue)") { launchCommands[agent.rawValue] = cmd }
        }
        return ManifestSettings(homeMode: d.string(forKey: "homeMode"), launchCommands: launchCommands)
    }

    // MARK: - Restore script (self-contained, no jq/python dependency)

    /// A pure bash restore script with one block per project — clone+checkout for `gitRemote`,
    /// copy for `archive`. Values are single-quoted so paths/URLs can't break the script.
    static func restoreScript(for entries: [ManifestProject]) -> String {
        var s = """
        #!/bin/bash
        # Pass backup — restore script. Run from INSIDE the unpacked bundle directory.
        # Usage: ./restore.sh [target-parent-dir]   (default: $HOME/pass-restore)
        # Best-effort: each project restores independently; a failure doesn't stop the rest.
        TARGET="${1:-$HOME/pass-restore}"
        mkdir -p "$TARGET"
        echo "Restoring Pass projects into $TARGET"

        """
        for e in entries {
            s += "\n# \(e.name)\n"
            switch e.mode {
            case .gitRemote:
                let url = e.git?.remoteURL ?? ""
                s += "git clone \(shq(url)) \"$TARGET\"/\(shq(e.name)) && \\\n"
                s += "  git -C \"$TARGET\"/\(shq(e.name)) checkout \(shq(e.git?.commit ?? "")) 2>/dev/null || true\n"
            case .archive:
                s += "cp -R projects/\(shq(e.name)) \"$TARGET\"/\(shq(e.name)) || true\n"
            }
        }
        s += "\necho 'Done. On the new machine, add these folders in Pass (Add projects…).'\n"
        return s
    }

    // MARK: - Encoders

    static func encodedManifest(_ manifest: Manifest) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(manifest)
    }

    private static func encodedProjects(_ projects: [Project]) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        return try enc.encode(projects)
    }

    // MARK: - Small utilities

    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    private static func iso8601(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// Single-quote a value for safe interpolation into bash.
    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The last non-empty line of stderr (git/rsync/tar put the real reason there).
    private static func lastLine(_ s: String) -> String {
        let last = s.split(separator: "\n").map(String.init).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        return (last ?? s).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Manifest model (schemaVersion 1)

struct Manifest: Codable, Sendable {
    var schemaVersion: Int
    var app: String
    var appVersion: String
    var createdAt: String
    var hostname: String
    var projects: [ManifestProject]
    var settings: ManifestSettings
}

struct ManifestProject: Codable, Sendable {
    var name: String
    var originalPath: String
    var emoji: String?
    var mode: Mode
    var git: GitRef?
    var archivePath: String?

    enum Mode: String, Codable, Sendable {
        case gitRemote  // recorded by URL+commit; folder not copied
        case archive    // folder copied into projects/<name>
    }

    struct GitRef: Codable, Sendable {
        var remoteURL: String
        var commit: String
        var branch: String?
    }
}

struct ManifestSettings: Codable, Sendable {
    var homeMode: String?
    var launchCommands: [String: String]
}

// MARK: - Backup destination (online backup surface — planned, not yet wired)

/// Where a finished backup archive goes. Today the export writes a local file directly; the
/// planned online target is object storage (S3/R2/self-hosted). New destinations implement this
/// protocol so the export flow can grow an upload step without changing `ProjectExportService`.
protocol BackupDestination: Sendable {
    /// Deliver the produced archive; return a user-facing location string.
    func deliver(archive: URL) async throws -> String
}

/// Moves the archive to a user-chosen local path. This is the destination used today.
struct LocalFileDestination: BackupDestination {
    let target: URL
    func deliver(archive: URL) async throws -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: archive, to: target)
        return target.path
    }
}

// Planned online destination — object storage (S3-compatible). Left unimplemented on purpose:
// this milestone ships local export only. When wired, hold endpoint/bucket/region here and keep
// the access secret in the Keychain (never in the manifest or UserDefaults).
//
// struct ObjectStorageDestination: BackupDestination {
//     let endpoint: URL, bucket: String, key: String   // + credentials from Keychain
//     func deliver(archive: URL) async throws -> String { /* multipart PUT, return object URL */ }
// }
