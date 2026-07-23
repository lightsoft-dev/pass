import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Git-backed extension exchange. A repository is only copied onto disk here; ExtensionStore's
/// normal validation, explicit enable toggle, and content fingerprint remain the trust boundary.
enum ExtensionSharingService {
    static let pendingReviewMarkerName = "pass-unreviewed"
    private static let maximumRepositoryBytes: Int64 = 50 * 1_024 * 1_024
    private static let maximumRepositoryFiles = 5_000
    // Git metadata and an in-progress pack need some headroom beyond the checked-out tree.
    // The committed tree is still held to `maximumRepositoryBytes` below.
    private static let maximumTransferGrowthBytes: Int64 = 64 * 1_024 * 1_024
    private static let maximumCheckoutGrowthBytes: Int64 = 116 * 1_024 * 1_024
    private static let maximumExistingInstallationBytes: Int64 = 160 * 1_024 * 1_024
    private static let maximumGitOutputBytes: Int64 = 16 * 1_024 * 1_024
    private static let maximumMonitoredEntries = 20_000
    private static let networkGitTimeout: TimeInterval = 120
    private static let localGitTimeout: TimeInterval = 30
    private static let monitorInterval: TimeInterval = 0.05
    private static let timedOutExitCode: Int32 = -1001
    private static let quotaExceededExitCode: Int32 = -1002
    private static let outputExceededExitCode: Int32 = -1003

    struct Installed: Equatable, Sendable {
        var id: String
        var name: String
    }

    enum UpdateCheck: Equatable, Sendable {
        case current
        case available(revision: String)
    }

    enum Failure: Error, Equatable {
        case invalidURL
        case clone(String)
        case missingManifest
        case invalidManifest(String)
        case manifestMismatch
        case alreadyInstalled(String)
        case notGitRepository
        case repositoryTooLarge
        case update(String)

        var message: String {
            switch self {
            case .invalidURL:
                return "Enter a Git repository URL."
            case .clone(let detail):
                return detail.isEmpty ? "Could not download the extension." : detail
            case .missingManifest:
                return "The repository does not contain extension.json at its root."
            case .invalidManifest(let detail):
                return "extension.json could not be read: \(detail)"
            case .manifestMismatch:
                return "The repository's extension.json no longer matches this marketplace listing. Ask the publisher to update it."
            case .alreadyInstalled(let id):
                return "An extension named '\(id)' is already installed."
            case .notGitRepository:
                return "This extension was not installed from a Git repository."
            case .repositoryTooLarge:
                return "The repository is too large for an extension (maximum 50 MB and 5,000 files)."
            case .update(let detail):
                return detail.isEmpty ? "Could not update the extension." : detail
            }
        }
    }

    private static let gitPath = Shell.resolveViaLoginShell("git") ?? "/usr/bin/git"
    private static let gitEnvironment = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_LFS_SKIP_SMUDGE": "1",
        "GIT_SSH_COMMAND": "ssh -oBatchMode=yes -oConnectTimeout=15 -oConnectionAttempts=1 -oServerAliveInterval=15 -oServerAliveCountMax=2",
        // Never let an untrusted fetch launch detached maintenance outside our process-group and
        // disk monitors. Explicit maintenance can still be run by the user outside this service.
        "GIT_CONFIG_COUNT": "4",
        "GIT_CONFIG_KEY_0": "maintenance.auto",
        "GIT_CONFIG_VALUE_0": "false",
        "GIT_CONFIG_KEY_1": "maintenance.autoDetach",
        "GIT_CONFIG_VALUE_1": "false",
        "GIT_CONFIG_KEY_2": "gc.auto",
        "GIT_CONFIG_VALUE_2": "0",
        "GIT_CONFIG_KEY_3": "gc.autoDetach",
        "GIT_CONFIG_VALUE_3": "false",
        "LC_ALL": "C",
    ]

    /// Clone into a temporary sibling, read the canonical id from the manifest, then atomically
    /// move it into the extensions directory. Existing folders are never overwritten.
    static func install(repository rawRepository: String, into root: URL,
                        expectedManifest: ExtensionManifest? = nil,
                        fileManager: FileManager = .default) -> Result<Installed, Failure> {
        let repository = rawRepository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repository.isEmpty, !repository.hasPrefix("-") else { return .failure(.invalidURL) }

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return .failure(.clone(error.localizedDescription))
        }
        cleanupStaleInstallations(in: root, fileManager: fileManager)
        let staging = root.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }

        // Fetch only one revision and inspect its Git tree before materializing files. This keeps
        // a marketplace listing from silently pulling an unbounded history or working tree.
        let clone = runGit(
            ["-c", "http.lowSpeedLimit=1024", "-c", "http.lowSpeedTime=30",
             "clone", "--quiet", "--depth", "1", "--filter=blob:none", "--single-branch", "--no-tags",
             "--no-checkout", "--", repository, staging.path],
            timeout: networkGitTimeout,
            monitor: DiskBudget(directory: staging, maximumGrowth: maximumTransferGrowthBytes))
        guard clone.ok else {
            return .failure(clone.code == quotaExceededExitCode
                ? .repositoryTooLarge
                : .clone(lastError(clone.stderr)))
        }
        if let failure = repositorySizeFailure(directory: staging, revision: "HEAD") {
            return .failure(failure)
        }
        let checkout = runGit(
            ["-C", staging.path, "reset", "--hard", "--quiet", "HEAD"],
            timeout: networkGitTimeout,
            monitor: DiskBudget(directory: staging, maximumGrowth: maximumCheckoutGrowthBytes))
        guard checkout.ok else {
            return .failure(checkout.code == quotaExceededExitCode
                ? .repositoryTooLarge
                : .clone(lastError(checkout.stderr)))
        }

        let manifestURL = staging.appendingPathComponent("extension.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { return .failure(.missingManifest) }
        let manifest: ExtensionManifest
        do {
            manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            return .failure(.invalidManifest(error.localizedDescription))
        }
        guard ExtensionManifest.isValidIdentifier(manifest.id) else {
            return .failure(.invalidManifest("id must use lowercase letters, digits, and '-'"))
        }
        if let expectedManifest, manifest != expectedManifest {
            return .failure(.manifestMismatch)
        }
        let destination = root.appendingPathComponent(manifest.id, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            return .failure(.alreadyInstalled(manifest.id))
        }
        do {
            // This marker moves atomically with the clone. If Pass exits after the move but
            // before the MainActor store reloads, the next scan still clears any stale approval.
            let marker = staging.appendingPathComponent(".git", isDirectory: true)
                .appendingPathComponent(pendingReviewMarkerName)
            try Data("review required\n".utf8).write(to: marker, options: .atomic)
            try fileManager.moveItem(at: staging, to: destination)
            return .success(Installed(id: manifest.id, name: manifest.name))
        } catch {
            return .failure(.clone(error.localizedDescription))
        }
    }

    /// Fetch first without touching executable files. Callers can leave a running extension alone
    /// when it is current or the network fails, then disable it immediately before `applyUpdate`.
    static func checkForUpdate(directory: URL) -> Result<UpdateCheck, Failure> {
        guard remoteURL(directory: directory) != nil else { return .failure(.notGitRepository) }
        let fetch = runGit(
            ["-c", "http.lowSpeedLimit=1024", "-c", "http.lowSpeedTime=30",
             "-C", directory.path, "fetch", "--quiet", "--no-tags", "origin"],
            timeout: networkGitTimeout,
            monitor: DiskBudget(
                directory: directory.appendingPathComponent(".git", isDirectory: true),
                maximumGrowth: maximumTransferGrowthBytes))
        guard fetch.ok else {
            return .failure(fetch.code == quotaExceededExitCode
                ? .repositoryTooLarge
                : .update(lastError(fetch.stderr)))
        }
        guard let current = revision(directory: directory, expression: "HEAD"),
              let upstream = revision(directory: directory, expression: "@{upstream}") else {
            return .failure(.update("The current branch does not track an upstream branch."))
        }
        guard current != upstream else { return .success(.current) }
        let ancestor = runGit(
            ["-C", directory.path, "merge-base", "--is-ancestor", current, upstream],
            timeout: localGitTimeout)
        guard ancestor.ok else {
            return .failure(.update("Local and remote histories have diverged; no files were changed."))
        }
        if let failure = repositorySizeFailure(directory: directory, revision: upstream) {
            return .failure(failure)
        }
        return .success(.available(revision: upstream))
    }

    /// Apply only the revision returned by `checkForUpdate`, preserving local edits and refusing
    /// force-pushed/divergent histories. ExtensionStore.reload() remains a MainActor responsibility.
    static func applyUpdate(directory: URL, revision: String) -> Result<Void, Failure> {
        guard revision.range(of: #"^[a-f0-9]{40,64}$"#, options: .regularExpression) != nil else {
            return .failure(.update("The fetched revision was invalid."))
        }
        let result = runGit(
            ["-C", directory.path, "merge", "--ff-only", "--quiet", revision],
            timeout: localGitTimeout,
            monitor: DiskBudget(directory: directory, maximumGrowth: maximumCheckoutGrowthBytes))
        if result.code == quotaExceededExitCode { return .failure(.repositoryTooLarge) }
        return result.ok ? .success(()) : .failure(.update(lastError(result.stderr)))
    }

    /// Convenience for non-UI callers. Interactive UI uses the two-phase API above so it can
    /// disable executable content only when an update is actually ready to apply.
    static func update(directory: URL) -> Result<Void, Failure> {
        switch checkForUpdate(directory: directory) {
        case .success(.current):
            return .success(())
        case .success(.available(let revision)):
            return applyUpdate(directory: directory, revision: revision)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    static func remoteURL(directory: URL) -> String? {
        let result = runGit(["-C", directory.path, "remote", "get-url", "origin"],
                            timeout: localGitTimeout)
        guard result.ok else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Convert common GitHub clone spellings to a browser URL. Other HTTP(S) repository URLs are
    /// already useful as-is; local paths and unknown SSH hosts intentionally have no web page.
    static func webURL(for repository: String) -> URL? {
        var value = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("git@github.com:") {
            value = "https://github.com/" + value.dropFirst("git@github.com:".count)
        } else if value.hasPrefix("ssh://git@github.com/") {
            value = "https://github.com/" + value.dropFirst("ssh://git@github.com/".count)
        }
        if value.hasSuffix(".git") { value.removeLast(4) }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return url
    }

    private struct DiskBudget {
        var directory: URL
        var maximumGrowth: Int64
    }

    private struct DiskUsage {
        var bytes: Int64 = 0
        var entries = 0
        var couldNotInspect = false
    }

    /// Run Git in its own process group so a wall-clock or disk limit can stop Git and any
    /// transport helpers together. Polling the destination also bounds servers that ignore
    /// partial-clone filters before the committed-tree check gets a chance to run.
    private static func runGit(
        _ arguments: [String],
        timeout: TimeInterval,
        monitor budget: DiskBudget? = nil,
        fileManager: FileManager = .default
    ) -> ProcResult {
        let baselineUsage: DiskUsage
        if let budget {
            baselineUsage = directoryUsage(
                at: budget.directory,
                stoppingAfter: maximumExistingInstallationBytes,
                fileManager: fileManager)
            if baselineUsage.couldNotInspect || baselineUsage.entries > maximumMonitoredEntries
                || baselineUsage.bytes > maximumExistingInstallationBytes {
                return ProcResult(
                    stdout: "",
                    stderr: "Repository storage exceeds the safe inspection limit.",
                    code: quotaExceededExitCode)
            }
        } else {
            baselineUsage = DiskUsage()
        }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pass-git-\(UUID().uuidString)")
        let outURL = scratch.appendingPathExtension("out")
        let errURL = scratch.appendingPathExtension("err")
        fileManager.createFile(atPath: outURL.path, contents: nil)
        fileManager.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fileManager.removeItem(at: outURL)
            try? fileManager.removeItem(at: errURL)
        }
        guard let outHandle = FileHandle(forWritingAtPath: outURL.path),
              let errHandle = FileHandle(forWritingAtPath: errURL.path) else {
            return ProcResult(stdout: "", stderr: "Could not create Git capture files.", code: -1)
        }

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in gitEnvironment { environment[key] = value }
        var argv: [UnsafeMutablePointer<CChar>?] = ([gitPath] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        let outFD = outHandle.fileDescriptor
        let errFD = errHandle.fileDescriptor
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        let pid = spawnGitProcess(argv: &argv, envp: &envp, outFD: outFD, errFD: errFD)
        guard pid > 0 else {
            outHandle.closeFile()
            errHandle.closeFile()
            return ProcResult(stdout: "", stderr: "Could not start Git.", code: -1)
        }
        // The child also does this before exec; the parent call closes the small scheduling race.
        _ = setpgid(pid, pid)

        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + max(1, timeout)
        var status: Int32 = 0
        var exitCode: Int32 = -1
        var forcedCode: Int32?
        var forcedMessage = ""

        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                exitCode = decodedExitCode(status)
                break
            }
            if waited == -1, errno != EINTR {
                forcedCode = -1
                forcedMessage = "Could not wait for Git to finish."
                break
            }

            if ProcessInfo.processInfo.systemUptime >= deadline {
                forcedCode = timedOutExitCode
                forcedMessage = "The Git operation exceeded its time limit."
                break
            }
            if captureBytes(at: outURL, fileManager: fileManager)
                + captureBytes(at: errURL, fileManager: fileManager) > maximumGitOutputBytes {
                forcedCode = outputExceededExitCode
                forcedMessage = "Git produced more output than the safe limit."
                break
            }
            if let budget {
                let allowedBytes = addingWithoutOverflow(
                    baselineUsage.bytes, budget.maximumGrowth)
                let usage = directoryUsage(
                    at: budget.directory,
                    stoppingAfter: allowedBytes,
                    fileManager: fileManager)
                if usage.couldNotInspect || usage.entries > maximumMonitoredEntries
                    || usage.bytes > allowedBytes {
                    forcedCode = quotaExceededExitCode
                    forcedMessage = "Repository transfer exceeded the safe storage limit."
                    break
                }
            }
            Thread.sleep(forTimeInterval: monitorInterval)
        }

        if forcedCode != nil {
            terminateProcessGroup(pid, status: &status)
            exitCode = forcedCode ?? -1
        } else {
            // A well-behaved Git invocation waits for its helpers. Any process left in the
            // dedicated group after Git exits is orphaned and must not keep writing to staging.
            _ = kill(-pid, SIGKILL)
        }
        outHandle.closeFile()
        errHandle.closeFile()

        let capturedBytes = captureBytes(at: outURL, fileManager: fileManager)
            + captureBytes(at: errURL, fileManager: fileManager)
        if capturedBytes > maximumGitOutputBytes {
            exitCode = outputExceededExitCode
            forcedMessage = "Git produced more output than the safe limit."
        }
        if forcedMessage.isEmpty, let budget {
            let allowedBytes = addingWithoutOverflow(baselineUsage.bytes, budget.maximumGrowth)
            let usage = directoryUsage(
                at: budget.directory,
                stoppingAfter: allowedBytes,
                fileManager: fileManager)
            if usage.couldNotInspect || usage.entries > maximumMonitoredEntries
                || usage.bytes > allowedBytes {
                exitCode = quotaExceededExitCode
                forcedMessage = "Repository transfer exceeded the safe storage limit."
            }
        }
        if !forcedMessage.isEmpty {
            return ProcResult(stdout: "", stderr: forcedMessage, code: exitCode)
        }
        let stdout = (try? Data(contentsOf: outURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let stderr = (try? Data(contentsOf: errURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return ProcResult(stdout: stdout, stderr: stderr, code: exitCode)
    }

    private static func spawnGitProcess(
        argv: inout [UnsafeMutablePointer<CChar>?],
        envp: inout [UnsafeMutablePointer<CChar>?],
        outFD: Int32,
        errFD: Int32
    ) -> pid_t {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else { return -1 }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, outFD, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errFD, STDERR_FILENO) == 0 else {
            return -1
        }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else { return -1 }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { return -1 }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, gitPath, &actions, &attributes, argv, envp)
        return result == 0 ? pid : -1
        #else
        let pid = fork()
        if pid == 0 {
            // Everything allocated by Swift is prepared above; only async-signal-safe calls are
            // made between fork and exec on platforms where Foundation.Process cannot be polled.
            _ = setpgid(0, 0)
            let devnull = open("/dev/null", O_RDONLY)
            if devnull >= 0 {
                _ = dup2(devnull, STDIN_FILENO)
                _ = close(devnull)
            }
            _ = dup2(outFD, STDOUT_FILENO)
            _ = dup2(errFD, STDERR_FILENO)
            _ = execve(argv[0], argv, envp)
            _exit(127)
        }
        return pid
        #endif
    }

    private static func terminateProcessGroup(_ pid: pid_t, status: inout Int32) {
        _ = kill(-pid, SIGTERM)
        _ = kill(pid, SIGTERM)
        let graceDeadline = ProcessInfo.processInfo.systemUptime + 1
        var childWasReaped = false
        while ProcessInfo.processInfo.systemUptime < graceDeadline {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                childWasReaped = true
                break
            }
            if waited == -1, errno != EINTR {
                childWasReaped = true
                break
            }
            Thread.sleep(forTimeInterval: monitorInterval)
        }
        _ = kill(-pid, SIGKILL)
        _ = kill(pid, SIGKILL)
        if !childWasReaped {
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        }
    }

    private static func decodedExitCode(_ status: Int32) -> Int32 {
        (status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f)
    }

    private static func captureBytes(at url: URL, fileManager: FileManager) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    private static func addingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        lhs > Int64.max - rhs ? Int64.max : lhs + rhs
    }

    private static func directoryUsage(
        at directory: URL,
        stoppingAfter byteLimit: Int64,
        fileManager: FileManager
    ) -> DiskUsage {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return DiskUsage()
        }
        guard isDirectory.boolValue else {
            let bytes = captureBytes(at: directory, fileManager: fileManager)
            return DiskUsage(bytes: bytes, entries: 1, couldNotInspect: false)
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        ]
        var usage = DiskUsage()
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { item, _ in
                // Git atomically renames and deletes temporary pack files during fetch. A path
                // disappearing between enumeration and inspection is expected; a path that still
                // exists but cannot be inspected is not safe to ignore.
                if fileManager.fileExists(atPath: item.path) {
                    usage.couldNotInspect = true
                }
                return true
            }) else {
            return DiskUsage(couldNotInspect: true)
        }

        while let item = enumerator.nextObject() as? URL {
            usage.entries += 1
            guard let values = try? item.resourceValues(forKeys: keys) else {
                if fileManager.fileExists(atPath: item.path) {
                    usage.couldNotInspect = true
                }
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isRegularFile == true {
                let bytes = Int64(values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.fileSize
                    ?? 0)
                usage.bytes = addingWithoutOverflow(usage.bytes, max(0, bytes))
            }
            if usage.bytes > byteLimit || usage.entries > maximumMonitoredEntries {
                break
            }
        }
        return usage
    }

    private static func lastError(_ stderr: String) -> String {
        stderr.split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func revision(directory: URL, expression: String) -> String? {
        let result = runGit(["-C", directory.path, "rev-parse", "--verify", expression],
                            timeout: localGitTimeout)
        guard result.ok else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.range(of: #"^[a-f0-9]{40,64}$"#, options: .regularExpression) == nil ? nil : value
    }

    /// Remove abandoned atomic-install staging directories. Startup callers pass `olderThan: 0`
    /// because no install can be active before the store is initialized; routine install cleanup
    /// keeps a 24-hour grace period so concurrent app activity is never disturbed.
    static func cleanupStaleInstallations(
        in root: URL,
        olderThan age: TimeInterval = 24 * 60 * 60,
        fileManager: FileManager = .default
    ) {
        let removeRegardlessOfAge = age <= 0
        let cutoff = Date().addingTimeInterval(-max(0, age))
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        let children = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(keys))) ?? []
        for child in children where child.lastPathComponent.hasPrefix(".install-") {
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isDirectory == true,
                  removeRegardlessOfAge || values.contentModificationDate.map({ $0 < cutoff }) == true
            else { continue }
            try? fileManager.removeItem(at: child)
        }
    }

    /// Inspect committed blob sizes before checkout. Git LFS smudging is disabled above, and
    /// submodules are never initialized, so the checked tree is the complete materialized scope.
    private static func repositorySizeFailure(directory: URL, revision: String) -> Failure? {
        let result = runGit(
            ["-C", directory.path, "ls-tree", "-lr", "-z", "--full-tree", revision],
            timeout: localGitTimeout,
            monitor: DiskBudget(
                directory: directory.appendingPathComponent(".git", isDirectory: true),
                maximumGrowth: maximumTransferGrowthBytes))
        guard result.ok else {
            return result.code == quotaExceededExitCode
                ? .repositoryTooLarge
                : .clone(lastError(result.stderr))
        }
        var fileCount = 0
        var totalBytes: Int64 = 0
        for record in result.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: "\t") else { return .clone("Could not inspect repository contents.") }
            let fields = record[..<tab].split(separator: " ")
            guard fields.count >= 4 else { return .clone("Could not inspect repository contents.") }
            guard fields[1] == "blob" else { continue }
            guard let bytes = Int64(fields[3]), bytes >= 0 else {
                return .clone("Could not inspect repository contents.")
            }
            fileCount += 1
            totalBytes += bytes
            if fileCount > maximumRepositoryFiles || totalBytes > maximumRepositoryBytes {
                return .repositoryTooLarge
            }
        }
        return nil
    }
}
