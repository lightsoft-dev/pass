import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Pass

/// XCTest-free runtime smoke for platforms where the test bundle can't run (the Static
/// Linux SDK ships no XCTest). Mirrors Tests/PassTests/EndToEndSmokeTests.swift: boots the
/// real HookServer, drives the real tmux. Exit 0 = all checks passed.
@main
struct Smoke {
    static var failures = 0

    static func check(_ ok: Bool, _ label: String, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    static func main() async {
        // `pass-smoke proc` — minimal Foundation.Process probe (is waitUntilExit alive at all?)
        if CommandLine.arguments.contains("proc") {
            print("spawning /bin/echo …")
            let r = Shell.run("/bin/echo", ["proc-check-ok"])
            print("echo done: code=\(r.code) out=\(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
            print("spawning /bin/sh -c 'exit 3' …")
            let r2 = Shell.run("/bin/sh", ["-c", "exit 3"])
            print("sh done: code=\(r2.code)")
            print("spawning tmux new-session (first server) …")
            let r3 = Shell.run("/usr/bin/tmux", ["new-session", "-d", "-s", "proccheck"],
                               extraEnv: ["LC_ALL": "C.UTF-8"])
            print("tmux done: code=\(r3.code) err=\(r3.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            exit(0)
        }

        print("INFO os: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("INFO tmux: \(Shell.resolveViaLoginShell("tmux") ?? "not found")")

        await hookServerSmoke()
        await tmuxSmoke()

        print(failures == 0 ? "OK — all checks passed" : "FAILED — \(failures) check(s)")
        exit(failures == 0 ? 0 : 1)
    }

    static func hookServerSmoke() async {
        let port: UInt16 = 49907 // never 49817 — a live pass app may own it
        let server = HookServer()
        await server.start(port: port)
        let bound = await server.didBind
        check(bound, "hook server binds 127.0.0.1:\(port) (FlyingFox/epoll)")
        guard bound else { return }

        let events = await server.events
        let listener = Task { () -> HookHit? in
            for await hit in events { return hit }
            return nil
        }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook/claude/Notification")!)
        req.httpMethod = "POST"
        req.setValue("portspike", forHTTPHeaderField: "X-Pass-Session")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Notification",
            "message": "smoke",
        ])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            check((resp as? HTTPURLResponse)?.statusCode == 200, "POST /hook/claude/* → 200")
        } catch {
            check(false, "POST /hook/claude/*", error.localizedDescription)
        }

        let watchdog = Task { try? await Task.sleep(for: .seconds(10)); listener.cancel() }
        let hit = await listener.value
        watchdog.cancel()
        check(hit?.path == "/hook/claude/Notification" && hit?.raw.passSessionHeader == "portspike",
              "hook routed through AsyncStream with X-Pass-Session header",
              hit.map { "path=\($0.path) header=\($0.raw.passSessionHeader ?? "nil")" } ?? "no hit received")
        await server.stop()
    }

    static func tmuxSmoke() async {
        let client = TmuxClient()
        guard await client.isAvailable else {
            check(false, "tmux resolution", "tmux not found — install it in this environment")
            return
        }

        // Not `pass-` prefixed — a live pass app must not adopt it.
        let name = "portspike-\(UInt32.random(in: 0x1000...0xFFFF))"
        await client.newSession(name: name, cwd: NSTemporaryDirectory(),
                                projectRoot: "/tmp/portspike", agent: .claude, launchCommand: nil)
        check(await client.hasSession(name), "tmux new-session with -e env (needs tmux ≥ 3.2)")

        let mine = await client.listSessions().first { $0.name == name }
        check(mine != nil, "list-sessions -F tab-separated parsing")
        check(mine?.projectRootOption == "/tmp/portspike" && mine?.agentOption == AgentKind.claude.rawValue,
              "@pass_project_root/@pass_agent options round-trip",
              mine.map { "root=\($0.projectRootOption ?? "nil") agent=\($0.agentOption ?? "nil")" } ?? "session missing")

        let marker = "portspike-marker-\(name.suffix(4))"
        await client.setBuffer("echo \(marker)")
        await client.pasteBuffer(into: name)
        try? await Task.sleep(for: .milliseconds(500))
        let captured = await client.capturePane(name, colors: false)
        check(captured.contains(marker), "bracketed-paste injection visible in capture-pane (FINDINGS §2)")

        await client.killSession(name)
        let gone = await client.hasSession(name)
        check(!gone, "kill-session")
    }
}
