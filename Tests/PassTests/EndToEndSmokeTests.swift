import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Pass

/// End-to-end smoke for the Linux port spike: boots the REAL HookServer and drives the REAL
/// tmux binary, so `swift test` proves the two empirical pillars (loopback hooks, tmux
/// injection primitives) on whatever platform it runs on. Runs on macOS too — same contract.
final class EndToEndSmokeTests: XCTestCase {
    /// Scratch port — never 49817, a live pass app may own that.
    private let port: UInt16 = 49907

    func testHookServerBindsAndRoutesAHook() async throws {
        let server = HookServer()
        await server.start(port: port)
        let bound = await server.didBind
        XCTAssertTrue(bound, "hook server failed to bind 127.0.0.1:\(port)")

        // Listener first; AsyncStream buffers, so no race with the POST below.
        let events = await server.events
        let listener = Task { () -> HookHit? in
            for await hit in events { return hit }
            return nil
        }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook/claude/Notification")!)
        req.httpMethod = "POST"
        req.setValue("portspike", forHTTPHeaderField: "X-Pass-Session")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Notification",
            "message": "smoke",
        ])
        let (_, resp) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)

        let watchdog = Task { try await Task.sleep(for: .seconds(10)); listener.cancel() }
        let hit = await listener.value
        watchdog.cancel()
        XCTAssertEqual(hit?.path, "/hook/claude/Notification")
        XCTAssertEqual(hit?.raw.passSessionHeader, "portspike")
        await server.stop()
    }

    func testTmuxSessionLifecycleAndPasteInjection() async throws {
        let client = TmuxClient()
        guard await client.isAvailable else { throw XCTSkip("tmux not installed") }

        // Not `pass-` prefixed — a live pass app must not adopt it.
        let name = "portspike-\(UInt32.random(in: 0x1000...0xFFFF))"
        await client.newSession(name: name, cwd: NSTemporaryDirectory(),
                                projectRoot: "/tmp/portspike", agent: .claude, launchCommand: nil)
        let created = await client.hasSession(name)
        XCTAssertTrue(created, "new-session failed (tmux < 3.2 lacks -e?)")

        do {
            // listSessions exercises the -F tab-separator parsing and @pass_* options.
            let mine = await client.listSessions().first { $0.name == name }
            XCTAssertNotNil(mine, "created session missing from list-sessions")
            XCTAssertEqual(mine?.projectRootOption, "/tmp/portspike")
            XCTAssertEqual(mine?.agentOption, AgentKind.claude.rawValue)

            // The FINDINGS §2 injection primitive: set-buffer → bracketed paste → capture.
            let marker = "portspike-marker-\(name.suffix(4))"
            await client.setBuffer("echo \(marker)")
            await client.pasteBuffer(into: name)
            try await Task.sleep(for: .milliseconds(500))
            let captured = await client.capturePane(name, colors: false)
            XCTAssertTrue(captured.contains(marker),
                          "pasted text not visible in pane; captured:\n\(captured)")
        }

        await client.killSession(name)
        let gone = await client.hasSession(name)
        XCTAssertFalse(gone, "kill-session left the session behind")
    }
}
