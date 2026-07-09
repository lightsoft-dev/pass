import XCTest
@testable import Pass

final class FuzzyTests: XCTestCase {
    func testMatches() {
        XCTAssertTrue(Fuzzy.matches("", "anything"))
        XCTAssertTrue(Fuzzy.matches("pass", "pass"))
        XCTAssertTrue(Fuzzy.matches("psi", "pass-inbox"))     // subsequence
        XCTAssertTrue(Fuzzy.matches("fs", "feat/stripe"))
        XCTAssertFalse(Fuzzy.matches("xyz", "pass-inbox"))
        XCTAssertTrue(Fuzzy.matches("PASS", "pass-app"))       // case-insensitive
    }

    func testScoreRanking() {
        // contiguous / earlier match should score lower (better)
        let contiguous = Fuzzy.score("pass", "passenger")!
        let scattered = Fuzzy.score("pass", "p-a-s-s-word")!
        XCTAssertLessThan(contiguous, scattered)
    }
}

final class InteractionProfileTests: XCTestCase {
    func testPermissionDialogDetection() {
        let p = InteractionProfile.claude
        let dialog = """
        ⏺ Write(spike_out.txt)
         Do you want to create spike_out.txt?
         ❯ 1. Yes
           2. Yes, allow all edits during this session
           3. No
         Esc to cancel · Tab to amend
        """
        XCTAssertTrue(p.isPermissionDialog(dialog))

        let inputBox = """
        ⏺ pong
        ────────────
        ❯
        ────────────
          master | ~/repo | Context: 4% used
        """
        XCTAssertFalse(p.isPermissionDialog(inputBox))
    }

    func testDecisionKeys() {
        let p = InteractionProfile.claude
        XCTAssertEqual(p.approveOnce, ["1"])
        XCTAssertEqual(p.approveAll, ["2"])
        XCTAssertEqual(p.deny, ["3"])
    }
}
