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

    private func waitForPane(
        _ client: TmuxClient,
        session: String,
        until condition: (String) -> Bool
    ) async -> String {
        var captured = ""
        for _ in 0..<50 {
            captured = await client.capturePane(session, colors: false)
            if condition(captured) { return captured }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return captured
    }

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

            // A different agent started later in the same terminal must replace the durable tag.
            await client.setAgentTag(name: name, agent: .codex)
            let retagged = await client.listSessions().first { $0.name == name }
            XCTAssertEqual(retagged?.agentOption, AgentKind.codex.rawValue)

            // This test verifies tmux's transport primitive, not the user's interactive shell
            // setup. A detached login shell can legitimately wait for a terminal response in
            // user rc files, so replace it with a deterministic echoing process.
            let pane = await client.run(["respawn-pane", "-k", "-t", name, "/bin/cat"])
            XCTAssertTrue(pane.ok, "could not start deterministic pane: \(pane.stderr)")

            // The FINDINGS §2 injection primitive: named buffer → bracketed paste → capture.
            let marker = "portspike-marker-\(name.suffix(4))"
            let pasteResult = await client.paste(marker, into: name)
            XCTAssertEqual(pasteResult, .pasted)
            let captured = await waitForPane(client, session: name) { $0.contains(marker) }
            XCTAssertTrue(captured.contains(marker),
                          "pasted text not visible in pane; captured:\n\(captured)")
        }

        await client.killSession(name)
        let gone = await client.hasSession(name)
        XCTAssertFalse(gone, "kill-session left the session behind")
    }

    func testLongUnicodeShellCommandLaunchesInNarrowPane() async throws {
        let client = TmuxClient()
        guard await client.isAvailable, FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw XCTSkip("tmux or zsh not installed")
        }

        let name = "portspike-launch-\(UInt32.random(in: 0x1000...0xFFFF))"
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-complete")
        let created = await client.newSession(name: name, cwd: NSTemporaryDirectory(),
                                              projectRoot: "/tmp/portspike", agent: .codex,
                                              launchCommand: nil)
        XCTAssertTrue(created)
        guard created else { return }

        // Delayed zsh startup proves the command waits for a real prompt, rather than
        // sending a long paste while the shell is still loading its configuration.
        let shell = await client.run(["respawn-pane", "-k", "-t", name,
                                      "sleep 0.7; exec /bin/zsh -f -i"])
        let resized = await client.run(["resize-window", "-t", name, "-x", "66", "-y", "39"])
        XCTAssertTrue(shell.ok)
        XCTAssertTrue(resized.ok)
        let prompt = String(repeating: "프로젝트 동기화 요청", count: 180)
        let command = ": \(Shell.singleQuoted(prompt)); printf complete > \(Shell.singleQuoted(output.path))"
        let submitted = await client.submitShellCommand(command, in: name)
        XCTAssertTrue(submitted)

        var completed = false
        for _ in 0..<40 {
            completed = FileManager.default.fileExists(atPath: output.path)
            if completed { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(completed, "long Korean command did not execute")
        await client.killSession(name)
        try? FileManager.default.removeItem(at: output)
    }
}
