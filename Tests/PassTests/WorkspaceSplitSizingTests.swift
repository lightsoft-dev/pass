import XCTest
@testable import Pass

final class WorkspaceSplitSizingTests: XCTestCase {
    private let dividerWidth: CGFloat = 7

    func testNarrowPanelClampsStoredFractionToKeepTerminalUsable() {
        let fraction = WorkspaceSplitSizing.clampedFraction(0.8, total: 460, dividerWidth: dividerWidth)

        XCTAssertEqual(fraction, 333 / 460, accuracy: 0.0001)
        XCTAssertEqual(
            WorkspaceSplitSizing.terminalWidth(total: 460, fraction: 0.8, dividerWidth: dividerWidth),
            WorkspaceSplitSizing.minimumPaneWidth,
            accuracy: 0.0001
        )
    }

    func testDragStartsAtDisplayedDividerWithoutJumping() {
        let displayed = WorkspaceSplitSizing.clampedFraction(0.8, total: 460, dividerWidth: dividerWidth)

        XCTAssertEqual(
            WorkspaceSplitSizing.resizedFraction(from: displayed, translation: 0, total: 460, dividerWidth: dividerWidth),
            displayed,
            accuracy: 0.0001
        )
    }

    func testDraggingDividerRightShrinksTheAuxiliaryPane() {
        let fraction = WorkspaceSplitSizing.resizedFraction(
            from: 0.45, translation: 100, total: 680, dividerWidth: dividerWidth
        )

        XCTAssertEqual(fraction, 0.45 - 100 / 680, accuracy: 0.0001)
    }
}
