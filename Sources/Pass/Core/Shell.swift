import Foundation
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

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
        // Capture into temp FILES, not pipes: when a child forks a daemon (tmux's first
        // command spawns the server), the daemon can inherit the pipe write-end and never
        // close it — readDataToEndOfFile() then blocks forever waiting for EOF (observed
        // with tmux on Linux). Files need no EOF: wait for the direct child, then read.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pass-shell-\(UUID().uuidString)")
        let outURL = scratch.appendingPathExtension("out")
        let errURL = scratch.appendingPathExtension("err")
        let fm = FileManager.default
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }
        guard let outFH = FileHandle(forWritingAtPath: outURL.path),
              let errFH = FileHandle(forWritingAtPath: errURL.path) else {
            return ProcResult(stdout: "", stderr: "could not create capture files", code: -1)
        }

        let code: Int32
        var spawnError = ""
        #if canImport(Darwin)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if !extraEnv.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnv { env[k] = v }
            proc.environment = env
        }
        proc.standardOutput = outFH
        proc.standardError = errFH
        do {
            try proc.run()
            proc.waitUntilExit()
            code = proc.terminationStatus
        } catch {
            code = -1
            spawnError = "spawn failed: \(error.localizedDescription)"
        }
        #else
        // Foundation.Process's child-exit monitoring never fires under the Static Linux
        // SDK (musl) — waitUntilExit hangs forever (observed with 6.2.4). Spawn directly.
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { env[k] = v }
        code = forkExecWait(executable, args, cwd: cwd, env: env,
                            outFD: outFH.fileDescriptor, errFD: errFH.fileDescriptor)
        if code == -1 { spawnError = "spawn failed: \(executable)" }
        #endif

        outFH.closeFile()
        errFH.closeFile()
        let outData = (try? Data(contentsOf: outURL)) ?? Data()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()
        let stderrText = String(decoding: errData, as: UTF8.self)
        return ProcResult(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: spawnError.isEmpty ? stderrText : spawnError,
            code: code
        )
    }

    #if !canImport(Darwin)
    /// fork/execve/waitpid. Everything the child touches is allocated BEFORE fork —
    /// between fork() and execve() only async-signal-safe calls are allowed.
    /// Returns the exit code, a negative signal number, or -1 on spawn failure.
    private static func forkExecWait(_ executable: String, _ args: [String], cwd: String?,
                                     env: [String: String], outFD: Int32, errFD: Int32) -> Int32 {
        var argvC: [UnsafeMutablePointer<CChar>?] = ([executable] + args).map { strdup($0) }
        argvC.append(nil)
        var envpC: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        envpC.append(nil)
        let cwdC = cwd.map { strdup($0) }
        defer {
            argvC.forEach { free($0) }
            envpC.forEach { free($0) }
            free(cwdC ?? nil)
        }

        let pid = fork()
        if pid == 0 {
            if let cwdC { _ = chdir(cwdC) }
            let devnull = open("/dev/null", O_RDONLY)
            if devnull >= 0 { _ = dup2(devnull, 0) }
            _ = dup2(outFD, 1)
            _ = dup2(errFD, 2)
            _ = execve(argvC[0], argvC, envpC)
            _exit(127)
        }
        guard pid > 0 else { return -1 }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return -1 }
        }
        if (status & 0x7f) == 0 { return (status >> 8) & 0xff } // WIFEXITED → WEXITSTATUS
        return -(status & 0x7f)                                 // terminated by signal
    }
    #endif

    /// Resolve an executable on the user's login PATH (GUI apps get an impoverished PATH).
    /// Returns the absolute path, or nil if not found.
    static func resolveViaLoginShell(_ name: String) -> String? {
        // Try common locations first (fast path), then a login shell.
        #if os(macOS)
        let candidateDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let loginShell = "/bin/zsh"
        #else
        // Linux: user-space installs first (SteamOS's immutable rootfs pushes tools to
        // ~/.local/bin, linuxbrew, or nix), then the system dirs. No zsh on SteamOS —
        // fall back to the user's shell, then sh.
        let home = NSHomeDirectory()
        let candidateDirs = ["\(home)/.local/bin", "/usr/local/bin", "/usr/bin", "/bin",
                             "/home/linuxbrew/.linuxbrew/bin", "\(home)/.nix-profile/bin"]
        let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
        #endif
        for dir in candidateDirs {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        let r = run(loginShell, ["-lc", "command -v \(name)"])
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.ok && !path.isEmpty && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
    }
}
