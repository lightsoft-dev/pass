import XCTest
@testable import Pass

final class AgentConversationParserTests: XCTestCase {
    func testStripsANSIAndOSCControlSequences() {
        let input = "\u{1b}[31mred\u{1b}[0m\u{1b}]0;title\u{07} text\r\n"
        XCTAssertEqual(AgentConversationParser.stripTerminalControl(input), "red text\n")
    }

    func testClaudeStrategyParsesConversationAndToolResult() {
        let pane = """
        ╭────────────────────────────────────────╮
        │ > Check the configuration              │
        ╰────────────────────────────────────────╯
        ⏺ I'll inspect the project first.

        ⏺ Read(config.swift)
          ⎿ Read 42 lines

        ⏺ The port is configured correctly and
          the service is ready.

        branch main | Context: 40% used
        ❯
        """
        let blocks = AgentConversationParser.parse(pane, agent: .claude)
        XCTAssertEqual(blocks.map(\.kind), [.user, .assistant, .tool, .assistant])
        XCTAssertEqual(blocks[0].text, "Check the configuration")
        XCTAssertEqual(blocks[2].title, "Read(config.swift)")
        XCTAssertEqual(blocks[2].text, "Read 42 lines")
        XCTAssertEqual(blocks[3].text, "The port is configured correctly and the service is ready.")
    }

    func testCodexStrategyParsesBulletsAndKeepsToolLines() {
        let pane = """
        › Fix the failing test

        • I’ll inspect the relevant files first.

        • Explored
          └ Read package.json
            Search failing test

        • The test now passes.
        """
        let blocks = AgentConversationParser.parse(pane, agent: .codex)
        XCTAssertEqual(blocks.map(\.kind), [.user, .assistant, .tool, .assistant])
        XCTAssertEqual(blocks[2].title, "Explored")
        XCTAssertEqual(blocks[2].text, "Read package.json\nSearch failing test")
    }

    func testProviderMarkersDoNotLeakAcrossStrategies() {
        let pane = "⏺ Read(config.swift)\n  ⎿ Read 4 lines"
        XCTAssertEqual(AgentConversationParser.parse(pane, agent: .codex), [])
        XCTAssertEqual(AgentConversationParser.parse(pane, agent: .claude).first?.kind, .tool)
    }

    func testPiStrategyUsesRoleLabels() {
        let pane = """
        You: Review the change
        Pi: I will inspect the diff.
        Tool: read
          Sources/App.swift
        Pi: The change looks correct.
        """
        let blocks = AgentConversationParser.parse(pane, agent: .pi)
        XCTAssertEqual(blocks.map(\.kind), [.user, .assistant, .tool, .assistant])
        XCTAssertEqual(blocks[2].title, "read")
        XCTAssertEqual(blocks[2].text, "Sources/App.swift")
    }

    func testPiStrategyUsesOSC133UserMessageZones() {
        let start = "\u{1b}]133;A\u{07}"
        let end = "\u{1b}]133;B\u{07}\u{1b}]133;C\u{07}"
        let pane = "\(start) Review the change \(end)\n\nThe implementation is correct."
        let blocks = AgentConversationParser.parse(pane, agent: .pi)
        XCTAssertEqual(blocks.map(\.kind), [.user, .assistant])
        XCTAssertEqual(blocks[0].text, "Review the change")
        XCTAssertEqual(blocks[1].text, "The implementation is correct.")
    }

    func testShellStrategyPreservesPlainOutputAsOneBlock() {
        let blocks = AgentConversationParser.parse("$ swift test\nAll tests passed\n", agent: .shell)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .output)
        XCTAssertEqual(blocks[0].text, "$ swift test\nAll tests passed")
    }
}
