import XCTest
@testable import Pass

final class PaneSummaryTests: XCTestCase {
    func testLastAgentMessagePicksProseNotToolCall() {
        // A realistic Claude Code pane: prose, then a tool call + result, then final prose.
        let pane = """
        ⏺ I'll check the file first.

        ⏺ Read(config.swift)
          ⎿ Read 42 lines

        ⏺ The config looks correct — the port is set to 49817 and
          the host is bound to localhost.

        ─────────────────────────────
        ❯
        branch main | ~/proj | Context: 40% used
        """
        XCTAssertEqual(
            PaneSummary.lastAgentMessage(pane),
            "The config looks correct — the port is set to 49817 and the host is bound to localhost."
        )
    }

    func testLastAgentMessageSkipsTrailingToolCalls() {
        // The last ⏺ block is a tool call → fall back to the prior prose block.
        let pane = """
        ⏺ Running the build now.

        ⏺ Bash(make build)
          ⎿ ** BUILD SUCCEEDED **
        """
        XCTAssertEqual(PaneSummary.lastAgentMessage(pane), "Running the build now.")
    }

    func testLastAgentMessageNilWhenNoProse() {
        let pane = """
        ⏺ Read(a.txt)
          ⎿ Read 1 line
        ❯
        """
        XCTAssertNil(PaneSummary.lastAgentMessage(pane))
    }

    func testLastContentLinesFallbackStillWorks() {
        let pane = """
        some plain shell output
        final line here
        ─────────
        ❯
        """
        XCTAssertEqual(PaneSummary.lastContentLines(pane, max: 2), "some plain shell output\nfinal line here")
    }

    func testInputBoxBordersAreChromeNotContent() {
        // A freshly-booted Claude pane: only the input box + mode line are visible. The
        // rounded corners (╭ ╮ ╰ ╯) must not leak into the preview as "content".
        let pane = """
        ╭──────────────────────────────────────╮
        │ >                                    │
        ╰──────────────────────────────────────╯
          ⏵⏵ bypass permissions on (shift+tab to cycle)
        """
        XCTAssertNil(PaneSummary.lastContentLines(pane, max: 2))
        XCTAssertNil(PaneSummary.lastAgentMessage(pane))
    }

    func testMixedBorderAndProsePicksProse() {
        let pane = """
        ⏺ Done — the tests pass.
        ╭────────────╮
        │ >          │
        ╰────────────╯
        """
        XCTAssertEqual(PaneSummary.lastContentLines(pane, max: 1), "Done — the tests pass.")
    }
}
