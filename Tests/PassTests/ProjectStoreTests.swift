import XCTest
@testable import Pass

@MainActor
final class ProjectStoreTests: XCTestCase {
    private func makeStore() -> (ProjectStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pass-projects-\(UUID().uuidString).json")
        return (ProjectStore(fileURL: url), url)
    }

    // MARK: create / register

    func testRememberRegistersAndDedupesToFront() {
        let (store, _) = makeStore()
        store.remember(rootPath: "/a")
        store.remember(rootPath: "/b")
        store.remember(rootPath: "/a") // re-remember → moves to front, no duplicate
        XCTAssertEqual(store.projects.map(\.rootPath), ["/a", "/b"])
    }

    func testRememberIfNewSkipsExisting() {
        let (store, _) = makeStore()
        store.remember(rootPath: "/a")
        store.rememberIfNew(rootPath: "/a") // already known → no-op, no reorder
        store.rememberIfNew(rootPath: "/b")
        XCTAssertEqual(store.projects.map(\.rootPath), ["/a", "/b"])
    }

    func testRememberExistingProjectPreservesEmoji() {
        let (store, _) = makeStore()
        store.remember(rootPath: "/a")
        store.remember(rootPath: "/b")
        store.setEmoji(rootPath: "/a", "🚀")

        store.remember(rootPath: "/a")

        XCTAssertEqual(store.projects.map(\.rootPath), ["/a", "/b"])
        XCTAssertEqual(store.emoji(forRoot: "/a"), "🚀")
    }

    // MARK: delete

    func testForgetRemoves() {
        let (store, _) = makeStore()
        store.remember(rootPath: "/a")
        store.remember(rootPath: "/b")
        store.forget(rootPath: "/a")
        XCTAssertEqual(store.projects.map(\.rootPath), ["/b"])
    }

    func testForgetOnlyTargetsTheRequestedRoot() {
        // Regression guard for "the wrong item got removed": forget must remove exactly one root.
        let (store, _) = makeStore()
        ["/x", "/y", "/z"].forEach { store.remember(rootPath: $0) } // front→back: z, y, x
        store.forget(rootPath: "/y")
        XCTAssertEqual(Set(store.projects.map(\.rootPath)), ["/x", "/z"])
    }

    // MARK: edit (emoji)

    func testSetEmojiEditsAndReads() {
        let (store, _) = makeStore()
        store.remember(rootPath: "/a")
        store.setEmoji(rootPath: "/a", "🚀")
        XCTAssertEqual(store.emoji(forRoot: "/a"), "🚀")
    }

    func testSetEmojiClearsWithEmptyOrNil() {
        let (store, _) = makeStore()
        store.remember(rootPath: "/a")
        store.setEmoji(rootPath: "/a", "🚀")
        store.setEmoji(rootPath: "/a", "  ") // whitespace → clear
        XCTAssertNil(store.emoji(forRoot: "/a"))
    }

    func testSetEmojiCapsAtTwoClusters() {
        let (store, _) = makeStore()
        store.remember(rootPath: "/a")
        store.setEmoji(rootPath: "/a", "🚀🔥🐛") // keep only the first two
        XCTAssertEqual(store.emoji(forRoot: "/a"), "🚀🔥")
    }

    func testSetEmojiUnknownRootIsNoop() {
        let (store, _) = makeStore()
        store.remember(rootPath: "/a")
        store.setEmoji(rootPath: "/missing", "🚀")
        XCTAssertNil(store.emoji(forRoot: "/missing"))
        XCTAssertNil(store.emoji(forRoot: "/a"))
    }

    // MARK: persistence

    func testPersistsAcrossReload() {
        let (store, url) = makeStore()
        store.remember(rootPath: "/a")
        store.setEmoji(rootPath: "/a", "🎯")
        // A fresh store on the same file sees the registration + emoji.
        let reloaded = ProjectStore(fileURL: url)
        XCTAssertEqual(reloaded.projects.map(\.rootPath), ["/a"])
        XCTAssertEqual(reloaded.emoji(forRoot: "/a"), "🎯")
    }

    // MARK: project directories

    func testRememberDirectoryNormalizesDedupesAndPersists() {
        let (store, url) = makeStore()
        XCTAssertTrue(store.rememberDirectory(path: "/work/projects/../projects"))
        XCTAssertFalse(store.rememberDirectory(path: "/work/projects"))
        XCTAssertEqual(store.projectDirectories, ["/work/projects"])

        let reloaded = ProjectStore(fileURL: url)
        XCTAssertEqual(reloaded.projectDirectories, ["/work/projects"])
    }

    func testForgetDirectoryDoesNotDeleteKnownProjects() {
        let (store, _) = makeStore()
        store.remember(rootPath: "/work/projects/pass")
        store.rememberDirectory(path: "/work/projects")

        store.forgetDirectory(path: "/work/projects")

        XCTAssertTrue(store.projectDirectories.isEmpty)
        XCTAssertEqual(store.projects.map(\.rootPath), ["/work/projects/pass"])
    }

    func testCountsProjectsInsideDirectoryWithoutPrefixCollisions() {
        let (store, _) = makeStore()
        store.remember(rootPath: "/work/projects/pass")
        store.remember(rootPath: "/work/projects-two/other")
        store.remember(rootPath: "/work/projects")

        XCTAssertEqual(store.projectCount(inDirectory: "/work/projects"), 2)
    }

    func testLegacyProjectsSeedParentDirectoriesOnce() throws {
        let (_, url) = makeStore()
        let legacyProjects = [
            Project(rootPath: "/work/projects/pass"),
            Project(rootPath: "/work/projects/another"),
            Project(rootPath: "/other/tool")
        ]
        try JSONEncoder().encode(legacyProjects).write(to: url)

        let migrated = ProjectStore(fileURL: url)
        XCTAssertEqual(migrated.projectDirectories, ["/other", "/work/projects"])

        migrated.projectDirectories.forEach { migrated.forgetDirectory(path: $0) }
        let reloaded = ProjectStore(fileURL: url)
        XCTAssertTrue(reloaded.projectDirectories.isEmpty)
    }
}
