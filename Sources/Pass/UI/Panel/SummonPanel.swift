import AppKit

/// Plain (unmodified) navigation keys, routed through performKeyEquivalent rather than
/// SwiftUI's `.onKeyPress` — the latter depends on which control currently has focus in the
/// responder chain, which SwiftUI's FocusState can desync after a mouse click reassigns real
/// AppKit first-responder status. performKeyEquivalent is asked about EVERY key-down before
/// the first responder ever sees it, so this works no matter what has focus.
enum PanelNavKey {
    case up, down, returnKey, escape, tab, delete
    /// ⌘M — manually mark the selected session as checked.
    case markChecked
    /// ⌘P — toggle the centered quick command (the home terminal owns plain keys by default).
    case toggleInput
    /// ⇧⇧ (double-tap, routed from DoubleTapHotkey) — hop to the next session waiting on you.
    case nextWaiting
    /// ⌘D — open the selected session's project spec document.
    case openSpecs
    /// ⌘N — quick command in new-session mode (pick a project, ⏎ starts a session).
    case newSession
    /// ⌘T — quick command prefilled with a worktree branch for the selected session.
    case newWorktree
    /// ⌘B — toggle the current session's browser split (opens a blank tab if none).
    case toggleBrowser
    /// ⌘L — focus the browser's address field (shows the split first if needed).
    case focusAddress
    /// ⌘⇧B — expand the browser over the whole workspace / back to the split.
    case expandBrowser
}

struct PanelNavEvent {
    var key: PanelNavKey
    var command: Bool
    var option: Bool
}

/// A Spotlight/Raycast-style floating panel: non-activating (takes keystrokes without
/// activating pass or deactivating the frontmost app), keyboard-first, appears over
/// full-screen apps. Dismissal is explicit only (Esc / hotkey toggle) — it does NOT
/// hide on focus loss, so you can copy from your editor into a reply field.
final class SummonPanel: NSPanel {
    var onCancel: (() -> Void)?
    /// ⌘[ — used to step back from an embedded terminal (which consumes Esc itself).
    var onGoBack: (() -> Void)?
    /// ⌘⇧F — toggle floating vs normal window.
    var onToggleFloat: (() -> Void)?
    /// Plain Up/Down/Return/Escape — return true to consume the event, false to let it fall
    /// through to the normal responder chain (e.g. so Escape can still close the panel, or so
    /// a real terminal view gets its arrow keys when one is open).
    var onNavigate: ((PanelNavEvent) -> Bool)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        minSize = NSSize(width: 460, height: 300)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isReleasedWhenClosed = false
        // Show over full-screen spaces. (canJoinAllSpaces and moveToActiveSpace are
        // mutually exclusive — use only canJoinAllSpaces.)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    // Required so the panel (and its text fields) can receive keyboard input.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// An accessory (LSUIElement) app doesn't own the menu bar, so its main-menu key
    /// equivalents (⌘X/C/V/A/Z) never fire. Route them to the first responder ourselves —
    /// this is what makes copy/paste work inside the panel's text fields.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            // Letter shortcuts must ALSO match by physical key code: with a non-Latin input
            // source active (한글 등), charactersIgnoringModifiers reports the mapped character
            // ("ㅓ" for the J key), so a pure character comparison never fires.
            let ch = event.charactersIgnoringModifiers?.lowercased()
            let code = event.keyCode
            func key(_ letter: String, _ kc: UInt16) -> Bool { ch == letter || code == kc }

            // ⌘[ or ⌘W step back to the list (the embedded terminal owns Esc, so we can't
            // use it here). ⌘W is intercepted so it never closes the whole panel window.
            if key("[", 33) || key("w", 13) {
                onGoBack?()
                return true
            }
            // ⌘⇧F toggles floating vs normal window.
            if event.modifierFlags.contains(.shift), key("f", 3) {
                onToggleFloat?()
                return true
            }
            // ⌘⌫ asks to kill the selected session (the view confirms first).
            if code == 51, onNavigate?(PanelNavEvent(key: .delete, command: true, option: false)) == true {
                return true
            }
            // ⌘J / ⌘K — vim-style session movement (down / up), same as ⌘↓ / ⌘↑.
            if key("j", 38),
               onNavigate?(PanelNavEvent(key: .down, command: true, option: false)) == true {
                return true
            }
            if key("k", 40),
               onNavigate?(PanelNavEvent(key: .up, command: true, option: false)) == true {
                return true
            }
            // ⌘P toggles the centered quick command — typing goes into the embedded terminal
            // by default.
            if key("p", 35),
               onNavigate?(PanelNavEvent(key: .toggleInput, command: true, option: false)) == true {
                return true
            }
            // ⌘D opens the selected session's project spec document.
            if key("d", 2),
               onNavigate?(PanelNavEvent(key: .openSpecs, command: true, option: false)) == true {
                return true
            }
            // ⌘M manually clears the selected session's needs-you state.
            if key("m", 46),
               onNavigate?(PanelNavEvent(key: .markChecked, command: true, option: false)) == true {
                return true
            }
            // ⌘N — new session (quick command in project-pick mode).
            if key("n", 45),
               onNavigate?(PanelNavEvent(key: .newSession, command: true, option: false)) == true {
                return true
            }
            // ⌘T — new worktree session off the selected session (branch name prefilled).
            if key("t", 17),
               onNavigate?(PanelNavEvent(key: .newWorktree, command: true, option: false)) == true {
                return true
            }
            // ⌘⇧B expands the browser; plain ⌘B toggles the split — shift checked first
            // because the plain match would also fire with shift held.
            if event.modifierFlags.contains(.shift), key("b", 11),
               onNavigate?(PanelNavEvent(key: .expandBrowser, command: true, option: false)) == true {
                return true
            }
            if key("b", 11),
               onNavigate?(PanelNavEvent(key: .toggleBrowser, command: true, option: false)) == true {
                return true
            }
            // ⌘L — browser address field (browser keys work on home and in the detail view).
            if key("l", 37),
               onNavigate?(PanelNavEvent(key: .focusAddress, command: true, option: false)) == true {
                return true
            }
            let cmdShift = event.modifierFlags.contains(.shift)
            var selector: Selector?
            if key("x", 7) { selector = #selector(NSText.cut(_:)) }
            else if key("c", 8) { selector = #selector(NSText.copy(_:)) }
            else if key("v", 9) { selector = #selector(NSText.paste(_:)) }
            else if key("a", 0) { selector = #selector(NSResponder.selectAll(_:)) }
            else if key("z", 6) { selector = cmdShift ? Selector(("redo:")) : Selector(("undo:")) }
            else { selector = nil }
            if let selector, NSApp.sendAction(selector, to: nil, from: self) {
                return true
            }
        }

        if !event.modifierFlags.contains(.control) {
            let cmd = event.modifierFlags.contains(.command)
            let opt = event.modifierFlags.contains(.option)
            let key: PanelNavKey?
            switch event.keyCode {
            case 125: key = .down
            case 126: key = .up
            case 36:  key = .returnKey
            case 53:  key = .escape
            case 48:  key = .tab
            default:  key = nil
            }
            if let key, onNavigate?(PanelNavEvent(key: key, command: cmd, option: opt)) == true {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc that nothing handled. The controller leaves this nil — Esc never dismisses the
    /// panel (it interrupts the agent in the embedded terminal instead).
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
