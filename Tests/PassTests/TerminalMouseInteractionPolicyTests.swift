import AppKit
import XCTest
@testable import Pass

final class TerminalMouseInteractionPolicyTests: XCTestCase {
    @MainActor
    func testTerminalDefaultsToPersistentLocalSelectionMode() {
        let terminal = IMETerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))

        XCTAssertFalse(terminal.allowMouseReporting)
    }

    @MainActor
    func testSelectionSurvivesMouseUpAndStreamedOutput() throws {
        let pasteboard = NSPasteboard.general
        let originalClipboard = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let originalClipboard { pasteboard.setString(originalClipboard, forType: .string) }
        }

        let terminal = IMETerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        terminal.getTerminal().feed(text: "hello persistent selection")

        let y = terminal.bounds.height - 8
        terminal.mouseDown(with: try mouseEvent(type: .leftMouseDown, x: 2, y: y))
        // SwiftTerm establishes the selection anchor on the first drag event, then extends it.
        terminal.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, x: 2, y: y))
        terminal.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, x: 150, y: y))
        terminal.mouseUp(with: try mouseEvent(type: .leftMouseUp, x: 150, y: y))
        terminal.copy(self)

        let selectedBeforeOutput = pasteboard.string(forType: .string)
        XCTAssertTrue(selectedBeforeOutput?.hasPrefix("hello") == true)

        // This calls MacTerminalView.linefeed. With mouse reporting enabled SwiftTerm clears
        // the selection here, which was the user-visible regression.
        terminal.getTerminal().feed(text: "\r\nnext line")
        terminal.copy(self)

        XCTAssertEqual(pasteboard.string(forType: .string), selectedBeforeOutput)
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

    func testMiniTerminalRecognizesPasteByPhysicalKeyWithKoreanInput() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "ㅍ",
            charactersIgnoringModifiers: "ㅍ",
            isARepeat: false,
            keyCode: 9
        ))

        let selector = try XCTUnwrap(MiniTerminalEditingShortcut.selector(for: event))
        XCTAssertEqual(
            NSStringFromSelector(selector),
            NSStringFromSelector(#selector(NSText.paste(_:)))
        )
    }

    private func mouseEvent(type: NSEvent.EventType, x: CGFloat, y: CGFloat) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: x, y: y),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0.5
        ))
    }
}
