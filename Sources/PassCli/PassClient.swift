import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

// Mirrored /cli/* JSON shapes — the app's Sources/Pass/Server/CLIAPI.swift is the source of
// truth (separate target, no shared framework — same rule as PassShare). Keep the two in sync.

struct CLIOpenRequest: Codable {
    var session: String? = nil
    var url: String
    var background: Bool? = nil
}

struct CLIOpenResponse: Codable {
    var ok: Bool
    var tabId: String? = nil
    var resolvedURL: String? = nil
    var error: String? = nil
}

struct CLICloseRequest: Codable {
    var session: String? = nil
}

struct CLISimpleResponse: Codable {
    var ok: Bool
    var error: String? = nil
}

struct CLITabsResponse: Codable {
    struct Tab: Codable {
        var id: String
        var session: String
        var url: String
        var title: String? = nil
        var unseen: Bool
    }
    var ok: Bool
    var tabs: [Tab]
}

struct CLIScreenshotRequest: Codable {
    var session: String? = nil
    var path: String? = nil
}

struct CLIScreenshotResponse: Codable {
    var ok: Bool
    var path: String? = nil
    var error: String? = nil
}

struct CLIReadRequest: Codable {
    var session: String? = nil
    var format: String? = nil
}

struct CLIReadResponse: Codable {
    var ok: Bool
    var content: String? = nil
    var truncated: Bool? = nil
    var error: String? = nil
}

/// Exit codes (BROWSER.md §5.3): 0 ok · 1 pass refused (reason on stderr) · 2 usage /
/// no target session · 3 pass not running.
enum PassExit {
    static let refused: Int32 = 1
    static let usage: Int32 = 2
    static let notRunning: Int32 = 3
}

/// Thin loopback HTTP client for pass's /cli/* control plane.
enum PassClient {
    static var port: Int {
        ProcessInfo.processInfo.environment["PASS_PORT"].flatMap(Int.init) ?? 49817
    }

    static var baseURL: String { "http://127.0.0.1:\(port)" }

    /// --session > $PASS_SESSION > the enclosing tmux session (covers adopted sessions whose
    /// agent started before pass injected the env var) > nil.
    static func resolveSession(explicit: String?) -> String? {
        if let explicit, !explicit.isEmpty { return explicit }
        let env = ProcessInfo.processInfo.environment
        if let s = env["PASS_SESSION"], !s.isEmpty { return s }
        if env["TMUX"] != nil, let s = tmuxSessionName() { return s }
        return nil
    }

    private static func tmuxSessionName() -> String? {
        #if canImport(Darwin)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "display-message", "-p", "#S"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
        #else
        // Foundation.Process.waitUntilExit hangs under the Static Linux SDK (musl) —
        // fork/execve directly. Mirror of Core/Shell.swift's forkExecWait; keep in sync.
        let outPath = NSTemporaryDirectory() + "passcli-tmux-\(UUID().uuidString).out"
        FileManager.default.createFile(atPath: outPath, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        guard let outFH = FileHandle(forWritingAtPath: outPath) else { return nil }

        let argvStrings: [String] = ["/usr/bin/env", "tmux", "display-message", "-p", "#S"]
        var argvC: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) }
        argvC.append(nil)
        var envpC: [UnsafeMutablePointer<CChar>?] =
            ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        envpC.append(nil)
        defer {
            argvC.forEach { free($0) }
            envpC.forEach { free($0) }
        }

        let pid = fork()
        if pid == 0 {
            let devnull = open("/dev/null", O_RDWR)
            if devnull >= 0 { _ = dup2(devnull, 0); _ = dup2(devnull, 2) }
            _ = dup2(outFH.fileDescriptor, 1)
            _ = execve(argvC[0], argvC, envpC)
            _exit(127)
        }
        outFH.closeFile()
        guard pid > 0 else { return nil }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return nil }
        }
        guard (status & 0x7f) == 0, (status >> 8) & 0xff == 0 else { return nil }
        guard let data = FileManager.default.contents(atPath: outPath) else { return nil }
        let out = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
        #endif
    }

    static func post<Request: Encodable, Response: Decodable>(
        _ path: String, _ body: Request, as type: Response.Type
    ) async -> Response {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        request.timeoutInterval = 30
        return await send(request, as: type)
    }

    static func get<Response: Decodable>(_ path: String, as type: Response.Type) async -> Response {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.timeoutInterval = 10
        return await send(request, as: type)
    }

    private static func send<Response: Decodable>(
        _ request: URLRequest, as type: Response.Type
    ) async -> Response {
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
                fail("pass answered with an unexpected shape — app and passcli out of sync? (rebuild pass)",
                     code: PassExit.refused)
            }
            return response
        } catch {
            fail("could not reach pass on 127.0.0.1:\(port) — is the pass app running?",
                 code: PassExit.notRunning)
        }
    }

    /// GET /health. Short timeout so `advertise` never delays a session's startup.
    static func healthy(timeout: TimeInterval = 1.0) async -> Bool {
        guard let url = URL(string: baseURL + "/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(decoding: data, as: UTF8.self) == "ok"
    }

    static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }

    static func printJSON<T: Encodable>(_ value: T) {
        if let data = try? JSONEncoder().encode(value) {
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
