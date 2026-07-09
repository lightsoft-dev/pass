import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Default: ⌥Space. User-rebindable via a KeyboardShortcuts.Recorder (Settings, later).
    static let summonPass = Self("summonPass", default: .init(.space, modifiers: [.option]))
}

enum HotkeyService {
    /// Register the global summon hotkey. `handler` runs on the main actor.
    static func registerSummon(_ handler: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyUp(for: .summonPass) {
            MainActor.assumeIsolated { handler() }
        }
        Log.app.info("global hotkey registered (summonPass)")
    }
}
