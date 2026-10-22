import XCTest
@testable import Pass

final class ProjectAgentAttachmentTests: XCTestCase {
    func testAttachmentCopyAndPromptHistoryRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("brief.txt")
        try "hello".write(to: original, atomically: true, encoding: .utf8)

        let copied = try ProjectAgentAttachments.copyFiles(
            [original], for: "/repos/example", baseDirectory: directory)
        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(ProjectAgentAttachments.displayName(for: copied[0]), "brief.txt")
        try FileManager.default.removeItem(at: original)
        XCTAssertEqual(try String(contentsOf: copied[0]), "hello")

        let prompt = ProjectAgentAttachments.prompt("이 문서를 검토해 줘", files: copied)
        let displayed = ProjectAgentAttachments.displayContent(prompt)
        XCTAssertEqual(displayed.text, "이 문서를 검토해 줘")
        XCTAssertEqual(displayed.files, copied)
    }

    func testImagePayloadUsesPiImageContentFormat() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("dot.png")
        let onePixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lXcAAAAASUVORK5CYII="
        try XCTUnwrap(Data(base64Encoded: onePixel)).write(to: image)

        let payload = try XCTUnwrap(ProjectAgentAttachments.imagePayloads(for: [image]).first)
        XCTAssertEqual(payload["type"] as? String, "image")
        XCTAssertEqual(payload["mimeType"] as? String, "image/png")
        XCTAssertNotNil(Data(base64Encoded: try XCTUnwrap(payload["data"] as? String)))
    }
}
