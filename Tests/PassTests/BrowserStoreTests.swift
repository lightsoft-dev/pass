import XCTest
@testable import Pass

@MainActor
final class BrowserStoreTests: XCTestCase {
    private func makeStore() -> BrowserStore { BrowserStore(persisting: false) }
    private let u1 = URL(string: "http://localhost:5173")!
    private let u2 = URL(string: "https://github.com")!

    func testOpenCreatesThenReusesTheSessionTab() {
        let store = makeStore()
        let first = store.open(url: u1, session: "pass-a")
        let second = store.open(url: u2, session: "pass-a")
        XCTAssertEqual(first.id, second.id) // v1: reuse — agent loops never grow tabs
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tab(for: "pass-a")?.url, u2)
    }

    func testSessionsGetSeparateTabs() {
        let store = makeStore()
        store.open(url: u1, session: "pass-a")
        store.open(url: u2, session: "pass-b")
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.tab(for: "pass-a")?.url, u1)
        XCTAssertEqual(store.tab(for: "pass-b")?.url, u2)
    }

    func testUnseenBadgeLifecycle() {
        let store = makeStore()
        store.open(url: u1, session: "pass-a", markUnseen: true) // background/unfocused open
        XCTAssertTrue(store.hasUnseen("pass-a"))
        store.markSeen("pass-a")
        XCTAssertFalse(store.hasUnseen("pass-a"))
        // A later foreground open clears a stale badge by itself.
        store.open(url: u1, session: "pass-a", markUnseen: true)
        store.open(url: u2, session: "pass-a")
        XCTAssertFalse(store.hasUnseen("pass-a"))
    }

    func testToggleHiddenKeepsTheTab() {
        let store = makeStore()
        XCTAssertFalse(store.toggleHidden(session: "pass-a")) // no tab yet → caller opens blank
        store.open(url: u1, session: "pass-a")
        XCTAssertNotNil(store.visibleTab(for: "pass-a"))
        XCTAssertTrue(store.toggleHidden(session: "pass-a")) // ⌘B off
        XCTAssertNil(store.visibleTab(for: "pass-a"))
        XCTAssertNotNil(store.tab(for: "pass-a")) // hidden ≠ closed
        store.open(url: u2, session: "pass-a") // an explicit open re-shows the split
        XCTAssertNotNil(store.visibleTab(for: "pass-a"))
    }

    func testCloseReleasesTheWebViewViaCallback() {
        let store = makeStore()
        var dropped: [UUID] = []
        store.onTabClosed = { dropped.append($0) }
        let tab = store.open(url: u1, session: "pass-a")
        store.close(session: "pass-a")
        XCTAssertEqual(dropped, [tab.id])
        XCTAssertNil(store.tab(for: "pass-a"))
        XCTAssertTrue(store.tabs.isEmpty)
    }

    func testOpenDrivesTheLoadCallback() {
        let store = makeStore()
        var loaded: [URL] = []
        store.onTabOpened = { loaded.append($0.url) }
        store.open(url: u1, session: "pass-a")
        store.open(url: u2, session: "pass-a")
        XCTAssertEqual(loaded, [u1, u2]) // loads are store-driven, never render-driven
    }

    func testPruneDropsDeadSessionsOnly() {
        let store = makeStore()
        var dropped: [UUID] = []
        store.onTabClosed = { dropped.append($0) }
        let dead = store.open(url: u1, session: "pass-a")
        store.open(url: u2, session: "pass-b")
        store.pruneSessions(alive: ["pass-b"])
        XCTAssertNil(store.tab(for: "pass-a"))
        XCTAssertNotNil(store.tab(for: "pass-b"))
        XCTAssertEqual(dropped, [dead.id])
    }

    func testRecentsDedupeAndCapAtTwenty() {
        let store = makeStore()
        for i in 0..<30 {
            store.open(url: URL(string: "http://localhost:\(3000 + i)")!, session: "pass-a")
        }
        XCTAssertEqual(store.recentURLs(for: "pass-a").count, 20)
        let repeated = URL(string: "http://localhost:3029")!
        store.open(url: repeated, session: "pass-a") // re-open → front, no duplicate
        XCTAssertEqual(store.recentURLs(for: "pass-a").first, repeated)
        XCTAssertEqual(store.recentURLs(for: "pass-a").count, 20)
    }

    func testMirrorUpdatesNavigationFacts() {
        let store = makeStore()
        let tab = store.open(url: u1, session: "pass-a")
        store.mirror(tabId: tab.id, url: u2, title: "GitHub", canGoBack: true, canGoForward: false)
        let after = store.tab(for: "pass-a")
        XCTAssertEqual(after?.url, u2)
        XCTAssertEqual(after?.title, "GitHub")
        XCTAssertEqual(after?.canGoBack, true)
        XCTAssertEqual(after?.canGoForward, false)
    }

    // MARK: persistence shape (the snapshot field BrowserStore owns)

    func testSnapshotDecodesLegacyStateWithoutBrowserURLs() throws {
        let legacy = #"{"pending":{},"lastMessages":{"a":"hi"}}"#
        let snap = try JSONDecoder().decode(SessionStatePersistence.Snapshot.self,
                                            from: Data(legacy.utf8))
        XCTAssertNil(snap.browserURLs)
    }

    func testSnapshotRoundTripsBrowserURLs() throws {
        var snap = SessionStatePersistence.Snapshot()
        snap.browserURLs = ["pass-a": "http://localhost:5173"]
        let back = try JSONDecoder().decode(SessionStatePersistence.Snapshot.self,
                                            from: JSONEncoder().encode(snap))
        XCTAssertEqual(back.browserURLs?["pass-a"], "http://localhost:5173")
    }
}
