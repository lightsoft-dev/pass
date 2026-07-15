import XCTest
@testable import Pass

@MainActor
final class SpecStoreTests: XCTestCase {
    private var root: String!

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spec-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir.resolvingSymlinksInPath().path
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    func testEnsureDocumentCreatesOneFilePerProject() throws {
        let store = SpecStore()
        let doc = try store.ensureDocument(projectRoot: root)
        XCTAssertEqual(doc.title, URL(fileURLWithPath: root).lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: SpecStore.fileURL(projectRoot: root).path))
        // A second call reuses the same document instead of writing another file.
        let again = try store.ensureDocument(projectRoot: root)
        XCTAssertEqual(again.createdAt.timeIntervalSince1970, doc.createdAt.timeIntervalSince1970,
                       accuracy: 1)
    }

    func testSpecNumbersAreStableAndNeverReused() throws {
        let store = SpecStore()
        try store.addSpec(projectRoot: root, title: "로그인")
        try store.addSpec(projectRoot: root, title: "결제")
        try store.addSpec(projectRoot: root, title: "알림")
        XCTAssertEqual(store.document(for: root)?.specs.map(\.number), [1, 2, 3])

        try store.removeSpec(projectRoot: root, number: 2)
        let added = try store.addSpec(projectRoot: root, title: "설정")
        XCTAssertEqual(added.number, 4) // 2 is gone forever — no renumbering, no reuse
        XCTAssertEqual(store.document(for: root)?.specs.map(\.number), [1, 3, 4])
    }

    func testStatusRoundTripsThroughDisk() throws {
        let store = SpecStore()
        try store.addSpec(projectRoot: root, title: "로그인")
        try store.updateSpec(projectRoot: root, number: 1) { $0.status = .needsReview }

        let fresh = SpecStore() // brand-new store: must read state purely from disk
        fresh.reload(projectRoot: root)
        XCTAssertEqual(fresh.document(for: root)?.specs.first?.status, .needsReview)
    }

    func testHandEditedMinimalJSONDecodes() throws {
        // Someone (or an agent) writes a minimal file by hand: defaults fill the rest, and
        // nextNumber self-heals to max(number)+1 so a later addSpec can't collide.
        let json = #"{"specs":[{"number":5,"title":"수동 스펙","status":"nonsense"}]}"#
        let url = SpecStore.fileURL(projectRoot: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)

        let store = SpecStore()
        store.reload(projectRoot: root)
        let doc = try XCTUnwrap(store.document(for: root))
        XCTAssertEqual(doc.specs.first?.status, .draft) // unknown status string → draft
        XCTAssertEqual(doc.nextNumber, 6)
        XCTAssertEqual(try store.addSpec(projectRoot: root, title: "다음").number, 6)
    }

    func testCorruptFileKeepsLastGoodCopyAndReportsError() throws {
        let store = SpecStore()
        try store.addSpec(projectRoot: root, title: "로그인")
        try Data("{broken".utf8).write(to: SpecStore.fileURL(projectRoot: root))

        store.reload(projectRoot: root)
        XCTAssertNotNil(store.errorByProject[root])
        XCTAssertEqual(store.document(for: root)?.specs.count, 1) // in-memory copy survives
    }

    func testWorkingDirectoryCannotEscapeTheProject() throws {
        let store = SpecStore()
        try store.ensureDocument(projectRoot: root)

        try store.updateDevelopment(projectRoot: root) { $0.workingDirectory = "web" }
        XCTAssertEqual(store.developmentWorkingDirectory(projectRoot: root), root + "/web")

        try store.updateDevelopment(projectRoot: root) { $0.workingDirectory = "../outside" }
        XCTAssertNil(store.developmentWorkingDirectory(projectRoot: root))

        try store.updateDevelopment(projectRoot: root) { $0.workingDirectory = "/etc" }
        XCTAssertNil(store.developmentWorkingDirectory(projectRoot: root))
    }
}
