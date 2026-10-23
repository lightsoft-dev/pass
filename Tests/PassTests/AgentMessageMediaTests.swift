import XCTest
@testable import Pass

final class AgentMessageMediaTests: XCTestCase {
    func testWebPreviewsSkipCodeAndEmbeddedMarkdownImages() {
        let message = """
        [Guide](https://example.com/guide) and https://example.com/guide.
        ![Screenshot](https://example.com/embedded.png)
        `https://example.com/inline`
        ```text
        https://example.com/code
        ```
        https://example.com/standalone.png
        """

        XCTAssertEqual(AgentMessageMedia.webLinks(in: message).map(\.absoluteString),
                       ["https://example.com/guide"])
        XCTAssertEqual(AgentMessageMedia.bareWebImages(in: message).map(\.absoluteString),
                       ["https://example.com/standalone.png"])
    }

    func testBareScreenshotPathsIncludeQuotedSpacesAndRelativeProjectFiles() {
        let root = URL(fileURLWithPath: "/repo", isDirectory: true)
        let message = """
        Screenshot: `/tmp/Screen Shot.png`
        Also saved at ./artifacts/shot.png
        ![Already embedded](file:///tmp/embedded.png)
        ```text
        /tmp/not-a-preview.png
        ```
        """

        XCTAssertEqual(AgentMessageMedia.bareLocalImages(in: message, relativeTo: root)
            .map(\.path), ["/tmp/Screen Shot.png", "/repo/artifacts/shot.png"])
    }
}
