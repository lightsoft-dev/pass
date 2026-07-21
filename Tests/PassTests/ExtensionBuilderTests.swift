import XCTest
@testable import Pass

@MainActor
final class ExtensionBuilderTests: XCTestCase {
    private struct Snapshot: Codable { var builds: [ExtensionBuild] }

    func testStopBuildsBoundedReviewThenExplicitApprovalEnables() async throws {
        let fixture = try makeFixture(id: "review-me", manifest: #"""
        {
          "apiVersion": 2,
          "id": "review-me",
          "name": "Review Me",
          "permissions": ["ui:window", "session:read"],
          "contributes": {
            "windows": [{"id":"main","title":"Review Me","entry":"ui/index.html"}],
            "commands": [{"id":"review-me","title":"Open Review Me","run":{"openWindow":"main"}}]
          }
        }
        """#)
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.extensionDirectory.appendingPathComponent("ui"),
            withIntermediateDirectories: true)
        try Data("<h1>generated</h1>".utf8)
            .write(to: fixture.extensionDirectory.appendingPathComponent("ui/index.html"))
        try Data("Uses a separate UI window and read-only session snapshot.".utf8)
            .write(to: fixture.extensionDirectory.appendingPathComponent("SUMMARY.md"))
        try Data("hidden files must be reviewable".utf8)
            .write(to: fixture.extensionDirectory.appendingPathComponent(".review-note"))

        let build = ExtensionBuild(extensionId: "review-me", goal: "show my sessions",
                                   sessionName: "pass-review-me", status: .generating,
                                   createdAt: Date(), updatedAt: Date())
        try JSONEncoder().encode(Snapshot(builds: [build])).write(to: fixture.stateURL)
        let builder = ExtensionBuilder(store: fixture.store, sessions: fixture.sessions,
                                       stateURL: fixture.stateURL)

        builder.attentionPending(
            sessionName: "pass-review-me",
            attention: Attention(kind: .finished, receivedAt: Date(), preview: "done"))

        XCTAssertEqual(builder.builds.first?.status, .needsReview)
        XCTAssertEqual(builder.builds.first?.summary,
                       "Uses a separate UI window and read-only session snapshot.")
        let review = try XCTUnwrap(builder.review(for: "review-me"))
        XCTAssertTrue(review.canApprove)
        XCTAssertEqual(review.permissions, ["session:read", "ui:window"])
        XCTAssertEqual(review.commands, [">review-me — Open Review Me [global]"])
        XCTAssertEqual(review.windows, ["main — Review Me"])
        XCTAssertTrue(review.files.contains { $0.path == "extension.json" && $0.content != nil })
        XCTAssertTrue(review.files.contains { $0.path == "ui/index.html" && $0.content != nil })
        XCTAssertTrue(review.files.contains { $0.path == ".review-note" && $0.content != nil })
        XCTAssertFalse(fixture.store.isEnabled("review-me"))

        let approval = await builder.approve(extensionId: "review-me")
        XCTAssertEqual(approval, .success("review-me"))
        XCTAssertTrue(fixture.store.isEnabled("review-me"))
        XCTAssertEqual(builder.builds.first?.status, .approved)
        builder.refreshReview(extensionId: "review-me")
        XCTAssertEqual(builder.builds.first?.status, .approved)
        try Data("<h1>changed after approval</h1>".utf8)
            .write(to: fixture.extensionDirectory.appendingPathComponent("ui/index.html"))
        builder.refreshReview(extensionId: "review-me")
        XCTAssertEqual(builder.builds.first?.status, .needsReview)
        XCTAssertFalse(fixture.store.isEnabled("review-me"))
    }

    func testInvalidGeneratedManifestCanBeReviewedButNotApproved() async throws {
        let fixture = try makeFixture(id: "broken", manifest: #"""
        {
          "apiVersion": 2,
          "id": "broken",
          "name": "Broken",
          "permissions": [],
          "contributes": {
            "windows": [{"id":"main","title":"Broken","entry":"missing.html"}]
          }
        }
        """#)
        defer { fixture.cleanup() }
        let build = ExtensionBuild(extensionId: "broken", goal: "broken draft",
                                   status: .needsReview, createdAt: Date(), updatedAt: Date())
        try JSONEncoder().encode(Snapshot(builds: [build])).write(to: fixture.stateURL)
        let builder = ExtensionBuilder(store: fixture.store, sessions: fixture.sessions,
                                       stateURL: fixture.stateURL)

        builder.refreshReview(extensionId: "broken")

        let review = try XCTUnwrap(builder.review(for: "broken"))
        XCTAssertFalse(review.canApprove)
        XCTAssertTrue(review.problems.contains { $0.contains("permission \"ui:window\" not declared") })
        let approval = await builder.approve(extensionId: "broken")
        if case .failure = approval {} else {
            XCTFail("invalid generated files must never be enabled")
        }
        XCTAssertFalse(fixture.store.isEnabled("broken"))
    }

    func testApprovalRefusesFilesChangedSinceTheDisplayedReview() async throws {
        let manifest = #"{"apiVersion":1,"id":"moving-target","name":"Moving Target","permissions":[],"contributes":{}}"#
        let fixture = try makeFixture(id: "moving-target", manifest: manifest)
        defer { fixture.cleanup() }
        let build = ExtensionBuild(extensionId: "moving-target", goal: "test fingerprint",
                                   status: .needsReview, createdAt: Date(), updatedAt: Date())
        try JSONEncoder().encode(Snapshot(builds: [build])).write(to: fixture.stateURL)
        let builder = ExtensionBuilder(store: fixture.store, sessions: fixture.sessions,
                                       stateURL: fixture.stateURL)
        builder.refreshReview(extensionId: "moving-target")

        try Data((manifest + "\n").utf8)
            .write(to: fixture.extensionDirectory.appendingPathComponent("extension.json"))

        let firstApproval = await builder.approve(extensionId: "moving-target")
        XCTAssertEqual(
            firstApproval,
            .failure("Files changed after the review was loaded. Review the new content before enabling."))
        XCTAssertFalse(fixture.store.isEnabled("moving-target"))
        let secondApproval = await builder.approve(extensionId: "moving-target")
        XCTAssertEqual(secondApproval, .success("moving-target"))
    }

    private struct Fixture {
        var root: URL
        var extensionDirectory: URL
        var stateURL: URL
        var store: ExtensionStore
        var sessions: SessionStore
        var defaults: UserDefaults
        var suiteName: String

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeFixture(id: String, manifest: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pass-builder-\(UUID().uuidString)", isDirectory: true)
        let extensions = root.appendingPathComponent("extensions", isDirectory: true)
        let directory = extensions.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("extension.json"))
        let stateURL = root.appendingPathComponent("extension-builds.json")
        let suite = "ExtensionBuilderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = ExtensionStore(directory: extensions, defaults: defaults)
        let projects = ProjectStore(fileURL: root.appendingPathComponent("projects.json"))
        let sessions = SessionStore(tmux: TmuxClient(), projects: projects)
        return Fixture(root: root, extensionDirectory: directory, stateURL: stateURL,
                       store: store, sessions: sessions, defaults: defaults, suiteName: suite)
    }
}
