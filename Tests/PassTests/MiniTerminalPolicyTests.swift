import Foundation
import XCTest
@testable import Pass

final class MiniTerminalPolicyTests: XCTestCase {
    func testRecentClipboardValueIsAvailableForFiveMinutes() {
        let copiedAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(RecentClipboardPolicy.isRecent(
            text: "value",
            changedAt: copiedAt,
            now: copiedAt.addingTimeInterval(299)
        ))
        XCTAssertTrue(RecentClipboardPolicy.isRecent(
            text: "value",
            changedAt: copiedAt,
            now: copiedAt.addingTimeInterval(300)
        ))
        XCTAssertFalse(RecentClipboardPolicy.isRecent(
            text: "value",
            changedAt: copiedAt,
            now: copiedAt.addingTimeInterval(301)
        ))
    }

    func testClipboardButtonRequiresNonemptyTextAndTimestamp() {
        let now = Date()

        XCTAssertFalse(RecentClipboardPolicy.isRecent(text: nil, changedAt: now, now: now))
        XCTAssertFalse(RecentClipboardPolicy.isRecent(text: "", changedAt: now, now: now))
        XCTAssertFalse(RecentClipboardPolicy.isRecent(text: "value", changedAt: nil, now: now))
    }

    func testMiniTerminalOnlyShowsForVisibleFocusedSession() {
        XCTAssertTrue(MiniTerminalVisibilityPolicy.shouldShow(
            panelVisible: true,
            focusedSessionName: "pass-a",
            terminalSessionName: "pass-a"
        ))
        XCTAssertFalse(MiniTerminalVisibilityPolicy.shouldShow(
            panelVisible: false,
            focusedSessionName: "pass-a",
            terminalSessionName: "pass-a"
        ))
        XCTAssertFalse(MiniTerminalVisibilityPolicy.shouldShow(
            panelVisible: true,
            focusedSessionName: "pass-b",
            terminalSessionName: "pass-a"
        ))
        XCTAssertFalse(MiniTerminalVisibilityPolicy.shouldShow(
            panelVisible: true,
            focusedSessionName: nil,
            terminalSessionName: "pass-a"
        ))
    }
}
