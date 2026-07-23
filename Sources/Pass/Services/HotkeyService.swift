import AppKit
import KeyboardShortcuts

enum SummonShortcutMode: String, CaseIterable, Identifiable {
    static let storageKey = "summonShortcutMode"

    case doubleCommand
    case optionSpace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .doubleCommand: "Double Command  ⌘⌘"
        case .optionSpace: "Option Space  ⌥Space"
        }
    }

    static var current: Self {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let mode = Self(rawValue: raw) else { return .doubleCommand }
        return mode
    }
}

extension KeyboardShortcuts.Name {
    /// Fixed ⌥Space summon option. Settings chooses this OR ⌘⌘, never both.
    static let summonPass = Self("summonPass", default: .init(.space, modifiers: [.option]))
}

enum HotkeyService {
    /// Register the fixed ⌥Space global summon handler. Its enabled state follows the selected
    /// SummonShortcutMode, while the handler itself only needs to be installed once.
    static func registerSummon(_ handler: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.setShortcut(.init(.space, modifiers: [.option]), for: .summonPass)
        KeyboardShortcuts.onKeyUp(for: .summonPass) {
            MainActor.assumeIsolated { handler() }
        }
        Log.app.info("global hotkey registered (summonPass)")
    }

    static func setOptionSpaceEnabled(_ enabled: Bool) {
        if enabled {
            KeyboardShortcuts.enable(.summonPass)
        } else {
            KeyboardShortcuts.disable(.summonPass)
        }
    }
}

/// Detects a double-tap of a single modifier key (⌘⌘ summons pass; ⇧⇧ hops to the next
/// waiting session) — two clean press-releases in quick succession. Carbon hotkeys
/// (KeyboardShortcuts) can't express modifier-only shortcuts, so this watches flagsChanged
/// directly. Global flagsChanged monitors work WITHOUT Accessibility trust (only
/// keyDown/keyUp monitors need it), so this works out of the box.
///
/// A "clean tap": the modifier goes down ALONE, comes back up quickly, and no other key was
/// pressed while it was down (⌘C / ⇧A are not taps — guarded by the keyDown monitors where
/// available, and by the max hold time everywhere).
@MainActor
final class DoubleTapHotkey {
    private let modifier: NSEvent.ModifierFlags
    private let fire: () -> Void
    private var monitors: [Any] = []

    private var cmdDownAt: Date?   // the modifier is currently held (went down alone) since this moment
    private var dirty = false      // another key joined while it was down → it was a shortcut
    private var lastTapAt: Date?   // when the previous clean tap completed (modifier released)

    private let maxHold: TimeInterval = 0.35   // a tap's press-to-release must be quicker than this
    private let interval: TimeInterval = 0.45  // max gap between the two taps' completions

    init(modifier: NSEvent.ModifierFlags = .command, onDoubleTap: @escaping @MainActor () -> Void) {
        self.modifier = modifier
        fire = onDoubleTap
        let flags: (NSEvent) -> Void = { [weak self] e in
            MainActor.assumeIsolated { self?.handleFlags(e) }
        }
        let key: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.dirty = true } // ⌘<key> shortcut, not a tap
        }
        // Local monitors cover pass's own windows; global ones cover every other app.
        // (The global keyDown monitor silently delivers nothing unless the app is trusted for
        // Accessibility — the maxHold heuristic still filters most shortcut presses then.)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
            flags(e); return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            key(e); return e
        } as Any)
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: key) {
            monitors.append(m)
        }
        Log.app.info("double-tap hotkey registered (\(self.modifier.rawValue))")
    }

    func invalidate() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        cmdDownAt = nil
        lastTapAt = nil
    }

    private func handleFlags(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == modifier {
            // The modifier pressed alone → a tap candidate starts.
            cmdDownAt = Date()
            dirty = false
        } else if mods.isEmpty {
            // Everything released — did a clean, quick ⌘ tap just complete?
            let downAt = cmdDownAt
            cmdDownAt = nil
            guard let downAt, !dirty, Date().timeIntervalSince(downAt) < maxHold else {
                lastTapAt = nil // a long hold / shortcut press breaks any pending sequence
                return
            }
            if let last = lastTapAt, Date().timeIntervalSince(last) < interval {
                lastTapAt = nil
                fire()
            } else {
                lastTapAt = Date() // first tap — wait for the second
            }
        } else {
            // Some other modifier (alone or in a combo) — not a clean tap.
            cmdDownAt = nil
            lastTapAt = nil
        }
    }
}
