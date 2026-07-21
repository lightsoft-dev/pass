import AppKit
import XCTest
@testable import Pass

final class TerminalMouseInteractionPolicyTests: XCTestCase {
    @MainActor
    func testTerminalDefaultsToPersistentLocalSelectionMode() {
        let terminal = IMETerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))

        XCTAssertFalse(terminal.allowMouseReporting)
    }

    func testPlainDragUsesPersistentLocalSelection() {
        XCTAssertTrue(TerminalMouseInteractionPolicy.usesLocalSelection(modifierFlags: []))
    }

    func testOptionDragIsForwardedToTmux() {
        XCTAssertFalse(
            TerminalMouseInteractionPolicy.usesLocalSelection(modifierFlags: [.option])
        )
    }

    func testOptionIsUsedOnlyAsPassModeSwitch() {
        let forwarded = TerminalMouseInteractionPolicy.modifierFlagsForwardedToTmux([
            .option, .shift, .control,
        ])

        XCTAssertFalse(forwarded.contains(.option))
        XCTAssertTrue(forwarded.contains(.shift))
        XCTAssertTrue(forwarded.contains(.control))
    }

    func testCommandClickStillUsesLocalMouseHandling() {
        XCTAssertTrue(
            TerminalMouseInteractionPolicy.usesLocalSelection(modifierFlags: [.command])
        )
    }
}
