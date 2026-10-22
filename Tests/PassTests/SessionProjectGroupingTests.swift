import XCTest
@testable import Pass

final class SessionProjectGroupingTests: XCTestCase {
    func testInterleavedSessionsStayTogetherUnderTheirProject() {
        var waiting = session("pass-a-waiting", root: "/repos/a")
        waiting.attention = .pending(Attention(kind: .input, receivedAt: Date(), preview: "Question"))
        let other = session("pass-b", root: "/repos/b")
        let worktree = session("pass-a-worktree", root: "/repos/a", cwd: "/worktrees/a-feature")

        let groups = SessionProjectGrouping.groups(
            [waiting, other, worktree],
            projects: [Project(rootPath: "/repos/a", emoji: "🚀")]
        )

        XCTAssertEqual(groups.map(\.id), ["/repos/a", "/repos/b"])
        XCTAssertEqual(groups[0].sessions.map(\.name), ["pass-a-waiting", "pass-a-worktree"])
        XCTAssertEqual(groups[0].emoji, "🚀")
        XCTAssertEqual(groups[0].waitingCount, 1)
        XCTAssertEqual(groups[1].name, "b")
    }

    private func session(_ name: String, root: String, cwd: String? = nil) -> Session {
        Session(name: name, projectRoot: root, cwd: cwd ?? root, agent: .claude,
                git: nil, lastActivity: Date(), isAttached: false)
    }
}
