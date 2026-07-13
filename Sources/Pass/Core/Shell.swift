import Foundation

/// Result of running an external command.
struct ProcResult: Sendable {
    var stdout: String
    var stderr: String
    var code: Int32
    var ok: Bool { code == 0 }
    var lines: [String] { stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
}

enum Shell {
    /// Wrap text in single quotes for a shell command line (embedded ' becomes '\''),
    /// so arbitrary shared text can ride along as one argv entry. Newlines stay inside
    /// the quotes (zsh/bash continue the string across lines).
    static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Run an executable with args and return captured output. Blocking; call from an
    /// actor / background task, never the main thread.
    static func run(_ executable: String, _ args: [String], cwd: String? = nil,
                    extraEnv: [String: String] = [:]) -> ProcResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if !extraEnv.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnv { env[k] = v }
            proc.environment = env
        }
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return ProcResult(stdout: "", stderr: "spawn failed: \(error.localizedDescription)", code: -1)
        }
        // Read fully before waiting to avoid pipe-buffer deadlock on large output.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return ProcResult(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            code: proc.terminationStatus
        )
    }

    /// Resolve an executable on the user's login PATH (GUI apps get an impoverished PATH).
    /// Returns the absolute path, or nil if not found.
    static func resolveViaLoginShell(_ name: String) -> String? {
        // Try common locations first (fast path), then a login shell.
        for candidate in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        let r = run("/bin/zsh", ["-lc", "command -v \(name)"])
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.ok && !path.isEmpty && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
    }
}
