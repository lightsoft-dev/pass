import XCTest
@testable import Pass

/// The SessionStart advertise hook merge (BROWSER.md §5.2-3): same rules as the HTTP hooks —
/// idempotent, never touches entries pass didn't create, removable on its own.
final class AdvertiseHookTests: XCTestCase {
    private func sessionStartGroups(_ root: [String: Any]) -> [[String: Any]] {
        ((root["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]) ?? []
    }

    func testMergedAdvertiseAddsExactlyOnce() {
        let (root, changed) = ClaudeHooksInstaller.mergedAdvertise(into: [:])
        XCTAssertTrue(changed)
        let groups = sessionStartGroups(root)
        XCTAssertEqual(groups.count, 1)
        let hook = (groups[0]["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(hook?["type"] as? String, "command")
        XCTAssertEqual(hook?["command"] as? String, ClaudeHooksInstaller.advertiseCommand)

        let (again, changed2) = ClaudeHooksInstaller.mergedAdvertise(into: root)
        XCTAssertFalse(changed2) // idempotent
        XCTAssertEqual(sessionStartGroups(again).count, 1)
    }

    func testMergedAdvertisePreservesUserSessionStartHooks() {
        let user: [String: Any] = ["hooks": ["SessionStart": [
            ["hooks": [["type": "command", "command": "echo mine"]]],
        ]]]
        let (root, changed) = ClaudeHooksInstaller.mergedAdvertise(into: user)
        XCTAssertTrue(changed)
        let groups = sessionStartGroups(root)
        XCTAssertEqual(groups.count, 2) // user's group + ours
        let firstCommand = (groups[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String
        XCTAssertEqual(firstCommand, "echo mine") // untouched, still first
    }

    func testRemovedAdvertiseStripsOnlyOurs() {
        let user: [String: Any] = ["hooks": ["SessionStart": [
            ["hooks": [["type": "command", "command": "echo mine"]]],
        ]]]
        let (merged, _) = ClaudeHooksInstaller.mergedAdvertise(into: user)
        let (removed, changed) = ClaudeHooksInstaller.removedAdvertise(from: merged)
        XCTAssertTrue(changed)
        let groups = sessionStartGroups(removed)
        XCTAssertEqual(groups.count, 1) // only the user's group survives
        let command = (groups[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String
        XCTAssertEqual(command, "echo mine")

        let (_, changed2) = ClaudeHooksInstaller.removedAdvertise(from: removed)
        XCTAssertFalse(changed2) // removing when absent is a no-op
    }

    func testRemovedAdvertiseDropsTheKeyWhenNothingRemains() {
        let (merged, _) = ClaudeHooksInstaller.mergedAdvertise(into: [:])
        let (removed, changed) = ClaudeHooksInstaller.removedAdvertise(from: merged)
        XCTAssertTrue(changed)
        XCTAssertNil((removed["hooks"] as? [String: Any])?["SessionStart"])
    }

    func testHttpHookMergeStillIdempotentWithAdvertisePresent() {
        // install() layers both merges — make sure they don't disturb each other.
        let (withAdvertise, _) = ClaudeHooksInstaller.mergedAdvertise(into: [:])
        let (withBoth, changedHTTP) = ClaudeHooksInstaller.merged(into: withAdvertise)
        XCTAssertTrue(changedHTTP)
        let (_, changedAdvertise) = ClaudeHooksInstaller.mergedAdvertise(into: withBoth)
        XCTAssertFalse(changedAdvertise)
        XCTAssertEqual(sessionStartGroups(withBoth).count, 1)
    }
}
