import XCTest
@testable import Pass

final class SessionAliasTests: XCTestCase {
    func testCustomNameOverridesDerivedDisplayName() {
        var s = Session(name: "pass-x", projectRoot: "/tmp/x", cwd: "/tmp/x", agent: .claude,
                        git: nil, lastActivity: Date(), isAttached: false)
        XCTAssertEqual(s.displayName, "x")
        s.customName = "결제 서버"
        XCTAssertEqual(s.displayName, "결제 서버")
        XCTAssertEqual(s.defaultDisplayName, "x") // the derived name stays reachable
    }

    func testCustomNameKeepsBranchSuffix() {
        // The alias replaces only the repo part — the branch stays: "결제 서버 · main".
        var s = Session(name: "pass-x", projectRoot: "/tmp/x", cwd: "/tmp/x", agent: .claude,
                        git: GitIdentity(root: "/tmp/x", branch: "main", detachedSha: nil,
                                         isLinkedWorktree: false, mainRepoRoot: nil, worktreeDirName: nil),
                        lastActivity: Date(), isAttached: false)
        XCTAssertEqual(s.displayName, "x · main")
        s.customName = "결제 서버"
        XCTAssertEqual(s.displayName, "결제 서버 · main")
    }

    func testCustomNameKeepsWorktreeSuffix() {
        var s = Session(name: "pass-x--feat", projectRoot: "/tmp/x", cwd: "/tmp/x-feat", agent: .claude,
                        git: GitIdentity(root: "/tmp/x-feat", branch: "feat/login", detachedSha: nil,
                                         isLinkedWorktree: true, mainRepoRoot: "/tmp/x", worktreeDirName: "x-feat"),
                        lastActivity: Date(), isAttached: false)
        s.customName = "결제 서버"
        XCTAssertEqual(s.displayName, "결제 서버 ⧉ x-feat · feat/login")
    }

    func testEmptyCustomNameFallsBack() {
        var s = Session(name: "pass-x", projectRoot: "/tmp/x", cwd: "/tmp/x", agent: .claude,
                        git: nil, lastActivity: Date(), isAttached: false)
        s.customName = ""
        XCTAssertEqual(s.displayName, "x")
    }

    func testSnapshotDecodesLegacyStateWithoutAliases() throws {
        // state.json written before the aliases field existed must still decode.
        let legacy = #"{"pending":{},"lastMessages":{"a":"hi"}}"#
        let snap = try JSONDecoder().decode(SessionStatePersistence.Snapshot.self, from: Data(legacy.utf8))
        XCTAssertNil(snap.aliases)
        XCTAssertEqual(snap.lastMessages["a"], "hi")
    }

    func testSnapshotRoundTripsAliases() throws {
        let snap = SessionStatePersistence.Snapshot(
            pending: [:], lastMessages: [:], unacked: [], aliases: ["pass-x": "결제 서버"])
        let back = try JSONDecoder().decode(SessionStatePersistence.Snapshot.self,
                                            from: JSONEncoder().encode(snap))
        XCTAssertEqual(back.aliases?["pass-x"], "결제 서버")
    }
}
