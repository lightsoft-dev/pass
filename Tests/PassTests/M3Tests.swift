import XCTest
@testable import Pass

final class ClaudeAdapterTests: XCTestCase {
    private let adapter = ClaudeAdapter()

    private func raw(_ event: String, notif: String? = nil, msg: String? = nil, header: String? = "pass-x", cwd: String? = "/repo") -> RawHookEvent {
        var json: [String: Any] = ["hook_event_name": event, "session_id": "sid", "cwd": cwd as Any]
        if let notif { json["notification_type"] = notif }
        if let msg { json["last_assistant_message"] = msg }
        return RawHookEvent(json: json, header: header)
    }

    func testPermissionPrompt() {
        let e = adapter.normalize(raw("Notification", notif: "permission_prompt"))
        XCTAssertEqual(e?.kind, .needsDecision)
        XCTAssertEqual(e?.sessionNameHint, "pass-x")
    }

    func testIdlePromptIsInput() {
        XCTAssertEqual(adapter.normalize(raw("Notification", notif: "idle_prompt"))?.kind, .needsInput)
        XCTAssertEqual(adapter.normalize(raw("Notification", notif: "agent_needs_input"))?.kind, .needsInput)
    }

    func testUnknownNotificationTolerant() {
        // schema drift: unknown notification type must not crash — treat as needs-input
        XCTAssertEqual(adapter.normalize(raw("Notification", notif: "brand_new_thing"))?.kind, .needsInput)
    }

    func testStopCarriesPreview() {
        let e = adapter.normalize(raw("Stop", msg: "all done"))
        XCTAssertEqual(e?.kind, .finished)
        XCTAssertEqual(e?.preview, "all done")
    }

    func testLifecycleEvents() {
        XCTAssertEqual(adapter.normalize(raw("UserPromptSubmit"))?.kind, .started)
        XCTAssertEqual(adapter.normalize(raw("SessionEnd"))?.kind, .ended)
    }

    func testSessionStartIgnored() {
        XCTAssertNil(adapter.normalize(raw("SessionStart")))
    }

    func testHeaderRoutingHint() {
        XCTAssertNil(adapter.normalize(raw("Stop", header: ""))?.sessionNameHint) // empty header → nil
    }
}

final class HooksInstallerMergeTests: XCTestCase {
    // Mimic the user's real settings: existing command hooks that must survive.
    private var existing: [String: Any] {
        [
            "hooks": [
                "Notification": [["matcher": "", "hooks": [["type": "command", "command": "~/orca.sh"]]]],
                "Stop": [["hooks": [["type": "command", "command": "~/cmux.sh"]]]],
                "PostToolUse": [["matcher": "Task", "hooks": [["type": "command", "command": "~/t.sh"]]]],
            ],
        ]
    }

    func testMergePreservesExistingAndAddsHttp() {
        let (root, changed) = ClaudeHooksInstaller.merged(into: existing)
        XCTAssertTrue(changed)
        let hooks = root["hooks"] as! [String: Any]

        // original command hooks survive
        func commands(_ ev: String) -> [String] {
            (hooks[ev] as? [[String: Any]] ?? []).flatMap { g in
                (g["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
            }
        }
        XCTAssertTrue(commands("Notification").contains("~/orca.sh"))
        XCTAssertTrue(commands("Stop").contains("~/cmux.sh"))
        XCTAssertTrue(commands("PostToolUse").contains("~/t.sh")) // untouched event

        // pass http hook added to each of its events
        func httpURLs(_ ev: String) -> [String] {
            (hooks[ev] as? [[String: Any]] ?? []).flatMap { g in
                (g["hooks"] as? [[String: Any]] ?? []).filter { ($0["type"] as? String) == "http" }
                    .compactMap { $0["url"] as? String }
            }
        }
        for ev in ["Notification", "Stop", "UserPromptSubmit", "SessionEnd"] {
            XCTAssertEqual(httpURLs(ev), ["http://127.0.0.1:49817/hook/claude"], "event \(ev)")
        }
        XCTAssertEqual(root["allowedHttpHookUrls"] as? [String], ["http://127.0.0.1:49817/hook/claude"])
    }

    func testMergeIsIdempotent() {
        let (once, changed1) = ClaudeHooksInstaller.merged(into: existing)
        XCTAssertTrue(changed1)
        let (_, changed2) = ClaudeHooksInstaller.merged(into: once)
        XCTAssertFalse(changed2) // second run makes no changes
    }
}
