import XCTest
@testable import Pass

final class ProjectCreationServiceTests: XCTestCase {
    func testCreatesProjectInsideConfiguredParent() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("pass-new-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let path = try ProjectCreationService.createProject(
            named: "hello-pass",
            in: parent.path,
            initializeGit: false
        )

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "hello-pass")
    }

    func testRejectsTraversalHiddenAndEmptyNames() {
        ["", "  ", ".", "..", "../escape", "nested/project", ".hidden", "bad:name"].forEach {
            XCTAssertFalse(ProjectCreationService.isValidName($0), "\($0) should be rejected")
        }
    }

    func testRefusesExistingDestination() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("pass-new-project-\(UUID().uuidString)", isDirectory: true)
        let existing = parent.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        XCTAssertThrowsError(try ProjectCreationService.createProject(
            named: "existing",
            in: parent.path,
            initializeGit: false
        )) { error in
            XCTAssertEqual(error as? ProjectCreationService.Failure, .alreadyExists)
        }
    }
}
