import XCTest
@testable import Pass

final class ClaudeTranscriptTests: XCTestCase {
    func testEncodedDirReplacesSlashesAndDots() {
        XCTAssertEqual(ClaudeTranscript.encodedDir(for: "/Users/zimin/lightsoft-projects/pass"),
                       "-Users-zimin-lightsoft-projects-pass")
        // '/.claude' → '--claude' (both the slash and the dot become dashes).
        XCTAssertEqual(ClaudeTranscript.encodedDir(for: "/Users/zimin/.claude"),
                       "-Users-zimin--claude")
    }

    func testLastAssistantTextPicksFinalTurn() {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"first reply"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"the final answer"}]}}
        """
        XCTAssertEqual(ClaudeTranscript.lastAssistantText(inJSONL: jsonl), "the final answer")
    }

    func testSkipsToolOnlyAndSidechainTurns() {
        // Last two lines are a sidechain reply and a tool-only turn → fall back to real prose.
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"main answer"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read"}]}}
        {"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent chatter"}]}}
        """
        XCTAssertEqual(ClaudeTranscript.lastAssistantText(inJSONL: jsonl), "main answer")
    }

    func testJoinsMultipleTextBlocks() {
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"line one"},{"type":"text","text":"line two"}]}}
        """
        XCTAssertEqual(ClaudeTranscript.lastAssistantText(inJSONL: jsonl), "line one\nline two")
    }

    func testNilWhenNoAssistantText() {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}
        """
        XCTAssertNil(ClaudeTranscript.lastAssistantText(inJSONL: jsonl))
    }
}
