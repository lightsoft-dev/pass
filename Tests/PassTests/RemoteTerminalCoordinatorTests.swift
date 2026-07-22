import XCTest
@testable import Pass

final class RemoteTerminalCoordinatorTests: XCTestCase {
    func testOpenRenewInputAndCloseSubscription() async throws {
        let pane = FakeTerminalPaneAccess(snapshot: .init(
            content: "prompt $ ",
            columns: 120,
            rows: 36,
            cursorX: 9,
            cursorY: 0
        ))
        let coordinator = RemoteTerminalCoordinator(panes: pane) { _ in }

        let opened = await coordinator.open(
            session: "pass-app",
            subscriptionID: "term_123",
            previousRevision: nil
        )
        let revision = try XCTUnwrap(opened?.revision)
        XCTAssertEqual(opened?.content, "prompt $ ")
        XCTAssertEqual(opened?.columns, 120)

        let renewed = await coordinator.open(
            session: "pass-app",
            subscriptionID: "term_123",
            previousRevision: revision
        )
        XCTAssertNil(renewed?.content)
        let didSend = await coordinator.sendInput(
            session: "pass-app",
            subscriptionID: "term_123",
            input: "한글\r"
        )
        let receivedInputs = await pane.inputs()
        XCTAssertTrue(didSend)
        XCTAssertEqual(receivedInputs, ["한글\r"])

        await coordinator.close(session: "pass-app", subscriptionID: "term_123")
        let didSendAfterClose = await coordinator.sendInput(
            session: "pass-app",
            subscriptionID: "term_123",
            input: "ignored"
        )
        XCTAssertFalse(didSendAfterClose)
        await coordinator.stop()
    }

    func testPublishesOnlyChangedPaneSnapshots() async throws {
        let pane = FakeTerminalPaneAccess(snapshot: .init(
            content: "first",
            columns: 80,
            rows: 24,
            cursorX: 5,
            cursorY: 0
        ))
        let recorder = TerminalSnapshotRecorder()
        let coordinator = RemoteTerminalCoordinator(
            panes: pane,
            refreshInterval: .milliseconds(20)
        ) { snapshot in
            await recorder.append(snapshot)
        }

        _ = await coordinator.open(
            session: "pass-app",
            subscriptionID: "term_stream",
            previousRevision: nil
        )
        try await Task.sleep(for: .milliseconds(50))
        let initialPublishedCount = await recorder.count()
        XCTAssertEqual(initialPublishedCount, 0)

        await pane.setSnapshot(.init(
            content: "second",
            columns: 80,
            rows: 24,
            cursorX: 6,
            cursorY: 0
        ))
        for _ in 0..<20 {
            guard await recorder.count() == 0 else { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let snapshots = await recorder.values()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.content, "second")
        XCTAssertEqual(snapshots.first?.subscriptionID, "term_stream")
        await coordinator.stop()
    }
}

private actor FakeTerminalPaneAccess: TerminalPaneAccess {
    private var snapshot: TerminalPaneSnapshot?
    private var receivedInputs: [String] = []

    init(snapshot: TerminalPaneSnapshot?) {
        self.snapshot = snapshot
    }

    func terminalSnapshot(_ name: String) -> TerminalPaneSnapshot? {
        snapshot
    }

    func sendTerminalInput(_ input: String, to name: String) -> Bool {
        receivedInputs.append(input)
        return true
    }

    func setSnapshot(_ snapshot: TerminalPaneSnapshot?) {
        self.snapshot = snapshot
    }

    func inputs() -> [String] {
        receivedInputs
    }
}

private actor TerminalSnapshotRecorder {
    private var snapshots: [RemoteSessionTerminalSnapshot] = []

    func append(_ snapshot: RemoteSessionTerminalSnapshot) {
        snapshots.append(snapshot)
    }

    func count() -> Int {
        snapshots.count
    }

    func values() -> [RemoteSessionTerminalSnapshot] {
        snapshots
    }
}
