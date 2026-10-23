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

final class PanelPresentationRequestTests: XCTestCase {
    func testSessionDeepLinkAdvancesAsOneRequest() {
        var request = PanelPresentationRequest()

        request.advance(preselecting: "pass-target", projectRoot: "/repos/target")

        XCTAssertEqual(request.revision, 1)
        XCTAssertEqual(request.preselectedSession, "pass-target")
        XCTAssertEqual(request.preselectedProjectRoot, "/repos/target")
    }

    func testOrdinaryPresentationClearsPreviousDeepLink() {
        var request = PanelPresentationRequest()
        request.advance(preselecting: "pass-target", projectRoot: "/repos/target",
                        focusProjectAgent: true)

        request.advance()

        XCTAssertEqual(request.revision, 2)
        XCTAssertNil(request.preselectedSession)
        XCTAssertNil(request.preselectedProjectRoot)
        XCTAssertFalse(request.focusProjectAgent)
    }

    func testProjectFallbackWinsOverAnotherProjectsWaitingSession() {
        var other = Session(
            name: "pass-other", projectRoot: "/repos/other", cwd: "/repos/other",
            agent: .claude, lastActivity: .now, isAttached: false
        )
        other.attention = .pending(Attention(kind: .input, receivedAt: .now, preview: "Input"))
        let target = Session(
            name: "pass-target", projectRoot: "/repos/target", cwd: "/repos/target",
            agent: .claude, lastActivity: .now, isAttached: false
        )

        let selected = PanelSessionSelection.resolve(
            preselectedSession: "pass-ended-session",
            projectRoot: "/repos/target",
            orderedSessions: [other, target]
        )

        XCTAssertEqual(selected, target.name)
    }

    func testShortcutOpensPaForCurrentProjectDespiteOtherWaitingSession() {
        let other = Session(name: "pass-other", projectRoot: "/repos/other", cwd: "/repos/other",
                            agent: .claude, lastActivity: .now, isAttached: false)
        let target = Session(name: "pass-target", projectRoot: "/repos/target", cwd: "/repos/target",
                             agent: .codex, lastActivity: .now, isAttached: false)

        let root = PanelProjectSelection.resolve(
            preselectedSession: nil, preselectedProjectRoot: nil,
            currentProjectRoot: "/repos/target",
            availableProjectRoots: ["/repos/other", "/repos/target"],
            orderedSessions: [other, target]
        )

        XCTAssertEqual(root, "/repos/target")
    }

    func testNotificationProjectWinsOverCurrentProject() {
        let root = PanelProjectSelection.resolve(
            preselectedSession: "pass-ended", preselectedProjectRoot: "/repos/notified",
            currentProjectRoot: "/repos/current",
            availableProjectRoots: ["/repos/current", "/repos/notified"],
            orderedSessions: []
        )

        XCTAssertEqual(root, "/repos/notified")
    }
}

final class ProjectAgentNotificationTests: XCTestCase {
    @MainActor func testNotificationQueueKeepsContextUntilMarkedSent() {
        let model = AppModel()
        let request = ProjectAgentNotificationRequest(
            id: "worker:finished", sessionName: "worker", kind: "finished",
            title: "Build finished", summary: "Tests passed"
        )

        model.enqueueProjectAgentNotification(request, for: "/repos/project")
        let updated = ProjectAgentNotificationRequest(
            id: request.id, sessionName: "worker", kind: "finished",
            title: "Build finished", summary: "All checks passed"
        )
        model.enqueueProjectAgentNotification(updated, for: "/repos/project")

        XCTAssertEqual(model.pendingProjectAgentNotification(for: "/repos/project"), updated)
        XCTAssertNil(model.pendingProjectAgentNotification(for: "/repos/other"))
        XCTAssertTrue(updated.prompt.contains("All checks passed"))
        XCTAssertTrue(updated.prompt.contains("worker"))

        model.markProjectAgentNotificationSent(request.id, for: "/repos/project")
        XCTAssertNil(model.pendingProjectAgentNotification(for: "/repos/project"))
    }

    @MainActor func testAutomaticWorkerAttentionAsksPaToInspectBeforeActing() {
        let request = ProjectAgentNotificationRequest(
            id: "worker:decision", sessionName: "worker", kind: "decision",
            title: "Permission needed", summary: "Allow access?", automatic: true
        )

        XCTAssertTrue(request.prompt.contains("session list --json"))
        XCTAssertTrue(request.prompt.contains("session tail"))
        XCTAssertTrue(request.prompt.contains("권한 승인"))
        XCTAssertTrue(request.prompt.contains("worker"))
    }

    @MainActor func testFinishedWorkerTurnIsForwardedToPaAsAStatusUpdate() {
        let session = Session(name: "worker", projectRoot: "/repos/project",
                              cwd: "/repos/project", agent: .codex,
                              lastActivity: .now, isAttached: false)
        let attention = Attention(kind: .finished, receivedAt: .now, preview: "Tests passed")

        let request = ProjectAgentNotificationRequest.fromWorkerAttention(attention, session: session)

        XCTAssertEqual(request?.id, "worker:finished")
        XCTAssertTrue(request?.displayText.contains("워커의 턴 종료를 확인하는 중") == true)
        XCTAssertTrue(request?.prompt.contains("턴 종료가 전체 작업 완료를 뜻하지는 않습니다") == true)
        XCTAssertTrue(request?.prompt.contains("Tests passed") == true)
    }

    @MainActor func testRepeatedTurnEndIsNotForwardedTwice() {
        let completed = AttentionState.pending(
            Attention(kind: .finished, receivedAt: .now, preview: "done"))
        XCTAssertFalse(EventRouter.shouldEmitFinished(after: completed))
        for kind in [Attention.Kind.input, .decision] {
            let state = AttentionState.pending(
                Attention(kind: kind, receivedAt: .now, preview: "waiting"))
            XCTAssertTrue(EventRouter.shouldEmitFinished(after: state), "\(kind)")
        }
        XCTAssertTrue(EventRouter.shouldEmitFinished(after: .working))
        XCTAssertTrue(EventRouter.shouldEmitFinished(after: .idle))
    }

    func testWorkerProgressWatchReportsQuietAndRecoveryOnlyOnTransitions() {
        let start = Date(timeIntervalSince1970: 1_000)
        var sample = ProjectWorkerProgressSample(startedAt: start)

        XCTAssertNil(sample.observe(now: start.addingTimeInterval(5), isLive: true,
                                    pane: "working", lastActivity: start.addingTimeInterval(4)))
        XCTAssertNil(sample.observe(now: start.addingTimeInterval(34), isLive: true,
                                    pane: "working", lastActivity: start.addingTimeInterval(4)))
        XCTAssertEqual(sample.observe(now: start.addingTimeInterval(35), isLive: true,
                                      pane: "working", lastActivity: start.addingTimeInterval(4)),
                       .quiet)
        XCTAssertNil(sample.observe(now: start.addingTimeInterval(45), isLive: true,
                                    pane: "working", lastActivity: start.addingTimeInterval(4)))
        XCTAssertEqual(sample.observe(now: start.addingTimeInterval(50), isLive: true,
                                      pane: "new output", lastActivity: start.addingTimeInterval(49)),
                       .resumed)
        XCTAssertEqual(sample.observe(now: start.addingTimeInterval(80), isLive: true,
                                      pane: "new output", lastActivity: start.addingTimeInterval(49)),
                       .quiet)
    }

    func testWorkerProgressWatchConfirmsMissingSessionTwice() {
        let start = Date(timeIntervalSince1970: 1_000)
        var sample = ProjectWorkerProgressSample(startedAt: start)
        XCTAssertNil(sample.observe(now: start.addingTimeInterval(5), isLive: false,
                                    pane: "", lastActivity: nil))
        XCTAssertNil(sample.observe(now: start.addingTimeInterval(10), isLive: true,
                                    pane: "working", lastActivity: nil))
        XCTAssertNil(sample.observe(now: start.addingTimeInterval(15), isLive: false,
                                    pane: "", lastActivity: nil))
        XCTAssertEqual(sample.observe(now: start.addingTimeInterval(20), isLive: false,
                                      pane: "", lastActivity: nil), .disappeared)
    }

    @MainActor func testWorkerProgressAlertAsksPaToVerifyInsteadOfResending() {
        let request = ProjectAgentNotificationRequest.fromWorkerWatch(
            .quiet, sessionName: "worker", title: "Coding worker")
        XCTAssertEqual(request.kind, "watch-quiet")
        XCTAssertTrue(request.prompt.contains("session list --json"))
        XCTAssertTrue(request.prompt.contains("session tail"))
        XCTAssertTrue(request.prompt.contains("중복 전달하지 마세요"))
    }
}
