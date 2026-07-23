import XCTest
@testable import Pass

final class CodexHooksInstallerTests: XCTestCase {
    private var existing: [String: Any] {
        [
            "description": "My hooks",
            "hooks": [
                "Stop": [[
                    "hooks": [[
                        "type": "command",
                        "command": "echo existing",
                    ]],
                ]],
                "PreToolUse": [[
                    "matcher": "Bash",
                    "hooks": [[
                        "type": "command",
                        "command": "check-command",
                    ]],
                ]],
            ],
        ]
    }

    func testMergePreservesExistingHooksAndAddsEveryPassEvent() {
        let (root, changed) = CodexHooksInstaller.merged(into: existing)
        XCTAssertTrue(changed)
        XCTAssertEqual(root["description"] as? String, "My hooks")

        let hooks = root["hooks"] as! [String: Any]
        let stopGroups = hooks["Stop"] as! [[String: Any]]
        XCTAssertEqual(stopGroups.count, 2)
        XCTAssertEqual(
            ((stopGroups[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String),
            "echo existing"
        )
        XCTAssertNotNil(hooks["PreToolUse"])

        for event in CodexHooksInstaller.events {
            let groups = hooks[event] as? [[String: Any]] ?? []
            let commands = groups.flatMap {
                ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
            }
            XCTAssertTrue(commands.contains(CodexHooksInstaller.hookCommand), event)
        }
    }

    func testMergeIsIdempotent() {
        let (once, changed) = CodexHooksInstaller.merged(into: existing)
        XCTAssertTrue(changed)
        let (_, changedAgain) = CodexHooksInstaller.merged(into: once)
        XCTAssertFalse(changedAgain)
    }
}

final class MultiAgentAdapterTests: XCTestCase {
    private func raw(
        _ event: String,
        header: String = "pass-agent",
        extra: [String: Any] = [:]
    ) -> RawHookEvent {
        var json: [String: Any] = [
            "hook_event_name": event,
            "session_id": "session-id",
            "cwd": "/repo",
        ]
        for (key, value) in extra { json[key] = value }
        return RawHookEvent(json: json, header: header)
    }

    func testCodexMapsPermissionAndLifecycleEvents() {
        let adapter = CodexAdapter()
        let permission = adapter.normalize(raw(
            "PermissionRequest",
            extra: ["tool_name": "Bash"]
        ))
        XCTAssertEqual(permission?.preview, "Approval requested for Bash")
        XCTAssertEqual(permission?.sessionNameHint, "pass-agent")
        XCTAssertNotNil(adapter.normalize(raw("UserPromptSubmit")))
        XCTAssertNotNil(adapter.normalize(raw("SessionStart")))
        XCTAssertNotNil(adapter.normalize(raw(
            "Stop",
            extra: ["last_assistant_message": "Finished"]
        )))
        XCTAssertNil(adapter.normalize(raw("PreToolUse")))
    }

    func testPiMapsExtensionEvents() {
        let adapter = PiAdapter()
        XCTAssertNotNil(adapter.normalize(raw("SessionStart")))
        XCTAssertNotNil(adapter.normalize(raw("UserPromptSubmit")))
        XCTAssertEqual(
            adapter.normalize(raw(
                "Stop",
                extra: ["last_assistant_message": "Done"]
            ))?.preview,
            "Done"
        )
        XCTAssertNotNil(adapter.normalize(raw("SessionEnd")))
    }

    func testRegistryIncludesEveryLaunchableAgent() {
        XCTAssertNotNil(AgentRegistry.adapter(forRoute: "/hook/claude"))
        XCTAssertNotNil(AgentRegistry.adapter(forRoute: "/hook/codex"))
        XCTAssertNotNil(AgentRegistry.adapter(forRoute: "/hook/pi"))
    }

    func testPiExtensionContainsLifecycleBridge() {
        let source = PiHooksInstaller.extensionSource
        XCTAssertTrue(source.contains(PiHooksInstaller.marker))
        XCTAssertTrue(source.contains("/hook/pi"))
        XCTAssertTrue(source.contains(#"pi.on("input""#))
        XCTAssertTrue(source.contains(#"pi.on("agent_end""#))
        XCTAssertTrue(source.contains(#"pi.on("session_shutdown""#))
    }
}
