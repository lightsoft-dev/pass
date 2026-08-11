import SwiftUI
import SwiftTerm
import AppKit

/// Embedded tmux sessions request mouse events for scrollback. Normal terminal behavior is more
/// useful for dragging, though: keep a native SwiftTerm selection by default and reserve Option
/// for forwarding a drag to tmux copy-mode.
enum TerminalMouseInteractionPolicy {
    static func usesLocalSelection(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        !modifierFlags.contains(.option)
    }

    /// Option chooses tmux mode in Pass; it is not part of the mouse gesture tmux should match.
    static func modifierFlagsForwardedToTmux(
        _ modifierFlags: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        modifierFlags.subtracting(.option)
    }
}

/// Convert a semantic click on a numbered TUI option into the same input a keyboard user would
/// produce. Arrow-and-Enter works across Claude/Codex/Pi-style menus without assuming that a
/// provider binds number keys, and requires exactly one visibly highlighted choice.
enum TerminalChoiceInteraction {
    static func input(for target: DecisionOption, among options: [DecisionOption]) -> String? {
        let highlighted = options.indices.filter { options[$0].highlighted }
        guard highlighted.count == 1,
              let targetIndex = options.firstIndex(where: { $0.number == target.number })
        else { return nil }

        let distance = targetIndex - highlighted[0]
        if distance < 0 {
            return String(repeating: "\u{1b}[A", count: -distance) + "\r"
        }
        return String(repeating: "\u{1b}[B", count: distance) + "\r"
    }
}

/// SwiftTerm's macOS view ignores IME composition (`setMarkedText` is an empty stub), so while
/// typing Korean/Japanese/Chinese NOTHING shows until the character is committed — it feels
/// like keystrokes are swallowed. This subclass renders the in-progress composition at the
/// caret (underlined, like every regular terminal) and clears it when the IME commits the
/// text to the session.
final class IMETerminalView: LocalProcessTerminalView {
    private var markedText = ""
    /// Supplied by the owning workspace so selected output can be executed in that project's
    /// independent shell instead of being sent back into the agent's tmux session.
    var runSelectionInTerminal: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // SwiftTerm clears local selections on streamed output while this is true. Keep local
        // selection as the steady state; the event bridge enables reporting only for Option-drag.
        allowMouseReporting = false
        // A committed IME syllable reaches tmux asynchronously. Keep receiving display-change
        // callbacks so the next in-progress syllable follows the echoed cursor instead of
        // remaining over the previously committed character.
        notifyUpdateChanges = true
        // Drop files (or text) onto the terminal → their escaped paths land in the agent's
        // input, Terminal.app-style.
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        allowMouseReporting = false
        notifyUpdateChanges = true
        registerForDraggedTypes([.fileURL, .string])
    }

    // MARK: File drop → typed path

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let paths = urls.map { Self.escapedPath($0.path) }.joined(separator: " ")
            send(source: self, data: ArraySlice(Array((paths + " ").utf8)))
            return true
        }
        if let str = pb.string(forType: .string), !str.isEmpty {
            send(source: self, data: ArraySlice(Array(str.utf8)))
            return true
        }
        return false
    }

    /// Backslash-escape shell specials so a dropped path lands as one token (Terminal.app-style).
    private static func escapedPath(_ p: String) -> String {
        let specials = Set(" '\"`\\$&()[]{};<>?*|~!#")
        return String(p.flatMap { specials.contains($0) ? ["\\", $0] : [$0] })
    }
    private lazy var markedLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.isBezeled = false
        l.isEditable = false
        l.drawsBackground = true
        l.isHidden = true
        addSubview(l)
        return l
    }()

    /// SwiftTerm's wheel handler ONLY scrolls the local buffer — which is empty under tmux
    /// (it redraws in place; history lives on the tmux side), so scrolling did nothing. Its
    /// `scrollWheel` is public-not-open (can't override), so a local event monitor intercepts
    /// wheel events over these views and — when the terminal requested mouse tracking (our
    /// sessions run `mouse on`) — forwards them to tmux as SGR mouse events, which scroll
    /// tmux's copy-mode history like any modern terminal. A second monitor keeps normal drags
    /// as persistent, ⌘C-copyable SwiftTerm selections and temporarily enables reporting for
    /// Option-drag. It also opens plain-text http(s) URLs on ⌘-click (SwiftTerm only handles
    /// OSC 8 hyperlinks, which agents don't emit).
    static func installEventBridges() { _ = wheelForwarder; _ = mouseBridge }

    private static weak var hoverTerm: IMETerminalView?
    private static var mouseDownPoint: NSPoint?
    private static weak var mouseDownTerm: IMETerminalView?
    private static var mouseReportingBeforeDrag: Bool?
    private static var mouseGestureUsesTmux = false

    /// Hover a plain-text URL → underline + pointing hand. Click it in place (or ⌘-click
    /// anywhere on it) → open in the browser. Runs as a monitor because SwiftTerm's own mouse
    /// overrides are public-not-open.
    private static let mouseBridge: Any? =
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .mouseMoved,
                                                    .leftMouseDragged]) { event in
            let term = terminalView(under: event)
            switch event.type {
            case .mouseMoved:
                if hoverTerm !== term { hoverTerm?.clearInteractiveHover() }
                hoverTerm = term
                term?.updateInteractiveHover(event)
            case .leftMouseDragged:
                let dragTerm = mouseDownTerm ?? term
                if mouseGestureUsesTmux {
                    // Option is Pass's mode switch, not a modifier tmux should see. Forward an
                    // unmodified drag so tmux's ordinary MouseDrag1Pane binding still matches.
                    dragTerm?.forwardDrag(event)
                } else if mouseReportingBeforeDrag != nil {
                    // Keep reporting off for the whole gesture. SwiftTerm now extends its own
                    // selection, which remains visible after mouse-up and is handled by ⌘C.
                    dragTerm?.allowMouseReporting = false
                }
                dragTerm?.clearInteractiveHover()
                if mouseGestureUsesTmux { return eventForTmux(event) }
            case .leftMouseDown:
                // Recover if a previous gesture was interrupted before its mouse-up arrived.
                if let oldTerm = mouseDownTerm, let oldValue = mouseReportingBeforeDrag {
                    oldTerm.allowMouseReporting = oldValue
                }
                mouseDownPoint = event.locationInWindow
                mouseDownTerm = term
                mouseReportingBeforeDrag = nil
                mouseGestureUsesTmux = false
                if let term {
                    if TerminalMouseInteractionPolicy.usesLocalSelection(
                        modifierFlags: event.modifierFlags
                    ) {
                        mouseReportingBeforeDrag = term.allowMouseReporting
                        term.allowMouseReporting = false
                    } else {
                        mouseReportingBeforeDrag = term.allowMouseReporting
                        term.allowMouseReporting = true
                        mouseGestureUsesTmux = true
                        return eventForTmux(event)
                    }
                }
            case .leftMouseUp:
                let dragTerm = mouseDownTerm ?? term
                let reportingToRestore = mouseReportingBeforeDrag
                let downPoint = mouseDownPoint
                let gestureUsedTmux = mouseGestureUsesTmux
                mouseDownPoint = nil
                mouseDownTerm = nil
                mouseReportingBeforeDrag = nil
                mouseGestureUsesTmux = false

                // The local monitor runs before SwiftTerm receives mouseUp. Restore reporting on
                // the next main-queue turn so mouseUp also follows the local-selection path.
                if let dragTerm, let reportingToRestore {
                    DispatchQueue.main.async { [weak dragTerm] in
                        dragTerm?.allowMouseReporting = reportingToRestore
                    }
                }

                guard let term else { return event }
                let moved = downPoint.map {
                    hypot(event.locationInWindow.x - $0.x, event.locationInWindow.y - $0.y) > 4
                } ?? true
                let cmd = event.modifierFlags.contains(.command)
                let plainClick = event.modifierFlags
                    .intersection([.command, .option, .control, .shift]).isEmpty
                // Numbered agent menus are generally keyboard-only. Turn a click on an exact
                // option row into relative arrows + Enter, after re-reading the live screen.
                if !moved, plainClick,
                   term.activateDecisionOption(
                       at: term.convert(event.locationInWindow, from: nil)
                   ) {
                    debugLog("click choice")
                    return event
                }
                // A stationary click (not the end of a drag-selection) or a ⌘-click on a URL
                // opens it.
                if cmd || !moved,
                   let url = term.urlHit(at: term.convert(event.locationInWindow, from: nil))?.url {
                    debugLog("click open \(url.absoluteString)")
                    NSWorkspace.shared.open(url)
                    // Plain click still flows to tmux (keeps its button state sane); ⌘-click
                    // is consumed so SwiftTerm's OSC-8 handler doesn't double-fire.
                    if cmd { return nil }
                    return gestureUsedTmux ? eventForTmux(event) : event
                }
                // A normal drag leaves a persistent SwiftTerm selection. Surface a small
                // action menu only after SwiftTerm has received mouse-up and finalized it.
                // Option-drag belongs to tmux copy-mode and must remain untouched.
                if moved, !gestureUsedTmux, let dragTerm {
                    let menuPoint = dragTerm.convert(event.locationInWindow, from: nil)
                    DispatchQueue.main.async { [weak dragTerm] in
                        dragTerm?.showSelectionActions(at: menuPoint)
                    }
                }
                return gestureUsedTmux ? eventForTmux(event) : event
            default: break
            }
            return event
        }

    /// Rebuild a left-mouse event without Option. Pass uses Option to select tmux interaction,
    /// while tmux's default bindings intentionally listen for the ordinary mouse event.
    private static func eventForTmux(_ event: NSEvent) -> NSEvent {
        NSEvent.mouseEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: TerminalMouseInteractionPolicy.modifierFlagsForwardedToTmux(
                event.modifierFlags
            ),
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: event.clickCount,
            pressure: event.pressure
        ) ?? event
    }

    private static func terminalView(under event: NSEvent) -> IMETerminalView? {
        guard let window = event.window,
              let hit = window.contentView?.hitTest(event.locationInWindow) else { return nil }
        var v: NSView? = hit
        while let cur = v {
            if let t = cur as? IMETerminalView { return t }
            v = cur.superview
        }
        return nil
    }

    /// Breadcrumbs for mouse-path debugging (cheap, append-only): `tail -f /tmp/pass-mouse.log`.
    private static func debugLog(_ line: String) {
        let msg = "\(Date()) \(line)\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/pass-mouse.log") {
            h.seekToEndOfFile(); h.write(Data(msg.utf8)); try? h.close()
        } else {
            FileManager.default.createFile(atPath: "/tmp/pass-mouse.log", contents: Data(msg.utf8))
        }
    }

    /// The http(s) URL under a point, with the exact terminal-cell rects it occupies.
    /// SwiftTerm exposes its real cell size through `caretFrame`; deriving it from the full
    /// bounds also includes the scrollbar and leftover pixels, causing cumulative x/y drift.
    func urlHit(at point: NSPoint) -> (url: URL, rects: [NSRect])? {
        let terminal = getTerminal()
        let cols = max(terminal.cols, 1), rows = max(terminal.rows, 1)
        let renderedCell = caretFrame.size
        let cellW = renderedCell.width > 0
            ? renderedCell.width
            : max(bounds.width / CGFloat(cols), 1)
        let cellH = renderedCell.height > 0
            ? renderedCell.height
            : max(bounds.height / CGFloat(rows), 1)
        let fromTop = isFlipped ? point.y : bounds.height - point.y
        let contentWidth = CGFloat(cols) * cellW
        let contentHeight = CGFloat(rows) * cellH
        guard point.x >= 0, point.x < contentWidth,
              fromTop >= 0, fromTop < contentHeight
        else { return nil }

        let col = Int(point.x / cellW)
        let row = Int(fromTop / cellH)
        let terminalRows = linkRows(containing: row, terminal: terminal)
        guard let match = TerminalLinkResolver.match(
            rows: terminalRows,
            at: .init(row: row, column: col)
        ) else { return nil }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let thickness = max(round(scale * font.underlineThickness) / scale, 0.5)
        let baselineOffset = ceil(abs(font.descender) + font.leading)
        let underlineOffset = max(0, baselineOffset + font.underlinePosition)
        let rects = match.ranges.map { range in
            let y: CGFloat
            if isFlipped {
                let cellBottom = CGFloat(range.row + 1) * cellH
                y = cellBottom - underlineOffset - thickness
            } else {
                let cellBottom = bounds.height - CGFloat(range.row + 1) * cellH
                y = cellBottom + underlineOffset
            }
            let cellRect = NSRect(
                x: CGFloat(range.startColumn) * cellW,
                y: max(0, y),
                width: CGFloat(range.endColumn - range.startColumn) * cellW,
                height: thickness
            )
            return visuallyInsetUnderline(in: cellRect, scale: scale)
        }
        return (match.url, rects)
    }

    /// A terminal cell includes the glyph's side bearings. Drawing the hover underline across
    /// the full cell makes it visibly extend past the last character (especially for `r`,
    /// punctuation, and a URL followed by Korean text). Keep the cell-derived range for hit
    /// testing, but trim one device pixel from either end for the visual affordance.
    private func visuallyInsetUnderline(in rect: NSRect, scale: CGFloat) -> NSRect {
        let inset = 1 / max(scale, 1)
        guard rect.width > inset * 2 else { return rect }
        return rect.insetBy(dx: inset, dy: 0)
    }

    /// Returns the complete visible soft-wrapped line containing `row`. SwiftTerm keeps
    /// `BufferLine.isWrapped` internal, but its public text API preserves hard newlines, so a
    /// boundary without `\n` is an exact soft-wrap boundary rather than a three-row guess.
    private func linkRows(containing row: Int, terminal: Terminal) -> [TerminalLinkResolver.Row] {
        var first = row
        while first > 0, rowJoinsPrevious(first, terminal: terminal) { first -= 1 }

        var last = row
        while last + 1 < terminal.rows,
              rowJoinsPrevious(last + 1, terminal: terminal) {
            last += 1
        }

        return (first...last).compactMap { screenRow in
            guard let line = terminal.getLine(row: screenRow) else { return nil }
            let data = line.getData()
            let cells: [Character?] = (0..<terminal.cols).map { column in
                guard data.indices.contains(column) else { return nil }
                let character = terminal.getCharacter(for: data[column])
                return character.unicodeScalars.first?.value == 0 ? nil : character
            }
            return TerminalLinkResolver.Row(
                index: screenRow,
                cells: cells,
                joinsPrevious: screenRow > first
                    && rowJoinsPrevious(screenRow, terminal: terminal)
            )
        }
    }

    private func rowJoinsPrevious(_ screenRow: Int, terminal: Terminal) -> Bool {
        guard screenRow > 0 else { return false }
        let absoluteRow = terminal.buffer.yDisp + screenRow
        let boundary = terminal.getText(
            start: Position(col: 0, row: absoluteRow - 1),
            end: Position(col: min(1, terminal.cols), row: absoluteRow)
        )
        return !boundary.contains("\n")
    }

    // MARK: Link hover underline

    private var linkUnderlines: [NSView] = []
    private var hoverKey: String?
    private var hoverArea: NSTrackingArea?

    /// SwiftTerm only tracks mouse movement while ⌘ is held; hover affordance needs it always.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    /// Underline the URL under the pointer (and show a pointing hand) — cleared when the
    /// pointer leaves it.
    fileprivate func updateLinkHover(_ event: NSEvent) {
        guard let hit = urlHit(at: convert(event.locationInWindow, from: nil)) else {
            clearLinkHover()
            return
        }
        let key = hit.url.absoluteString + hit.rects.map(NSStringFromRect).joined()
        guard key != hoverKey else { return }
        clearLinkHover()
        hoverKey = key
        for r in hit.rects {
            let underline = NSView(frame: r)
            underline.wantsLayer = true
            underline.layer?.backgroundColor = NSColor.linkColor.cgColor
            addSubview(underline)
            linkUnderlines.append(underline)
        }
        NSCursor.pointingHand.set()
    }

    fileprivate func clearLinkHover() {
        guard hoverKey != nil || !linkUnderlines.isEmpty else { return }
        hoverKey = nil
        linkUnderlines.forEach { $0.removeFromSuperview() }
        linkUnderlines.removeAll()
        NSCursor.iBeam.set()
    }

    // MARK: Numbered choice hover + click

    private var choiceHighlight: NSView?
    private var choiceHoverRow: Int?

    /// Prefer a numbered menu row over a URL for a plain hover. Command-click still reaches
    /// the URL path on mouse-up, while ordinary clicks choose the option containing that URL.
    fileprivate func updateInteractiveHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = decisionOptionHit(at: point) {
            clearLinkHover()
            updateChoiceHover(row: hit.option.row, rect: hit.rect)
            NSCursor.pointingHand.set()
        } else {
            clearChoiceHover()
            updateLinkHover(event)
        }
    }

    fileprivate func clearInteractiveHover() {
        clearChoiceHover()
        clearLinkHover()
    }

    private func updateChoiceHover(row: Int, rect: NSRect) {
        guard choiceHoverRow != row else { return }
        clearChoiceHover()
        let highlight = NSView(frame: rect.insetBy(dx: 2, dy: 1))
        highlight.wantsLayer = true
        highlight.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.13).cgColor
        highlight.layer?.cornerRadius = 3
        addSubview(highlight)
        choiceHighlight = highlight
        choiceHoverRow = row
    }

    private func clearChoiceHover() {
        guard choiceHoverRow != nil || choiceHighlight != nil else { return }
        choiceHighlight?.removeFromSuperview()
        choiceHighlight = nil
        choiceHoverRow = nil
        NSCursor.iBeam.set()
    }

    /// The exact visible menu option under a terminal coordinate. Requiring one highlighted
    /// option keeps ordinary numbered prose inert even if it happens to resemble a list.
    func decisionOption(at point: NSPoint) -> DecisionOption? {
        decisionOptionHit(at: point)?.option
    }

    private func decisionOptionHit(
        at point: NSPoint
    ) -> (option: DecisionOption, options: [DecisionOption], rect: NSRect)? {
        let terminal = getTerminal()
        let rows = max(terminal.rows, 1)
        let row = screenRow(at: point, rows: rows)
        let lines = (0..<rows).map {
            terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? ""
        }
        let options = DecisionParser.parse(lines.joined(separator: "\n"))
        guard options.filter(\.highlighted).count == 1,
              let option = options.first(where: { $0.row == row }) else { return nil }

        let cellH = max(bounds.height / CGFloat(rows), 1)
        let y = isFlipped ? CGFloat(row) * cellH : bounds.height - CGFloat(row + 1) * cellH
        return (option, options, NSRect(x: 0, y: y, width: bounds.width, height: cellH))
    }

    /// Re-read the current screen and synchronously write the keyboard-equivalent input to the
    /// same PTY. This avoids a session lookup/race between hit-testing and delivery.
    fileprivate func activateDecisionOption(at point: NSPoint) -> Bool {
        guard let hit = decisionOptionHit(at: point),
              let input = TerminalChoiceInteraction.input(for: hit.option, among: hit.options)
        else { return false }
        send(source: self, data: ArraySlice(Array(input.utf8)))
        clearInteractiveHover()
        return true
    }

    private func screenRow(at point: NSPoint, rows: Int) -> Int {
        let cellH = max(bounds.height / CGFloat(rows), 1)
        let fromTop = isFlipped ? point.y : bounds.height - point.y
        return min(rows - 1, max(0, Int(fromTop / cellH)))
    }

    private static let wheelForwarder: Any? =
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // hitTest takes superview coordinates; the content view's superview (the window's
            // frame view) uses window coordinates, so locationInWindow is directly usable.
            guard let window = event.window,
                  let hit = window.contentView?.hitTest(event.locationInWindow)
            else { return event }
            var v: NSView? = hit
            while let cur = v {
                if let term = cur as? IMETerminalView {
                    return term.forwardWheel(event) ? nil : event
                }
                v = cur.superview
            }
            return event
        }

    /// Option-drag motion (button 1 held) as an SGR mouse report — SwiftTerm won't send these
    /// in button-event-tracking mode itself, and tmux needs them to extend a copy-mode selection.
    fileprivate func forwardDrag(_ event: NSEvent) {
        let terminal = getTerminal()
        guard terminal.mouseMode == .buttonEventTracking else { return } // anyEvent: SwiftTerm handles it
        let (col, row) = cellPosition(of: event)
        let seq = "\u{1b}[<32;\(col);\(row)M" // 32 = MB1 + motion flag
        send(source: self, data: ArraySlice(Array(seq.utf8)))
    }

    /// 1-based cell coordinates under an event's pointer.
    private func cellPosition(of event: NSEvent) -> (col: Int, row: Int) {
        let terminal = getTerminal()
        let cols = max(terminal.cols, 1), rows = max(terminal.rows, 1)
        let point = convert(event.locationInWindow, from: nil)
        let col = min(cols, max(1, Int(point.x / max(bounds.width / CGFloat(cols), 1)) + 1))
        let fromTop = isFlipped ? point.y : bounds.height - point.y
        let row = min(rows, max(1, Int(fromTop / max(bounds.height / CGFloat(rows), 1)) + 1))
        return (col, row)
    }

    /// Send the wheel event to the pty as an SGR mouse report. Returns false (→ default local
    /// scrolling) when the app didn't ask for mouse events.
    private func forwardWheel(_ event: NSEvent) -> Bool {
        let terminal = getTerminal()
        guard terminal.mouseMode != .off, event.deltaY != 0 else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let cols = max(terminal.cols, 1), rows = max(terminal.rows, 1)
        let col = min(cols, max(1, Int(point.x / max(bounds.width / CGFloat(cols), 1)) + 1))
        let fromTop = isFlipped ? point.y : bounds.height - point.y
        let row = min(rows, max(1, Int(fromTop / max(bounds.height / CGFloat(rows), 1)) + 1))
        let button = event.deltaY > 0 ? 64 : 65 // SGR wheel up / wheel down
        let seq = "\u{1b}[<\(button);\(col);\(row)M"
        send(source: self, data: ArraySlice(Array(seq.utf8)))
        return true
    }

    /// The panel is movable-by-background (drag empty areas to move it), and SwiftTerm's view
    /// doesn't claim its drags — so dragging ON THE TERMINAL moved the whole window instead of
    /// selecting text. Claim them so normal drags become persistent local selections.
    override var mouseDownCanMoveWindow: Bool { false }

    /// The summon panel is non-activating, so the app is usually "inactive" while you use it.
    /// Without first-mouse acceptance, every click/drag on the terminal is swallowed as a
    /// window-activation click and never reaches mouseDown — scroll is exempt from that rule,
    /// which is why scrolling worked while selection and clicks didn't.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Selected text actions

    /// SwiftTerm exposes a local selection through `copy(_:)`, but does not publish the
    /// selection string. Read it through that supported path and restore every pasteboard item
    /// immediately, so opening the action menu never replaces the user's clipboard.
    func selectedTextForMenu() -> String {
        let pasteboard = NSPasteboard.general
        let savedItems = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let saved = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { saved.setData(data, forType: type) }
            }
            return saved
        }

        super.copy(self)
        let selectedText = pasteboard.string(forType: .string) ?? ""
        pasteboard.clearContents()
        if let savedItems, !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
        return selectedText
    }

    /// Build the compact action menu shown after a local terminal selection. Kept separate
    /// from presentation so its contents can be regression-tested without tracking an NSMenu.
    func selectionActionMenu(for rawSelection: String) -> NSMenu? {
        let text = rawSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let menu = NSMenu(title: "Selected Text")
        menu.autoenablesItems = false
        menu.addItem(selectionMenuItem(
            title: "Copy",
            action: #selector(copySelectionFromMenu(_:))
        ))
        let runItem = selectionMenuItem(
            title: "Run in Terminal",
            action: #selector(runSelectionFromMenu(_:))
        )
        runItem.representedObject = text
        menu.addItem(runItem)
        menu.addItem(selectionMenuItem(
            title: "Find in Terminal",
            action: #selector(findSelectionFromMenu(_:))
        ))
        if let url = Self.explicitWebURL(in: text) {
            menu.addItem(.separator())
            let openItem = selectionMenuItem(
                title: "Open Link",
                action: #selector(openSelectionLink(_:))
            )
            openItem.representedObject = url
            menu.addItem(openItem)
        }
        return menu
    }

    private func showSelectionActions(at point: NSPoint) {
        guard let menu = selectionActionMenu(for: selectedTextForMenu()) else { return }
        menu.popUp(positioning: menu.item(withTitle: "Run in Terminal"), at: point, in: self)
    }

    private func selectionMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    private static func explicitWebURL(in text: String) -> URL? {
        guard !text.contains(where: \Character.isWhitespace),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil
        else { return nil }
        return url
    }

    @objc private func copySelectionFromMenu(_ sender: Any) {
        copy(sender)
    }

    @objc private func runSelectionFromMenu(_ sender: Any) {
        guard let command = (sender as? NSMenuItem)?.representedObject as? String else { return }
        runSelectionInTerminal?(command)
    }

    @objc private func findSelectionFromMenu(_ sender: Any) {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.setSearchString.rawValue
        performTextFinderAction(item)
    }

    @objc private func openSelectionLink(_ sender: Any) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    /// SwiftUI parks representable views at ~zero size for a beat while (un)mounting during a
    /// session switch. Letting that through resizes the PTY to 2×1 and back — tmux reflows the
    /// window twice and the agent's TUI re-renders its whole transcript both times (the
    /// "lines flying by" switch artifact, caught red-handed via a window-resized hook).
    /// Ignore degenerate sizes; the real layout follows a frame later.
    override func setFrameSize(_ newSize: NSSize) {
        guard newSize.width >= 50, newSize.height >= 50 else { return }
        super.setFrameSize(newSize)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let a = string as? NSAttributedString { markedText = a.string }
        else if let s = string as? String { markedText = s }
        else { markedText = "" }
        updateMarkedOverlay()
    }

    override func hasMarkedText() -> Bool { !markedText.isEmpty }

    override func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: (markedText as NSString).length)
    }

    override func unmarkText() {
        markedText = ""
        updateMarkedOverlay()
    }

    /// The IME commits: drop the preview — the real character now flows into the session
    /// (and echoes back through the terminal itself).
    override func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = ""
        updateMarkedOverlay()
        super.insertText(string, replacementRange: replacementRange)
    }

    /// tmux echoes a committed syllable after the IME may already have begun composing the
    /// next one. SwiftTerm updates its caret when that output arrives; move our overlay with it.
    override func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        super.rangeChanged(source: source, startY: startY, endY: endY)
        clearLinkHover()
        guard !markedText.isEmpty else { return }
        updateMarkedOverlay()
    }

    /// Draw the composing text over the caret cell, in the terminal's own font/colors.
    private func updateMarkedOverlay() {
        guard !markedText.isEmpty else { markedLabel.isHidden = true; return }
        markedLabel.attributedStringValue = NSAttributedString(string: markedText, attributes: [
            .font: font,
            .foregroundColor: nativeForegroundColor,
            .underlineStyle: NSUnderlineStyle.thick.rawValue,
            .underlineColor: nativeForegroundColor,
        ])
        markedLabel.backgroundColor = nativeBackgroundColor
        markedLabel.sizeToFit()
        // Anchor at the caret: firstRect() reports the caret cell in screen coordinates.
        let screenRect = firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        if let window {
            let local = convert(window.convertFromScreen(screenRect), from: nil)
            markedLabel.setFrameOrigin(NSPoint(x: local.minX, y: min(local.minY, local.maxY)))
        }
        markedLabel.isHidden = false
    }
}

/// Owns a real terminal attached to a tmux session. Keystrokes go straight into the session
/// (Claude), color and resize are handled natively by the emulator. Lives outside the SwiftUI
/// view graph so it isn't recreated on redraws.
@MainActor
final class TerminalController {
    let terminalView: LocalProcessTerminalView
    /// Which tmux session this client is attached to — lets views check the controller still
    /// matches their session while selection changes race the attach task.
    let sessionName: String
    private(set) var alive = true

    private var themeObserver: (any NSObjectProtocol)?

    init(session: String) {
        sessionName = session
        IMETerminalView.installEventBridges() // once: wheel → tmux scrollback, ⌘click → URL
        terminalView = IMETerminalView(frame: .zero) // adds IME composition preview (한글 등)
        terminalView.processDelegate = self // learn when the attach client dies
        TerminalTheme.current.apply(to: terminalView)
        themeObserver = NotificationCenter.default.addObserver(
            forName: .passTerminalThemeChanged, object: nil, queue: .main
        ) { [weak terminalView] _ in
            MainActor.assumeIsolated {
                guard let terminalView else { return }
                TerminalTheme.current.apply(to: terminalView)
            }
        }
    }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    /// Prepare the session (unpin manual sizing, hide tmux's status bar), THEN attach —
    /// strictly ordered so the client's very first draw already happens at the right size
    /// (racing them caused a visible post-attach reflow).
    func start() async {
        await TmuxClient.shared.prepareForAttach(sessionName)
        guard alive else { return } // detached while preparing
        var env = Terminal.getEnvironmentVariables() // TERM, COLORTERM, LANG… but NOT PATH
        env.append("PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(NSHomeDirectory())/.local/bin")
        let tmux = Shell.resolveViaLoginShell("tmux") ?? "/opt/homebrew/bin/tmux"
        // Attach to the existing session; -A would create if missing, but pass already made it.
        terminalView.startProcess(executable: tmux,
                                  args: ["attach-session", "-t", sessionName],
                                  environment: env)
        Log.ui.info("terminal attached to \(self.sessionName, privacy: .public)")
    }

    /// Detach the tmux client (the session keeps running) and tear down the PTY.
    func detach() {
        guard alive else { return }
        alive = false
        terminalView.terminate()
    }

    /// Make the terminal the key window's first responder so keystrokes reach the session.
    /// Retries briefly until the view is in a window.
    func focus(attempt: Int = 0) {
        guard alive, attempt < 20 else { return }
        guard let window = terminalView.window else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.focus(attempt: attempt + 1) }
            return
        }
        let ok = window.makeFirstResponder(terminalView)
        Log.ui.debug("terminal focus attempt \(attempt) firstResponder=\(ok)")
        if !ok {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.focus(attempt: attempt + 1) }
        }
    }
}

/// The attach client's process events. Only termination matters: mark the controller dead so
/// the pool hands out a fresh client next time (e.g. the session was killed, or someone ran
/// `tmux detach` inside it).
extension TerminalController: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in self.alive = false }
    }
}

/// Keeps sessions' terminal clients ATTACHED (LRU) so moving between sessions is instant —
/// no re-attach, no full tmux repaint (an attach makes the agent's renderer repaint its
/// whole transcript top-to-bottom, which reads as content "scrolling in"). Clients stay
/// attached across panel hide/show for the same reason; they die with their session.
@MainActor
final class TerminalPool {
    private var controllers: [String: TerminalController] = [:]
    private var order: [String] = [] // LRU — most recently used last
    private let capacity = 12

    /// The live client for a session — reused if still attached, recreated if it died.
    /// `size`: the frame the view will eventually get on screen. Critical for warmed
    /// (not-yet-mounted) clients: an unsized view reports the 80×25 default to the PTY and
    /// tmux resizes the whole session to it — the agent then renders 80-col output into
    /// history until the first mount (garbled widths when scrolling back).
    func controller(for session: String, size: CGSize? = nil) -> TerminalController {
        if let c = controllers[session], c.alive {
            touch(session)
            return c
        }
        controllers[session]?.detach()
        let c = TerminalController(session: session)
        if let size, size.width > 50, size.height > 50 {
            c.terminalView.setFrameSize(size) // sizes the PTY before the attach lands
        }
        controllers[session] = c
        touch(session)
        Task { await c.start() }
        while order.count > capacity {
            let victim = order.removeFirst()
            controllers.removeValue(forKey: victim)?.detach()
        }
        return c
    }

    /// The pooled live client for a session, if any — no LRU touch, no creation. Lets views
    /// render an already-attached client synchronously while the switch task catches up.
    func peek(_ name: String?) -> TerminalController? {
        guard let name, let c = controllers[name], c.alive else { return nil }
        return c
    }

    /// Pre-attach clients for sessions the user is likely to visit next, so switching to them
    /// shows an already-drawn screen instead of a live repaint. Requires the on-screen
    /// terminal's size so background clients match it (see controller(for:size:)). Bounded so
    /// the current session's slot is never evicted; call BEFORE touching the current session.
    func warm(_ names: [String], size: CGSize?) {
        guard let size, size.width > 50, size.height > 50 else { return } // no reference yet
        for name in names.prefix(capacity - 1) where peek(name) == nil {
            _ = controller(for: name, size: size)
        }
    }

    private func touch(_ name: String) {
        order.removeAll { $0 == name }
        order.append(name)
    }

    /// Drop one session's client (it was killed from pass).
    func drop(_ name: String) {
        order.removeAll { $0 == name }
        controllers.removeValue(forKey: name)?.detach()
    }

    /// Drop clients whose sessions no longer exist.
    func prune(keeping live: Set<String>) {
        for name in controllers.keys where !live.contains(name) { drop(name) }
    }
}

/// Embeds the terminal view. `makeNSView` returns the controller's long-lived view; we never
/// recreate it in `updateNSView`.
struct TerminalPaneView: NSViewRepresentable {
    let controller: TerminalController
    let runSelectionInTerminal: ((String) -> Void)?

    init(
        controller: TerminalController,
        runSelectionInTerminal: ((String) -> Void)? = nil
    ) {
        self.controller = controller
        self.runSelectionInTerminal = runSelectionInTerminal
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        (controller.terminalView as? IMETerminalView)?.runSelectionInTerminal =
            runSelectionInTerminal
        return controller.terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        (nsView as? IMETerminalView)?.runSelectionInTerminal = runSelectionInTerminal
    }
}
