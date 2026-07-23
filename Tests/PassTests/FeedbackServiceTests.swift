import XCTest
@testable import Pass

final class FeedbackServiceTests: XCTestCase {
    func testBuildsFeedbackEndpointFromDedicatedURL() throws {
        let url = try XCTUnwrap(FeedbackService.endpoint(
            environment: ["PASS_FEEDBACK_URL": "https://feedback.example.com/base/"],
            bundleValues: [:]
        ))

        XCTAssertEqual(url.absoluteString, "https://feedback.example.com/base/v2/feedback")
    }

    func testFallsBackToPublicRelayURL() throws {
        let url = try XCTUnwrap(FeedbackService.endpoint(
            environment: ["PASS_PUBLIC_RELAY_URL": "https://relay.example.com"],
            bundleValues: [:]
        ))

        XCTAssertEqual(url.absoluteString, "https://relay.example.com/v2/feedback")
    }

    func testRejectsInsecureFeedbackURL() {
        XCTAssertNil(FeedbackService.endpoint(
            environment: ["PASS_FEEDBACK_URL": "http://feedback.example.com"],
            bundleValues: [:]
        ))
    }
}
