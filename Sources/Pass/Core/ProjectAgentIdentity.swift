import CryptoKit
import Foundation
import Observation

/// Stable identity for the one Pi coordinator owned by a registered project.
enum ProjectAgentIdentity {
    private static func hash(_ root: String) -> String {
        SHA256.hash(data: Data(root.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func sessionName(for root: String) -> String {
        "pass-manager-" + String(hash(root).prefix(16))
    }

    static func piSessionID(for root: String) -> String {
        let value = hash(root)
        let end = value.index(value.startIndex, offsetBy: 32)
        let id = String(value[..<end])
        return "\(id.prefix(8))-\(id.dropFirst(8).prefix(4))-\(id.dropFirst(12).prefix(4))-\(id.dropFirst(16).prefix(4))-\(id.dropFirst(20))"
    }

    /// Separate from the earlier interactive Pi session, which may still be running in tmux.
    static func rpcSessionID(for root: String) -> String {
        piSessionID(for: root + "#pass-rpc")
    }

    static func isManager(name: String, projectRoot: String) -> Bool {
        name == sessionName(for: projectRoot)
    }

    static func launchCommand(for root: String) -> String? {
        guard let pi = Shell.resolveViaLoginShell("pi"),
              let prompt = Bundle.main.path(forResource: "ProjectAgentInstructions", ofType: "md"),
              let memory = try? ProjectAgentWorkerMemory.ensureFile(for: root)
        else { return nil }
        let title = URL(fileURLWithPath: root).lastPathComponent + " · Pa"
        return ["PASS_PA_MEMORY=" + Shell.singleQuoted(memory.path),
                Shell.singleQuoted(pi), "--no-extensions", "--session-id", piSessionID(for: root),
                "--name", Shell.singleQuoted(title),
                "--append-system-prompt", Shell.singleQuoted(prompt),
                "--append-system-prompt", Shell.singleQuoted(memory.path)].joined(separator: " ")
    }
}

enum ProjectAgentWorkerMemory {
    static func ensureFile(for root: String, baseDirectory: URL? = nil,
                           templateURL: URL? = nil) throws -> URL {
        let support = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("Pass/Pa", isDirectory: true)
            .appendingPathComponent(ProjectAgentIdentity.sessionName(for: root), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("worker-memory.md")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard let source = templateURL ?? Bundle.main.url(forResource: "PaWorkerMemory", withExtension: "md") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let contents = try String(contentsOf: source, encoding: .utf8)
                .replacingOccurrences(of: "{{PROJECT_ROOT}}", with: root)
                .replacingOccurrences(of: "{{MEMORY_PATH}}", with: file.path)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        return file
    }
}

enum ProjectAgentFailure: Error, LocalizedError {
    case unregisteredProject
    case piUnavailable
    case launchFailed

    var errorDescription: String? {
        switch self {
        case .unregisteredProject: return "This project is no longer registered in Pass."
        case .piUnavailable: return "Pi is unavailable. Install pi and restart Pass."
        case .launchFailed: return "The project agent could not start in tmux."
        }
    }
}

/// Pa may use any locally connected Pi provider; credentials stay in Pi's own auth store.
enum PiAuthentication {
    static func defaultModelLabel(agentDirectory: URL? = nil) -> String? {
        let directory = agentDirectory ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".pi/agent", isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = settings["defaultProvider"] as? String,
              let model = settings["defaultModel"] as? String else { return nil }
        return provider + "/" + model
    }

    static func hasCredential(for provider: String, agentDirectory: URL? = nil) -> Bool {
        usableProviders(agentDirectory: agentDirectory).contains(provider)
    }

    static func usableProviders(now: Date = Date(), agentDirectory: URL? = nil) -> Set<String> {
        let directory = agentDirectory ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".pi/agent", isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("auth.json")),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return Set(auth.compactMap { provider, value in
            guard let credential = value as? [String: Any] else { return nil }
            switch credential["type"] as? String {
            case "api_key":
                return (credential["key"] as? String)?.isEmpty == false ? provider : nil
            case "oauth":
                guard let expiry = credential["expires"] as? Double,
                      let access = credential["access"] as? String,
                      !access.isEmpty,
                      expiry > now.timeIntervalSince1970 * 1_000 + 60_000
                else { return nil }
                return provider
            default: return nil
            }
        })
    }

    static func needsLogin(now: Date = Date(), agentDirectory: URL? = nil) -> Bool {
        usableProviders(now: now, agentDirectory: agentDirectory).isEmpty
    }
}

/// Updates the user's existing Pi installation through Pi's own self-update command.
@MainActor
@Observable
final class PiUpdater {
    private(set) var version: String?
    private(set) var isUpdating = false
    private(set) var status: String?
    @ObservationIgnored private var versionGeneration = 0

    func refreshVersion() {
        guard !isUpdating else { return }
        guard let pi = Shell.resolveViaLoginShell("pi") else {
            version = nil
            return
        }
        versionGeneration += 1
        let generation = versionGeneration
        Task {
            let result = await Self.run(pi, arguments: ["--version"])
            if generation == versionGeneration, !isUpdating, result.exitCode == 0 {
                version = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    func update(onSuccess: @escaping @MainActor () -> Void) {
        guard !isUpdating else { return }
        guard let pi = Shell.resolveViaLoginShell("pi") else {
            status = "Pi가 설치되어 있지 않습니다."
            return
        }
        versionGeneration += 1
        isUpdating = true
        status = "Pi 업데이트 중…"
        Task {
            let oldVersion = version
            let result = await Self.run(pi, arguments: ["update", "--self", "--no-approve"])
            let updated = await Self.run(pi, arguments: ["--version"])
            if updated.exitCode == 0 {
                version = updated.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            isUpdating = false
            if result.exitCode == 0 {
                if let version {
                    status = version == oldVersion ? "Pi v\(version)은 최신 버전입니다."
                                                   : "Pi v\(version) 업데이트 완료"
                    if version != oldVersion { onSuccess() }
                } else {
                    status = "Pi 업데이트 후 버전을 확인할 수 없습니다."
                    onSuccess()
                }
            } else {
                let detail = result.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                status = detail.isEmpty ? "Pi 업데이트에 실패했습니다."
                    : "Pi 업데이트 실패: \(String(detail.prefix(180)))"
            }
        }
    }

    private struct CommandResult: Sendable {
        let exitCode: Int32
        let output: String
    }

    private nonisolated static func run(_ executable: String, arguments: [String]) async -> CommandResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = URL(fileURLWithPath: executable).deletingLastPathComponent().path
                + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return CommandResult(exitCode: process.terminationStatus,
                                     output: String(decoding: data, as: UTF8.self))
            } catch {
                return CommandResult(exitCode: -1, output: error.localizedDescription)
            }
        }.value
    }
}
