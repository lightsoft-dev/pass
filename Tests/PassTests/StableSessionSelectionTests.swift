import XCTest
@testable import Pass

final class StableSessionSelectionTests: XCTestCase {
    func testReorderingKeepsTheViewedSessionSelected() {
        let selected = StableSessionSelection.resolvedName(
            selectedName: "pass-b",
            oldOrder: ["pass-a", "pass-b", "pass-c"],
            newOrder: ["pass-c", "pass-a", "pass-b"]
        )

        XCTAssertEqual(selected, "pass-b")
    }

    func testRemovingTheViewedSessionSelectsItsNearestNeighbor() {
        let selected = StableSessionSelection.resolvedName(
            selectedName: "pass-b",
            oldOrder: ["pass-a", "pass-b", "pass-c"],
            newOrder: ["pass-a", "pass-c"]
        )

        XCTAssertEqual(selected, "pass-c")
    }

    func testEmptySessionListClearsSelection() {
        XCTAssertNil(
            StableSessionSelection.resolvedName(
                selectedName: "pass-a",
                oldOrder: ["pass-a"],
                newOrder: []
            )
        )
    }
}
