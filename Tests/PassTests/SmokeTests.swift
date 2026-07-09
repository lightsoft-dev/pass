import XCTest
@testable import Pass

final class SmokeTests: XCTestCase {
    func testConfigPortStable() {
        // The hook port is written into settings.json and snapshotted by Claude sessions
        // at start — it must never drift.
        XCTAssertEqual(PassConfig.hookPort, 49817)
        XCTAssertEqual(PassConfig.hookBaseURL, "http://127.0.0.1:49817")
    }

    func testSessionPrefix() {
        XCTAssertEqual(PassConfig.sessionPrefix, "pass-")
    }
}
