import XCTest
@testable import Pass

/// The /cli/* wire shapes (BROWSER.md §5.4). PassCli mirrors these structs — if a shape
/// changes here, its copy in Sources/PassCli/PassClient.swift must change with it.
@MainActor
final class CLIAPITests: XCTestCase {
    func testOpenRequestDecodesMinimalPayload() throws {
        let req = try JSONDecoder().decode(CLIOpenRequest.self,
                                           from: Data(#"{"url":"5173"}"#.utf8))
        XCTAssertEqual(req.url, "5173")
        XCTAssertNil(req.session)
        XCTAssertNil(req.background)
    }

    func testOpenRequestDecodesFullPayload() throws {
        let json = #"{"session":"pass-a","url":"http://localhost:5173","background":true}"#
        let req = try JSONDecoder().decode(CLIOpenRequest.self, from: Data(json.utf8))
        XCTAssertEqual(req.session, "pass-a")
        XCTAssertEqual(req.background, true)
    }

    func testOpenResponseRoundTrips() throws {
        let resp = CLIOpenResponse(ok: true, tabId: "T", resolvedURL: "http://localhost:5173/")
        let back = try JSONDecoder().decode(CLIOpenResponse.self,
                                            from: JSONEncoder().encode(resp))
        XCTAssertTrue(back.ok)
        XCTAssertEqual(back.tabId, "T")
        XCTAssertEqual(back.resolvedURL, "http://localhost:5173/")
        XCTAssertNil(back.error)
    }

    func testErrorResponseCarriesTheReason() throws {
        let resp = CLIOpenResponse(ok: false, error: "scheme not allowed: javascript:")
        let back = try JSONDecoder().decode(CLIOpenResponse.self,
                                            from: JSONEncoder().encode(resp))
        XCTAssertFalse(back.ok)
        XCTAssertEqual(back.error, "scheme not allowed: javascript:")
    }

    func testTabsResponseShape() throws {
        let tab = CLITabsResponse.Tab(id: "T", session: "pass-a",
                                      url: "https://github.com", title: "GitHub", unseen: true)
        let back = try JSONDecoder().decode(CLITabsResponse.self,
                                            from: JSONEncoder().encode(CLITabsResponse(ok: true, tabs: [tab])))
        XCTAssertEqual(back.tabs.count, 1)
        XCTAssertEqual(back.tabs[0].session, "pass-a")
        XCTAssertTrue(back.tabs[0].unseen)
    }

    func testReadAndScreenshotShapes() throws {
        let read = try JSONDecoder().decode(
            CLIReadResponse.self,
            from: Data(#"{"ok":true,"content":"hello","truncated":true}"#.utf8))
        XCTAssertEqual(read.content, "hello")
        XCTAssertEqual(read.truncated, true)

        let shot = try JSONDecoder().decode(
            CLIScreenshotResponse.self,
            from: Data(#"{"ok":true,"path":"/tmp/x.png"}"#.utf8))
        XCTAssertEqual(shot.path, "/tmp/x.png")
    }

    func testMissingSessionMessagesGuideTheAgent() {
        XCTAssertTrue(CLIAPI.missingSession(nil).contains("--session"))
        XCTAssertTrue(CLIAPI.missingSession(nil).contains("PASS_SESSION"))
        XCTAssertTrue(CLIAPI.missingSession("pass-x").contains("'pass-x'"))
    }
}
