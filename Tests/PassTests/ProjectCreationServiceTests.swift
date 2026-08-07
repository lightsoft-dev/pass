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

    func testParsesCommonGitHubRepositoryURLs() {
        let https = ProjectCreationService.githubRepository(
            from: "https://github.com/lightsoft-dev/pass"
        )
        XCTAssertEqual(https?.owner, "lightsoft-dev")
        XCTAssertEqual(https?.name, "pass")
        XCTAssertEqual(https?.cloneURL, "https://github.com/lightsoft-dev/pass.git")

        let ssh = ProjectCreationService.githubRepository(
            from: "git@github.com:lightsoft-dev/pass.git"
        )
        XCTAssertEqual(ssh?.displayName, "lightsoft-dev/pass")
        XCTAssertEqual(ssh?.cloneURL, "git@github.com:lightsoft-dev/pass.git")

        let sshURL = ProjectCreationService.githubRepository(
            from: "ssh://git@github.com/lightsoft-dev/pass.git"
        )
        XCTAssertEqual(sshURL, ssh)
    }

    func testRejectsNonRepositoryAndNonGitHubURLs() {
        [
            "https://gitlab.com/lightsoft-dev/pass",
            "https://github.com/lightsoft-dev/pass/tree/dev",
            "https://github.com/lightsoft-dev",
            "https://github.com/lightsoft-dev/pass?tab=readme",
            "file:///tmp/repository",
        ].forEach {
            XCTAssertNil(ProjectCreationService.githubRepository(from: $0), "\($0) should be rejected")
        }
    }

    func testClonesIntoRepositoryNamedFolder() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("pass-clone-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        var capturedArguments: [String] = []
        let path = try ProjectCreationService.cloneProject(
            from: "https://github.com/lightsoft-dev/pass",
            in: parent.path,
            runGit: { _, arguments in
                capturedArguments = arguments
                if let destination = arguments.last {
                    try? FileManager.default.createDirectory(
                        atPath: destination,
                        withIntermediateDirectories: false
                    )
                }
                return ProcResult(stdout: "", stderr: "", code: 0)
            }
        )

        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "pass")
        XCTAssertEqual(
            capturedArguments,
            ["clone", "--origin", "origin", "--",
             "https://github.com/lightsoft-dev/pass.git", path]
        )
    }

    func testCloneFailureRemovesOnlyNewDestination() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("pass-clone-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("pass", isDirectory: true)

        XCTAssertThrowsError(try ProjectCreationService.cloneProject(
            from: "https://github.com/lightsoft-dev/pass",
            in: parent.path,
            runGit: { _, _ in
                try? FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
                return ProcResult(stdout: "", stderr: "authentication failed", code: 128)
            }
        )) { error in
            XCTAssertEqual(
                error as? ProjectCreationService.Failure,
                .cloneFailed("authentication failed")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
