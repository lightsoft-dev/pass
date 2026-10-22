import XCTest
@testable import Pass

final class ProjectAgentIdentityTests: XCTestCase {
    func testOneStableManagerPerProject() {
        let first = "/repos/first"
        let second = "/repos/second"
        let name = ProjectAgentIdentity.sessionName(for: first)

        XCTAssertEqual(name, ProjectAgentIdentity.sessionName(for: first))
        XCTAssertNotEqual(name, ProjectAgentIdentity.sessionName(for: second))
        XCTAssertTrue(ProjectAgentIdentity.isManager(name: name, projectRoot: first))
        XCTAssertFalse(ProjectAgentIdentity.isManager(name: name, projectRoot: second))
        XCTAssertFalse(ProjectAgentIdentity.isManager(name: "pass-first", projectRoot: first))
        XCTAssertNotEqual(ProjectAgentIdentity.piSessionID(for: first),
                          ProjectAgentIdentity.piSessionID(for: second))
        XCTAssertNotEqual(ProjectAgentIdentity.rpcSessionID(for: first),
                          ProjectAgentIdentity.rpcSessionID(for: second))
        XCTAssertNotEqual(ProjectAgentIdentity.rpcSessionID(for: first),
                          ProjectAgentIdentity.piSessionID(for: first))
    }

    func testWorkerMemoryIsSeparateAndPreservedForEachProject() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let template = directory.appendingPathComponent("template.md")
        try "Project: {{PROJECT_ROOT}}\nFile: {{MEMORY_PATH}}\n".write(
            to: template, atomically: true, encoding: .utf8)

        let first = try ProjectAgentWorkerMemory.ensureFile(
            for: "/repos/first", baseDirectory: directory, templateURL: template)
        XCTAssertTrue(try String(contentsOf: first).contains("/repos/first"))
        try "Remember Codex".write(to: first, atomically: true, encoding: .utf8)
        let same = try ProjectAgentWorkerMemory.ensureFile(
            for: "/repos/first", baseDirectory: directory, templateURL: template)
        XCTAssertEqual(try String(contentsOf: same), "Remember Codex")

        let second = try ProjectAgentWorkerMemory.ensureFile(
            for: "/repos/second", baseDirectory: directory, templateURL: template)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(try String(contentsOf: second).contains("/repos/second"))
    }

    func testPiLoginIsRequiredWhenSelectedOAuthCredentialExpires() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"defaultProvider":"openai-codex"}"#.utf8)
            .write(to: directory.appendingPathComponent("settings.json"))
        let auth = directory.appendingPathComponent("auth.json")

        XCTAssertTrue(PiAuthentication.needsLogin(
            now: Date(timeIntervalSince1970: 100), agentDirectory: directory))
        try Data(#"{"openai-codex":{"type":"oauth","access":"token","expires":90000}}"#.utf8)
            .write(to: auth)
        XCTAssertTrue(PiAuthentication.needsLogin(
            now: Date(timeIntervalSince1970: 100), agentDirectory: directory))

        try Data(#"{"openai-codex":{"type":"oauth","access":"token","expires":300000}}"#.utf8)
            .write(to: auth)
        XCTAssertFalse(PiAuthentication.needsLogin(
            now: Date(timeIntervalSince1970: 100), agentDirectory: directory))
    }

    func testAnotherConnectedProviderCanServePaWhenDefaultExpires() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"defaultProvider":"openai-codex","defaultModel":"gpt-5.5"}"#.utf8)
            .write(to: directory.appendingPathComponent("settings.json"))
        try Data(#"{"openai-codex":{"type":"oauth","access":"old","expires":90000},"zai":{"type":"api_key","key":"test-key"}}"#.utf8)
            .write(to: directory.appendingPathComponent("auth.json"))

        XCTAssertFalse(PiAuthentication.needsLogin(
            now: Date(timeIntervalSince1970: 100), agentDirectory: directory))
        XCTAssertEqual(PiAuthentication.usableProviders(
            now: Date(timeIntervalSince1970: 100), agentDirectory: directory), ["zai"])
    }

    func testAutomaticModelChoiceSkipsUnsupportedProviderAndPrefersKnownWorkingModel() {
        let models = [
            PiModelOption(provider: "openai-codex", id: "gpt-5.5"),
            PiModelOption(provider: "zai", id: "glm-4.5-air"),
            PiModelOption(provider: "zai", id: "glm-4.7")
        ]
        let candidates = PiModelSelection.candidates(
            models, usableProviders: ["openai-codex", "zai"],
            preferredLabels: ["zai/glm-4.7"], attemptedLabels: ["openai-codex/gpt-5.5"],
            blockedProviders: ["openai-codex"])

        XCTAssertEqual(candidates.map(\.label), ["zai/glm-4.7", "zai/glm-4.5-air"])
    }

    func testToolActivityKeepsOneRowAndFullResult() {
        var messages: [ProjectAgentMessage] = []
        ProjectAgentToolActivity.start([
            "toolCallId": "call-1", "toolName": "bash", "args": ["command": "git status"]
        ], in: &messages)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].toolIsRunning)
        XCTAssertEqual(messages[0].toolSummary, "git status")

        let result = String(repeating: "output ", count: 120)
        ProjectAgentToolActivity.finish([
            "toolCallId": "call-1", "toolName": "bash",
            "result": ["content": [["type": "text", "text": result]]], "isError": false
        ], in: &messages, isComplete: true)
        XCTAssertEqual(messages.count, 1)
        XCTAssertFalse(messages[0].toolIsRunning)
        XCTAssertEqual(messages[0].text, result)
    }

    @MainActor func testToolActivityRestoresFromPiHistory() {
        let history: [[String: Any]] = [
            ["role": "assistant", "content": [
                ["type": "text", "text": "파일을 확인할게요."],
                ["type": "toolCall", "id": "call-2", "name": "read",
                 "arguments": ["path": "README.md"]]
            ]],
            ["role": "toolResult", "toolCallId": "call-2", "toolName": "read",
             "content": [["type": "text", "text": "README contents"]], "isError": false]
        ]
        let messages = ProjectAgentConversation.messagesFromHistory(history)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].text, "파일을 확인할게요.")
        XCTAssertEqual(messages[1].toolName, "read")
        XCTAssertEqual(messages[1].text, "README contents")
        XCTAssertFalse(messages[1].toolIsRunning)
    }

    @MainActor func testAssistantImageRestoresWithoutText() {
        let imageData = Data([0x89, 0x50, 0x4e, 0x47])
        let history: [[String: Any]] = [[
            "role": "assistant",
            "content": [["type": "image", "mimeType": "image/png",
                         "data": imageData.base64EncodedString()]]
        ]]

        let messages = ProjectAgentConversation.messagesFromHistory(history)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .assistant)
        XCTAssertEqual(messages[0].images, [imageData])
    }
}
