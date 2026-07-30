import WebKit
import XCTest
@testable import Pass

@MainActor
final class BrowserAutomationTests: XCTestCase {
    func testSnapshotUsesStableRefsShadowDOMAndRedactsPasswords() async throws {
        let page = await loadPage(
            #"""
            <!doctype html>
            <html>
              <head>
                <title>Automation fixture</title>
                <style>
                  body { margin: 16px; }
                  #far { margin-top: 1800px; }
                </style>
              </head>
              <body>
                <button id="save" aria-label="Save changes">Ignored text</button>
                <label>Account <input id="account" value="alice"></label>
                <label>Secret <input id="secret" type="password" value="do-not-expose"></label>
                <button hidden>Hidden button</button>
                <div style="opacity: 0"><button>Transparent ancestor</button></div>
                <fieldset disabled><button>Inherited disabled</button></fieldset>
                <div id="shadow-host"></div>
                <button id="far">Far away</button>
                <script>
                  const root = document.querySelector("#shadow-host").attachShadow({ mode: "open" });
                  root.innerHTML = '<button aria-label="Inside shadow">Shadow text</button>';
                </script>
              </body>
            </html>
            """#
        )
        defer { page.pool.drop(page.tab.id) }

        let first = try await page.pool.automationSnapshot(
            page.tab.id,
            includeOffscreen: false
        )
        XCTAssertEqual(first.title, "Automation fixture")
        XCTAssertGreaterThan(first.viewport.width, 100)
        XCTAssertGreaterThan(first.viewport.height, 100)
        XCTAssertTrue(first.elements.contains { $0.name == "Save changes" })
        XCTAssertTrue(first.elements.contains { $0.name == "Inside shadow" })
        XCTAssertFalse(first.elements.contains { $0.name == "Hidden button" })
        XCTAssertFalse(first.elements.contains { $0.name == "Transparent ancestor" })
        XCTAssertFalse(first.elements.contains { $0.name == "Far away" })
        XCTAssertEqual(
            first.elements.first { $0.name == "Inherited disabled" }?.disabled,
            true
        )

        let password = try XCTUnwrap(first.elements.first { $0.type == "password" })
        XCTAssertEqual(password.sensitive, true)
        XCTAssertNil(password.value)

        let saveRef = try XCTUnwrap(
            first.elements.first { $0.name == "Save changes" }?.ref
        )
        let second = try await page.pool.automationSnapshot(
            page.tab.id,
            includeOffscreen: true
        )
        XCTAssertGreaterThan(second.revision, first.revision)
        XCTAssertEqual(
            second.elements.first { $0.name == "Save changes" }?.ref,
            saveRef
        )
        XCTAssertTrue(second.elements.contains { $0.name == "Far away" })
    }

    func testClickFillAndTypeSupportUnicodeAndQuotes() async throws {
        let page = await loadPage(
            #"""
            <!doctype html>
            <html>
              <head><title>Actions</title></head>
              <body>
                <button id="run" onclick="document.body.dataset.clicked = 'yes'">Run</button>
                <label for="name">Name</label>
                <input id="name" value="" oninput="document.body.dataset.inputValue = this.value">
              </body>
            </html>
            """#
        )
        defer { page.pool.drop(page.tab.id) }

        let snapshot = try await page.pool.automationSnapshot(
            page.tab.id,
            includeOffscreen: false
        )
        let button = try XCTUnwrap(snapshot.elements.first { $0.name == "Run" })
        let field = try XCTUnwrap(snapshot.elements.first { $0.name == "Name" })

        let clicked = try await page.pool.performAutomationAction(
            page.tab.id,
            action: BrowserAutomationAction(
                action: "click",
                ref: button.ref,
                revision: snapshot.revision
            )
        )
        XCTAssertEqual(clicked.target?.ref, button.ref)
        XCTAssertTrue(clicked.snapshotRecommended)
        let clickedMarker = try await javaScriptString(
            "document.body.dataset.clicked",
            in: page.webView
        )
        XCTAssertEqual(clickedMarker, "yes")

        let text = #"한글 'single' "double" \ path"#
        let filled = try await page.pool.performAutomationAction(
            page.tab.id,
            action: BrowserAutomationAction(
                action: "fill",
                ref: field.ref,
                text: text,
                revision: clicked.revision
            )
        )
        XCTAssertEqual(filled.target?.value, text)
        let fieldValue = try await javaScriptString(
            "document.querySelector('#name').value",
            in: page.webView
        )
        let inputEventValue = try await javaScriptString(
            "document.body.dataset.inputValue",
            in: page.webView
        )
        XCTAssertEqual(fieldValue, text)
        XCTAssertEqual(inputEventValue, text)

        let typed = try await page.pool.performAutomationAction(
            page.tab.id,
            action: BrowserAutomationAction(
                action: "type",
                ref: field.ref,
                text: " +추가",
                revision: filled.revision
            )
        )
        XCTAssertEqual(typed.target?.value, text + " +추가")

        let pressed = try await page.pool.performAutomationAction(
            page.tab.id,
            action: BrowserAutomationAction(
                action: "press",
                key: "!",
                revision: typed.revision
            )
        )
        XCTAssertNil(pressed.target)
        let valueAfterPress = try await javaScriptString(
            "document.querySelector('#name').value",
            in: page.webView
        )
        XCTAssertEqual(valueAfterPress, text + " +추가!")
    }

    func testScrollRevisionMismatchAndDetachedRefAreRejected() async throws {
        let page = await loadPage(
            #"""
            <!doctype html>
            <html>
              <head>
                <style>
                  body { min-height: 3200px; margin: 0; }
                  #victim { margin: 20px; }
                </style>
              </head>
              <body><button id="victim">Replace me</button></body>
            </html>
            """#
        )
        defer { page.pool.drop(page.tab.id) }

        let snapshot = try await page.pool.automationSnapshot(
            page.tab.id,
            includeOffscreen: true
        )
        let victim = try XCTUnwrap(snapshot.elements.first { $0.name == "Replace me" })
        let scrolled = try await page.pool.performAutomationAction(
            page.tab.id,
            action: BrowserAutomationAction(
                action: "scroll",
                direction: "down",
                amount: 700,
                revision: snapshot.revision
            )
        )
        XCTAssertGreaterThan(scrolled.viewport.y, 0)

        do {
            _ = try await page.pool.performAutomationAction(
                page.tab.id,
                action: BrowserAutomationAction(
                    action: "scroll",
                    direction: "down",
                    amount: 20,
                    revision: snapshot.revision
                )
            )
            XCTFail("Expected a stale revision error")
        } catch let error as BrowserAutomationError {
            XCTAssertEqual(
                error,
                .staleRevision(expected: snapshot.revision, actual: scrolled.revision)
            )
        }

        _ = try await page.webView.evaluateJavaScript(
            "document.querySelector('#victim').replaceWith(document.querySelector('#victim').cloneNode(true))"
        )
        do {
            _ = try await page.pool.performAutomationAction(
                page.tab.id,
                action: BrowserAutomationAction(
                    action: "click",
                    ref: victim.ref,
                    revision: scrolled.revision
                )
            )
            XCTFail("Expected a stale ref error")
        } catch let error as BrowserAutomationError {
            XCTAssertEqual(error, .staleReference(victim.ref))
        }
    }

    func testNavigationInvalidatesRefLessActionsUntilANewSnapshot() async throws {
        let page = await loadPage(
            #"""
            <!doctype html>
            <html>
              <body style="min-height: 3000px">
                <input id="field" value="before" autofocus>
              </body>
            </html>
            """#
        )
        defer { page.pool.drop(page.tab.id) }

        let snapshot = try await page.pool.automationSnapshot(
            page.tab.id,
            includeOffscreen: true
        )
        _ = try await page.webView.evaluateJavaScript(
            #"history.pushState({}, "", "/different-route")"#
        )

        do {
            _ = try await page.pool.performAutomationAction(
                page.tab.id,
                action: BrowserAutomationAction(
                    action: "scroll",
                    direction: "down",
                    amount: 100,
                    revision: snapshot.revision
                )
            )
            XCTFail("Expected same-document navigation to require a new snapshot")
        } catch let error as BrowserAutomationError {
            XCTAssertEqual(error, .snapshotRequired)
        }

        let afterRouteChange = try await page.pool.automationSnapshot(
            page.tab.id,
            includeOffscreen: true
        )
        page.webView.loadHTMLString(
            "<!doctype html><html><body><button autofocus>New document</button></body></html>",
            baseURL: URL(string: "https://automation.test/new-document")!
        )
        await page.pool.awaitLoaded(page.tab.id)

        do {
            _ = try await page.pool.performAutomationAction(
                page.tab.id,
                action: BrowserAutomationAction(
                    action: "press",
                    key: "Enter",
                    revision: afterRouteChange.revision
                )
            )
            XCTFail("Expected full navigation to require a new snapshot")
        } catch let error as BrowserAutomationError {
            XCTAssertEqual(error, .snapshotRequired)
        }
    }

    func testReadonlyFieldsStayUnchangedAndNonTextSelectionDoesNotPartiallyFail() async throws {
        let page = await loadPage(
            #"""
            <!doctype html>
            <html>
              <body>
                <label>Locked <input id="locked" value="keep" readonly></label>
                <label>Quantity <input id="quantity" type="number" value="1"></label>
                <label>Email <input id="email" type="email" value="a"></label>
              </body>
            </html>
            """#
        )
        defer { page.pool.drop(page.tab.id) }

        let snapshot = try await page.pool.automationSnapshot(
            page.tab.id,
            includeOffscreen: true
        )
        let locked = try XCTUnwrap(snapshot.elements.first { $0.name == "Locked" })
        let quantity = try XCTUnwrap(snapshot.elements.first { $0.name == "Quantity" })
        let email = try XCTUnwrap(snapshot.elements.first { $0.name == "Email" })

        do {
            _ = try await page.pool.performAutomationAction(
                page.tab.id,
                action: BrowserAutomationAction(
                    action: "fill",
                    ref: locked.ref,
                    text: "replace",
                    revision: snapshot.revision
                )
            )
            XCTFail("Expected readonly fill to be rejected")
        } catch let error as BrowserAutomationError {
            XCTAssertEqual(error, .invalidArgument("fill target is readonly"))
        }
        let lockedAfterFill = try await javaScriptString(
            "document.querySelector('#locked').value",
            in: page.webView
        )
        XCTAssertEqual(lockedAfterFill, "keep")

        let filledNumber = try await page.pool.performAutomationAction(
            page.tab.id,
            action: BrowserAutomationAction(
                action: "fill",
                ref: quantity.ref,
                text: "42",
                revision: snapshot.revision
            )
        )
        XCTAssertEqual(filledNumber.target?.value, "42")

        let typedEmail = try await page.pool.performAutomationAction(
            page.tab.id,
            action: BrowserAutomationAction(
                action: "type",
                ref: email.ref,
                text: "@example.com",
                revision: filledNumber.revision
            )
        )
        XCTAssertEqual(typedEmail.target?.value, "a@example.com")

        do {
            _ = try await page.pool.performAutomationAction(
                page.tab.id,
                action: BrowserAutomationAction(
                    action: "press",
                    ref: locked.ref,
                    key: "!",
                    revision: typedEmail.revision
                )
            )
            XCTFail("Expected readonly character press to be rejected")
        } catch let error as BrowserAutomationError {
            XCTAssertEqual(error, .invalidArgument("press target is readonly"))
        }
        let lockedAfterPress = try await javaScriptString(
            "document.querySelector('#locked').value",
            in: page.webView
        )
        XCTAssertEqual(lockedAfterPress, "keep")
    }

    func testPressImplementsActivationAndRejectsUnsupportedNoOps() async throws {
        let page = await loadPage(
            #"""
            <!doctype html>
            <html>
              <body>
                <label>Accept <input id="accept" type="checkbox"></label>
                <a id="link" href="#ignored"
                   onclick="event.preventDefault(); document.body.dataset.link = 'yes'">Open</a>
              </body>
            </html>
            """#
        )
        defer { page.pool.drop(page.tab.id) }

        let snapshot = try await page.pool.automationSnapshot(
            page.tab.id,
            includeOffscreen: true
        )
        let checkbox = try XCTUnwrap(snapshot.elements.first { $0.name == "Accept" })
        let link = try XCTUnwrap(snapshot.elements.first { $0.name == "Open" })

        let checked = try await page.pool.performAutomationAction(
            page.tab.id,
            action: BrowserAutomationAction(
                action: "press",
                ref: checkbox.ref,
                key: "Space",
                revision: snapshot.revision
            )
        )
        let checkedValue = try await javaScriptString(
            "String(document.querySelector('#accept').checked)",
            in: page.webView
        )
        XCTAssertEqual(checkedValue, "true")

        do {
            _ = try await page.pool.performAutomationAction(
                page.tab.id,
                action: BrowserAutomationAction(
                    action: "press",
                    ref: checkbox.ref,
                    key: "ArrowDown",
                    revision: checked.revision
                )
            )
            XCTFail("Expected an unsupported synthetic default action to be rejected")
        } catch let error as BrowserAutomationError {
            XCTAssertEqual(
                error,
                .invalidArgument("key ArrowDown is not supported for the current press target")
            )
        }

        let activatedLink = try await page.pool.performAutomationAction(
            page.tab.id,
            action: BrowserAutomationAction(
                action: "press",
                ref: link.ref,
                key: "Enter",
                revision: checked.revision
            )
        )
        XCTAssertEqual(activatedLink.target?.ref, link.ref)
        let linkMarker = try await javaScriptString(
            "document.body.dataset.link",
            in: page.webView
        )
        XCTAssertEqual(linkMarker, "yes")
    }

    func testSnapshotVisibilityDisabledStateAndMutableFingerprintMatchActions() async throws {
        let page = await loadPage(
            #"""
            <!doctype html>
            <html>
              <body>
                <fieldset disabled><button id="inherited">Inherited disabled</button></fieldset>
                <div style="opacity: 0"><button id="invisible">Invisible ancestor</button></div>
                <label>Choice <input id="choice" type="checkbox"></label>
              </body>
            </html>
            """#
        )
        defer { page.pool.drop(page.tab.id) }

        let snapshot = try await page.pool.automationSnapshot(
            page.tab.id,
            includeOffscreen: true
        )
        XCTAssertEqual(
            snapshot.elements.first { $0.name == "Inherited disabled" }?.disabled,
            true
        )
        XCTAssertFalse(snapshot.elements.contains { $0.name == "Invisible ancestor" })

        let choice = try XCTUnwrap(snapshot.elements.first { $0.name == "Choice" })
        _ = try await page.webView.evaluateJavaScript(
            "document.querySelector('#choice').checked = true"
        )
        do {
            _ = try await page.pool.performAutomationAction(
                page.tab.id,
                action: BrowserAutomationAction(
                    action: "click",
                    ref: choice.ref,
                    revision: snapshot.revision
                )
            )
            XCTFail("Expected changed action state to invalidate the old ref")
        } catch let error as BrowserAutomationError {
            XCTAssertEqual(error, .staleReference(choice.ref))
        }
    }

    func testSnapshotCapsInteractiveElementsAtTwoHundred() async throws {
        let longValue = String(repeating: "값", count: 2_500)
        let longTitle = String(repeating: "T", count: 2_500)
        let buttons = (0..<205).map { "<button>Button \($0)</button>" }.joined()
        let page = await loadPage(
            """
            <!doctype html><html><head><title>\(longTitle)</title></head><body>
            <textarea aria-label="Long value">\(longValue)</textarea>
            \(buttons)
            </body></html>
            """
        )
        defer { page.pool.drop(page.tab.id) }

        let snapshot = try await page.pool.automationSnapshot(
            page.tab.id,
            includeOffscreen: true
        )
        XCTAssertEqual(snapshot.elements.count, 200)
        XCTAssertTrue(snapshot.truncated)
        XCTAssertEqual(snapshot.title.utf16.count, 2_000)
        let boundedValue = try XCTUnwrap(
            snapshot.elements.first { $0.name == "Long value" }?.value
        )
        XCTAssertEqual(boundedValue.utf16.count, 2_000)
    }

    func testUnknownPoolIDProducesAgentFacingError() async {
        let pool = WebViewPool()
        do {
            _ = try await pool.automationSnapshot(UUID(), includeOffscreen: false)
            XCTFail("Expected a missing tab error")
        } catch let error as BrowserAutomationError {
            XCTAssertEqual(error, .tabNotFound)
            XCTAssertTrue(error.localizedDescription.contains("tab_not_found"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private struct TestPage {
        let pool: WebViewPool
        let tab: BrowserTab
        let webView: WKWebView
    }

    private func loadPage(_ html: String) async -> TestPage {
        let pool = WebViewPool()
        let tab = BrowserTab(
            id: UUID(),
            sessionName: "automation-test",
            url: URL(string: "about:blank")!,
            title: nil,
            lastVisited: Date()
        )
        let webView = pool.webView(for: tab)
        webView.loadHTMLString(
            html,
            baseURL: URL(string: "https://automation.test/")!
        )
        await pool.awaitLoaded(tab.id)

        for _ in 0..<20 {
            let ready = try? await javaScriptString("document.readyState", in: webView)
            if ready == "complete" { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return TestPage(pool: pool, tab: tab, webView: webView)
    }

    private func javaScriptString(_ script: String, in webView: WKWebView) async throws -> String {
        let result = try await webView.evaluateJavaScript(script)
        return try XCTUnwrap(result as? String)
    }
}
