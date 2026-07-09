import AppKit

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
            // ⌘[ steps back (embedded terminal owns Esc).
            if event.charactersIgnoringModifiers == "[" {
                onGoBack?()
                return true
            }
            // ⌘⇧F toggles floating vs normal window.
            if event.modifierFlags.contains(.shift),
               event.charactersIgnoringModifiers?.lowercased() == "f" {
                onToggleFloat?()
                return true
            }
            let cmdShift = event.modifierFlags.contains(.shift)
            let selector: Selector?
            switch event.charactersIgnoringModifiers {
            case "x": selector = #selector(NSText.cut(_:))
            case "c": selector = #selector(NSText.copy(_:))
            case "v": selector = #selector(NSText.paste(_:))
            case "a": selector = #selector(NSResponder.selectAll(_:))
            case "z": selector = cmdShift ? Selector(("redo:")) : Selector(("undo:"))
            default:  selector = nil
            }
            if let selector, NSApp.sendAction(selector, to: nil, from: self) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc → let the controller decide (walk the nav stack up, then dismiss).
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
