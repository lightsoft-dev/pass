import XCTest
@testable import Pass

@MainActor
final class FeatureStoreTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func makeProject() throws -> (FeatureStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pass-feature-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return (FeatureStore(), root)
    }

    func testCreateWritesPortableDocumentAndSchema() throws {
        let (store, root) = try makeProject()
        let document = try store.create(projectRoot: root.path, title: "Login flow")

        XCTAssertEqual(document.id, "login-flow")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".pass/features/login-flow.json").path
        ))
        let schemaURL = root.appendingPathComponent(".pass/feature.schema.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: schemaURL.path))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)))
        XCTAssertEqual(store.documents(for: root.path).map(\.id), ["login-flow"])
    }

    func testSaveAndReloadRoundTripsImplementationEvidence() throws {
        let (store, root) = try makeProject()
        var document = try store.create(projectRoot: root.path, title: "Login")
        document.status = .needsReview
        document.development = .init(
            command: "npm run dev",
            workingDirectory: "web",
            url: "http://localhost:3000/login",
            testCommand: "npm test -- login",
            guide: ["Open login", "Submit credentials"]
        )
        document.implementation = .init(
            preferredAgent: .codex,
            agentSession: "pass-app--login",
            summary: "Implemented login",
            files: ["web/Login.swift"],
            checks: [.init(name: "Valid login", status: .passed, details: "Unit test passed")]
        )
        document.reviews = [.init(feedback: "Spinner is too slow")]
        try store.save(document, projectRoot: root.path)

        let reloadedStore = FeatureStore()
        reloadedStore.reload(projectRoot: root.path)
        let reloaded = try XCTUnwrap(reloadedStore.document(projectRoot: root.path, id: "login"))
        XCTAssertEqual(reloaded.status, .needsReview)
        XCTAssertEqual(reloaded.development.testCommand, "npm test -- login")
        XCTAssertEqual(reloaded.implementation.preferredAgent, .codex)
        XCTAssertEqual(reloaded.implementation.checks.first?.status, .passed)
        XCTAssertEqual(reloaded.reviews.first?.feedback, "Spinner is too slow")
    }

    func testWorkingDirectoryCannotEscapeProject() throws {
        let (store, root) = try makeProject()
        var document = FeatureDocument(id: "safe", title: "Safe")

        document.development.workingDirectory = "../../tmp"
        XCTAssertNil(store.developmentWorkingDirectory(for: document, projectRoot: root.path))

        document.development.workingDirectory = "/tmp"
        XCTAssertNil(store.developmentWorkingDirectory(for: document, projectRoot: root.path))

        document.development.workingDirectory = "web"
        XCTAssertEqual(
            store.developmentWorkingDirectory(for: document, projectRoot: root.path),
            root.appendingPathComponent("web").path
        )
    }

    func testMissingImplementationFilesIsDeterministic() throws {
        let (store, root) = try makeProject()
        let existing = root.appendingPathComponent("Sources/Login.swift")
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: existing)
        var document = FeatureDocument(id: "login", title: "Login")
        document.implementation.files = ["Sources/Login.swift", "Sources/Missing.swift", "../escape"]

        XCTAssertEqual(
            store.missingImplementationFiles(for: document, projectRoot: root.path),
            ["Sources/Missing.swift", "../escape"]
        )
    }

    func testReloadSurfacesMalformedCollaborativeJSON() throws {
        let (store, root) = try makeProject()
        let features = root.appendingPathComponent(".pass/features", isDirectory: true)
        try FileManager.default.createDirectory(at: features, withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: features.appendingPathComponent("broken.json"))

        store.reload(projectRoot: root.path)

        XCTAssertTrue(store.documents(for: root.path).isEmpty)
        XCTAssertTrue(store.loadErrorByProject[root.path]?.contains("broken.json") == true)
    }
}
