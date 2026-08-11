import AppKit
import XCTest
@testable import Pass

final class TerminalMouseInteractionPolicyTests: XCTestCase {
    @MainActor
    func testSelectionMenuOffersCopyAndFind() throws {
        let terminal = IMETerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))

        let menu = try XCTUnwrap(terminal.selectionActionMenu(for: "selected output"))

        XCTAssertEqual(
            menu.items.map(\.title),
            ["Copy", "Run in Terminal", "Find in Terminal"]
        )
        XCTAssertTrue(menu.items.allSatisfy(\.isEnabled))
        XCTAssertNil(terminal.selectionActionMenu(for: "  \n  "))
    }

    @MainActor
    func testRunInTerminalMenuExecutesTrimmedSelection() throws {
        let terminal = IMETerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        var executedCommand: String?
        terminal.runSelectionInTerminal = { executedCommand = $0 }
        let menu = try XCTUnwrap(terminal.selectionActionMenu(for: "  echo pass  \n"))

        let runItem = try XCTUnwrap(menu.item(withTitle: "Run in Terminal"))
        let action = try XCTUnwrap(runItem.action)
        XCTAssertTrue(NSApp.sendAction(action, to: runItem.target, from: runItem))

        XCTAssertEqual(executedCommand, "echo pass")
    }

    @MainActor
    func testSelectionMenuOffersOpenForExplicitWebURLOnly() throws {
        let terminal = IMETerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))

        let urlMenu = try XCTUnwrap(
            terminal.selectionActionMenu(for: " https://example.com/docs?q=pass ")
        )
        let proseMenu = try XCTUnwrap(
            terminal.selectionActionMenu(for: "open https://example.com")
        )

        XCTAssertEqual(
            urlMenu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Copy", "Run in Terminal", "Find in Terminal", "Open Link"]
        )
        XCTAssertEqual(
            proseMenu.items.map(\.title),
            ["Copy", "Run in Terminal", "Find in Terminal"]
        )
    }

    @MainActor
    func testTerminalDefaultsToPersistentLocalSelectionMode() {
        let terminal = IMETerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))

        XCTAssertFalse(terminal.allowMouseReporting)
        XCTAssertTrue(terminal.notifyUpdateChanges)
    }

    @MainActor
    func testIMECompositionFollowsCursorWhenCommittedTextEchoes() throws {
        let terminal = IMETerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = NSWindow(
            contentRect: terminal.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = terminal

        terminal.setMarkedText(
            "개",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let overlay = try XCTUnwrap(
            terminal.subviews.compactMap { $0 as? NSTextField }.first(where: { !$0.isHidden })
        )
        let xBeforeEcho = overlay.frame.minX

        // The previous Korean syllable was committed, then returned through tmux after the
        // next syllable had already entered its marked-text phase.
        terminal.feed(text: "지")
        let cursorUpdate = expectation(description: "SwiftTerm display update")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            cursorUpdate.fulfill()
        }
        wait(for: [cursorUpdate], timeout: 1)

        XCTAssertGreaterThan(
            overlay.frame.minX,
            xBeforeEcho,
            "The marked text should be re-anchored after tmux advances the terminal cursor"
        )
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

    @MainActor
    func testSelectionActionReadsTextWithoutReplacingClipboard() throws {
        let pasteboard = NSPasteboard.general
        let originalClipboard = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let originalClipboard { pasteboard.setString(originalClipboard, forType: .string) }
        }
        pasteboard.clearContents()
        pasteboard.setString("keep clipboard", forType: .string)

        let terminal = IMETerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        terminal.getTerminal().feed(text: "send this selection")
        let y = terminal.bounds.height - 8
        terminal.mouseDown(with: try mouseEvent(type: .leftMouseDown, x: 2, y: y))
        terminal.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, x: 2, y: y))
        terminal.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, x: 130, y: y))
        terminal.mouseUp(with: try mouseEvent(type: .leftMouseUp, x: 130, y: y))

        XCTAssertTrue(terminal.selectedTextForMenu().hasPrefix("send this"))
        XCTAssertEqual(pasteboard.string(forType: .string), "keep clipboard")
    }

    @MainActor
    func testPlainTextURLHitUsesExactCellsWithKoreanAroundIt() throws {
        let terminal = IMETerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 240))
        let url = "https://print-so.lightsoft.dev/admin/printer"
        terminal.feed(text: "한글 \(url)에서")

        let cellWidth = terminal.caretFrame.width
        let cellHeight = terminal.caretFrame.height
        XCTAssertGreaterThan(cellWidth, 0)
        XCTAssertGreaterThan(cellHeight, 0)

        // 한/글 each occupy two terminal cells, followed by one space.
        let urlStartColumn = 5
        func point(column: Int) -> NSPoint {
            NSPoint(
                x: (CGFloat(column) + 0.5) * cellWidth,
                y: terminal.bounds.height - cellHeight / 2
            )
        }

        let hit = try XCTUnwrap(terminal.urlHit(at: point(column: urlStartColumn + 8)))
        XCTAssertEqual(hit.url.absoluteString, url)
        let underline = try XCTUnwrap(hit.rects.first)
        let linkStart = CGFloat(urlStartColumn) * cellWidth
        let linkEnd = linkStart + CGFloat(url.count) * cellWidth
        XCTAssertGreaterThan(underline.minX, linkStart)
        XCTAssertLessThan(underline.maxX, linkEnd)

        XCTAssertNil(terminal.urlHit(at: point(column: 0)))
        XCTAssertNil(terminal.urlHit(at: point(column: urlStartColumn + url.count)))
    }

    @MainActor
    func testPlainTextURLHitFollowsSwiftTermSoftWrap() throws {
        let terminal = IMETerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        let url = "https://example.com/abcdefghijklmnopqrstuvwxyz0123456789"
        XCTAssertGreaterThan(url.count, terminal.getTerminal().cols)
        terminal.feed(text: url)

        let cellWidth = terminal.caretFrame.width
        let cellHeight = terminal.caretFrame.height
        let continuationColumn = 4
        let point = NSPoint(
            x: (CGFloat(continuationColumn) + 0.5) * cellWidth,
            y: terminal.bounds.height - 1.5 * cellHeight
        )

        let hit = try XCTUnwrap(terminal.urlHit(at: point))
        XCTAssertEqual(hit.url.absoluteString, url)
        XCTAssertGreaterThanOrEqual(hit.rects.count, 2)
        XCTAssertEqual(hit.rects[0].minX, 0, accuracy: 0.001)
        XCTAssertEqual(hit.rects[1].minX, 0, accuracy: 0.001)
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

    func testChoiceClickMovesFromHighlightAndConfirms() throws {
        let options = DecisionParser.parse("""
        ❯ 1. First
          2. Second
          3. Third
        """)

        let input = try XCTUnwrap(TerminalChoiceInteraction.input(for: options[2], among: options))

        XCTAssertEqual(input, "\u{1b}[B\u{1b}[B\r")
    }

    func testChoiceClickRequiresExactlyOneHighlight() {
        let options = DecisionParser.parse("""
          1. First
          2. Second
        """)

        XCTAssertNil(TerminalChoiceInteraction.input(for: options[1], among: options))
    }

    @MainActor
    func testDecisionOptionHitMapsTerminalCoordinatesToRows() throws {
        let terminal = IMETerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        terminal.getTerminal().feed(text: "Question?\r\n❯ 1. First\r\n  2. Second")
        let rows = max(terminal.getTerminal().rows, 1)
        let cellHeight = terminal.bounds.height / CGFloat(rows)
        let secondOptionRow = 2
        let point = NSPoint(
            x: 40,
            y: terminal.bounds.height - (CGFloat(secondOptionRow) + 0.5) * cellHeight
        )

        XCTAssertEqual(terminal.decisionOption(at: point)?.number, 2)
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
