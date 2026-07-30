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

    func testBrowserSnapshotWireShapes() throws {
        let minimal = try JSONDecoder().decode(
            CLIBrowserSnapshotRequest.self,
            from: Data(#"{"session":"pass-a"}"#.utf8))
        XCTAssertEqual(minimal.session, "pass-a")
        XCTAssertNil(minimal.all)

        let response = try JSONDecoder().decode(
            CLIBrowserSnapshotResponse.self,
            from: Data(#"""
            {
              "ok": true,
              "url": "https://example.com/form",
              "title": "Example",
              "revision": 7,
              "viewport": {
                "x": 0, "y": 600, "width": 1200, "height": 800,
                "documentWidth": 1200, "documentHeight": 2400
              },
              "elements": [
                {"ref":"@e1","role":"button","name":"Save","tag":"button"}
              ],
              "truncated": true
            }
            """#.utf8))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.revision, 7)
        XCTAssertEqual(response.viewport?.documentHeight, 2400)
        XCTAssertEqual(response.elements.first?.ref, "@e1")
        XCTAssertEqual(response.elements.first?.name, "Save")
        XCTAssertEqual(response.truncated, true)
        XCTAssertNil(response.error)
    }

    func testBrowserActionWireShapes() throws {
        let request = try JSONDecoder().decode(
            CLIBrowserActionRequest.self,
            from: Data(#"""
            {
              "session":"pass-a","action":"fill","ref":"@e12",
              "text":"hello","revision":9
            }
            """#.utf8))
        XCTAssertEqual(request.action, "fill")
        XCTAssertEqual(request.ref, "@e12")
        XCTAssertEqual(request.text, "hello")
        XCTAssertEqual(request.revision, 9)

        let response = try JSONDecoder().decode(
            CLIBrowserActionResponse.self,
            from: Data(#"""
            {
              "ok":true,"action":"click","ref":"@e1",
              "url":"https://example.com/next","title":"Next","revision":10,
              "viewport":{
                "x":0,"y":0,"width":1200,"height":800,
                "documentWidth":1200,"documentHeight":800
              },
              "target":{"ref":"@e1","role":"button","name":"Continue","tag":"button"},
              "snapshotRecommended":true
            }
            """#.utf8))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.action, "click")
        XCTAssertEqual(response.target?.role, "button")
        XCTAssertEqual(response.snapshotRecommended, true)
    }

    func testBrowserElementReferencesAreStrictAndOneBased() {
        XCTAssertTrue(CLIAPI.isValidBrowserElementRef("@e1"))
        XCTAssertTrue(CLIAPI.isValidBrowserElementRef("@e987"))

        for ref in ["", "@e", "@e0", "@e01", "@E1", "e1", "@e-1", "@e１", "@e1x"] {
            XCTAssertFalse(CLIAPI.isValidBrowserElementRef(ref), ref)
        }
    }

    func testBrowserActionRequiredArguments() {
        XCTAssertNotNil(CLIAPI.browserActionValidationError(
            CLIBrowserActionRequest(action: "click")))
        XCTAssertNil(CLIAPI.browserActionValidationError(
            CLIBrowserActionRequest(action: "click", ref: "@e1")))

        for action in ["fill", "type", "select"] {
            XCTAssertNotNil(CLIAPI.browserActionValidationError(
                CLIBrowserActionRequest(action: action, ref: "@e1")))
            XCTAssertNil(CLIAPI.browserActionValidationError(
                CLIBrowserActionRequest(action: action, ref: "@e1", text: "")))
        }

        XCTAssertNotNil(CLIAPI.browserActionValidationError(
            CLIBrowserActionRequest(action: "press")))
        XCTAssertNil(CLIAPI.browserActionValidationError(
            CLIBrowserActionRequest(action: "press", key: "Enter")))
        XCTAssertNil(CLIAPI.browserActionValidationError(
            CLIBrowserActionRequest(action: "press", ref: "@e2", key: "Tab")))
    }

    func testBrowserActionRejectsUnknownActionsAndInvalidRevision() {
        XCTAssertTrue(CLIAPI.browserActionValidationError(
            CLIBrowserActionRequest(action: "hover"))?.contains("unsupported action") == true)
        XCTAssertTrue(CLIAPI.browserActionValidationError(
            CLIBrowserActionRequest(action: "click", ref: "@e0"))?.contains("ref") == true)
        XCTAssertTrue(CLIAPI.browserActionValidationError(
            CLIBrowserActionRequest(action: "click", ref: "@e1", revision: 0))?
            .contains("positive") == true)
    }

    func testBrowserActionEnforcesTextKeyAndScrollBounds() {
        let oversizedText = String(repeating: "a",
                                   count: PassConfig.cliMaxAutomationTextBytes + 1)
        XCTAssertTrue(CLIAPI.browserActionValidationError(
            CLIBrowserActionRequest(action: "fill", ref: "@e1", text: oversizedText))?
            .contains("32 KB") == true)

        let oversizedKey = String(repeating: "k",
                                  count: PassConfig.cliMaxAutomationKeyBytes + 1)
        XCTAssertTrue(CLIAPI.browserActionValidationError(
            CLIBrowserActionRequest(action: "press", key: oversizedKey))?
            .contains("64 bytes") == true)
        XCTAssertTrue(CLIAPI.browserActionValidationError(
            CLIBrowserActionRequest(action: "press", key: String(repeating: "🔑", count: 17)))?
            .contains("64 bytes") == true)

        XCTAssertNil(CLIAPI.browserActionValidationError(
            CLIBrowserActionRequest(action: "scroll", direction: "down")))
        XCTAssertNil(CLIAPI.browserActionValidationError(
            CLIBrowserActionRequest(action: "scroll", direction: "left", amount: 10_000)))
        for amount in [0.0, 10_001.0, Double.infinity] {
            XCTAssertTrue(CLIAPI.browserActionValidationError(
                CLIBrowserActionRequest(action: "scroll", direction: "down", amount: amount))?
                .contains("between 1 and 10000") == true)
        }
        XCTAssertTrue(CLIAPI.browserActionValidationError(
            CLIBrowserActionRequest(action: "scroll", direction: "forward"))?
            .contains("direction") == true)
    }

    func testBrowserAutomationBodiesAreBoundedBeforeAppAccess() async throws {
        let body = Data(repeating: 0x20, count: PassConfig.cliMaxBodyBytes + 1)
        let action = try JSONDecoder().decode(
            CLIBrowserActionResponse.self,
            from: await CLIAPI.action(AppModel(), body: body))
        XCTAssertFalse(action.ok)
        XCTAssertEqual(action.error, "request too large")

        let snapshot = try JSONDecoder().decode(
            CLIBrowserSnapshotResponse.self,
            from: await CLIAPI.snapshot(AppModel(), body: body))
        XCTAssertFalse(snapshot.ok)
        XCTAssertEqual(snapshot.elements, [])
        XCTAssertEqual(snapshot.error, "request too large")
    }

    func testCLIRequestPolicyRejectsBrowserOriginatedPosts() {
        XCTAssertTrue(CLIRequestPolicy.allowsJSON(
            contentType: "application/json", origin: nil))
        XCTAssertTrue(CLIRequestPolicy.allowsJSON(
            contentType: "Application/JSON; charset=utf-8", origin: nil))

        XCTAssertFalse(CLIRequestPolicy.allowsJSON(contentType: nil, origin: nil))
        XCTAssertFalse(CLIRequestPolicy.allowsJSON(
            contentType: "text/plain", origin: nil))
        XCTAssertFalse(CLIRequestPolicy.allowsJSON(
            contentType: "application/json", origin: "https://attacker.example"))
        XCTAssertFalse(CLIRequestPolicy.allowsJSON(
            contentType: "application/json", origin: "null"))
    }

    func testMissingSessionMessagesGuideTheAgent() {
        XCTAssertTrue(CLIAPI.missingSession(nil).contains("--session"))
        XCTAssertTrue(CLIAPI.missingSession(nil).contains("PASS_SESSION"))
        XCTAssertTrue(CLIAPI.missingSession("pass-x").contains("'pass-x'"))
    }

    func testExtensionValidationUsesRuntimeManifestRules() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pass-cli-extension-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"apiVersion":2,"id":"wrong-id","name":"Draft","permissions":["ui:window"],"contributes":{}}"#.utf8)
            .write(to: root.appendingPathComponent("extension.json"))

        let body = try JSONEncoder().encode(CLIExtensionValidateRequest(path: root.path))
        let response = try JSONDecoder().decode(
            CLIExtensionValidateResponse.self,
            from: CLIAPI.validateExtension(body: body))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.id, "wrong-id")
        XCTAssertTrue(response.problems.contains { $0.contains("must match its folder name") })
        XCTAssertNil(response.error)
    }

    func testExtensionValidationAcceptsAValidDraftWithoutEnablingIt() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("pass-cli-extension-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("valid-draft", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"apiVersion":1,"id":"valid-draft","name":"Valid Draft","permissions":["notify"],"contributes":{"commands":[{"id":"hello","title":"Hello","run":{"notify":{"title":"Hello"}}}]}}"#.utf8)
            .write(to: root.appendingPathComponent("extension.json"))

        let body = try JSONEncoder().encode(CLIExtensionValidateRequest(path: root.path))
        let response = try JSONDecoder().decode(
            CLIExtensionValidateResponse.self,
            from: CLIAPI.validateExtension(body: body))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.name, "Valid Draft")
        XCTAssertEqual(response.permissions, ["notify"])
        XCTAssertTrue(response.problems.isEmpty)
    }
}
