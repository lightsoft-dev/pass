import XCTest
@testable import Pass

final class ProjectWorkerRemovalGuardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func worker(activitySecondsAgo: TimeInterval = 60,
                        attention: AttentionState = .idle,
                        launching: Bool = false) -> Session {
        var session = Session(name: "pass-worker", projectRoot: "/project", cwd: "/project",
                              agent: .claude, attention: attention,
                              lastActivity: now.addingTimeInterval(-activitySecondsAgo),
                              isAttached: false)
        session.launching = launching
        return session
    }

    func testBlocksLaunchingAndWorkingWorkers() {
        XCTAssertNotNil(ProjectWorkerRemovalGuard.rejectionReason(
            for: worker(launching: true), now: now))
        XCTAssertNotNil(ProjectWorkerRemovalGuard.rejectionReason(
            for: worker(attention: .working), now: now))
    }

    func testBlocksWorkersWaitingForInputOrPermission() {
        for kind: Attention.Kind in [.input, .decision] {
            let attention = Attention(kind: kind, receivedAt: now, preview: "Needs an answer")
            XCTAssertNotNil(ProjectWorkerRemovalGuard.rejectionReason(
                for: worker(attention: .pending(attention)), now: now))
        }
    }

    func testRecentActivityNeedsACompletionSignal() {
        XCTAssertNotNil(ProjectWorkerRemovalGuard.rejectionReason(
            for: worker(activitySecondsAgo: 10), now: now))
        XCTAssertNil(ProjectWorkerRemovalGuard.rejectionReason(
            for: worker(activitySecondsAgo: 30), now: now))

        let finished = Attention(kind: .finished, receivedAt: now, preview: "Done")
        XCTAssertNil(ProjectWorkerRemovalGuard.rejectionReason(
            for: worker(activitySecondsAgo: 1, attention: .pending(finished)), now: now))
    }
}
