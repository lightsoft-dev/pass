import XCTest
@testable import Pass

final class DecisionParserTests: XCTestCase {
    func testPermissionDialog() {
        // The real Claude Code permission prompt (spikes/FINDINGS.md).
        let pane = """
        ⏺ Write(spike_out.txt)
         Do you want to create spike_out.txt?
         ❯ 1. Yes
           2. Yes, allow all edits during this session (shift+tab)
           3. No
         Esc to cancel · Tab to amend
        """
        let opts = DecisionParser.parse(pane)
        XCTAssertEqual(opts.map(\.number), [1, 2, 3])
        XCTAssertEqual(opts[0].label, "Yes")
        XCTAssertTrue(opts[0].highlighted)      // ❯ marks option 1
        XCTAssertFalse(opts[2].highlighted)
        XCTAssertTrue(opts[1].label.contains("allow all"))
    }

    func testAskUserQuestionStyle() {
        let pane = """
        Which library should we use?
          1. date-fns
          2. Day.js
        ❯ 3. Luxon
          4. Moment
        """
        let opts = DecisionParser.parse(pane)
        XCTAssertEqual(opts.count, 4)
        XCTAssertEqual(opts[3].label, "Moment")
        XCTAssertTrue(opts[2].highlighted)
    }

    func testIgnoresProseWithSingleNumber() {
        // A lone "1. foo" in a normal message must NOT be treated as a menu.
        XCTAssertTrue(DecisionParser.parse("Here is step 1. Do the thing.").isEmpty)
        XCTAssertTrue(DecisionParser.parse("⏺ pong\n❯ ").isEmpty)
    }

    func testRequiresConsecutiveFromOne() {
        // 2,3,4 without a 1 is not a valid pick menu.
        let pane = "  2. b\n  3. c\n  4. d"
        XCTAssertTrue(DecisionParser.parse(pane).isEmpty)
    }
}
