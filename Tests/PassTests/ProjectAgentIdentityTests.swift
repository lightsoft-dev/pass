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
}
