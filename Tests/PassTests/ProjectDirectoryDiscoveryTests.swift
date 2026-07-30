import XCTest
@testable import Pass

@MainActor
final class ProjectDirectoryDiscoveryTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testPlainDirectoryResolvesAsProjectWithoutGit() async throws {
        let directory = try makeTemporaryDirectory()

        let roots = await AppModel.resolveProjectRoots(under: directory.path)

        XCTAssertEqual(roots, [directory.standardizedFileURL.path])
    }

    func testMissingDirectoryDoesNotResolveAsProject() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pass-missing-\(UUID().uuidString)", isDirectory: true)

        let roots = await AppModel.resolveProjectRoots(under: missing.path)

        XCTAssertTrue(roots.isEmpty)
    }

    func testAsyncScanCombinesAvailableDirectoriesAndTracksMissingOnes() async throws {
        let first = try makeTemporaryDirectory()
        let second = try makeTemporaryDirectory()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pass-missing-\(UUID().uuidString)", isDirectory: true)

        let scan = await AppModel.scanProjectDirectories(
            [first.path, missing.path, second.path],
            knownProjectRoots: [first.path, missing.path]
        )

        XCTAssertEqual(
            scan.discovered,
            [first.standardizedFileURL.path, second.standardizedFileURL.path]
        )
        XCTAssertEqual(
            scan.availableDirectories,
            [first.path, second.path].sorted()
        )
        XCTAssertEqual(scan.existingKnownProjectRoots, [first.path])
        XCTAssertEqual(scan.unavailableCount, 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pass-project-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
