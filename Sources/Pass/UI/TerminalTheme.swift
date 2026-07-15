import AppKit
import SwiftTerm

extension Notification.Name {
    /// Posted by Settings when the terminal theme changes — every live terminal re-applies.
    static let passTerminalThemeChanged = Notification.Name("pass.terminalThemeChanged")
}

/// Color themes for the embedded terminals. Persisted in UserDefaults ("terminalTheme");
/// applied to every client (home pool + detail) at attach and live on change.
enum TerminalTheme: String, CaseIterable {
    case classic        // VGA/xterm palette on the system text background (SwiftTerm stock)
    case dracula
    case oneDark
    case solarizedDark
    case gruvbox

    static let storageKey = "terminalTheme"

    static var current: TerminalTheme {
        TerminalTheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .classic
    }

    var label: String {
        switch self {
        case .classic:       return "Classic"
        case .dracula:       return "Dracula"
        case .oneDark:       return "One Dark"
        case .solarizedDark: return "Solarized Dark"
        case .gruvbox:       return "Gruvbox"
        }
    }

    @MainActor
    func apply(to view: TerminalView) {
        view.installColors(ansi.map(Self.term))
        view.nativeForegroundColor = Self.ns(foreground)
        view.nativeBackgroundColor = Self.ns(background)
    }

    // MARK: palettes (0-7 normal, 8-15 bright — standard scheme definitions)

    private var foreground: UInt32 {
        switch self {
        case .classic:       return 0xdddddd
        case .dracula:       return 0xf8f8f2
        case .oneDark:       return 0xabb2bf
        case .solarizedDark: return 0x839496
        case .gruvbox:       return 0xebdbb2
        }
    }

    private var background: UInt32 {
        switch self {
        case .classic:       return 0x1e1e1e
        case .dracula:       return 0x282a36
        case .oneDark:       return 0x282c34
        case .solarizedDark: return 0x002b36
        case .gruvbox:       return 0x282828
        }
    }

    private var ansi: [UInt32] {
        switch self {
        case .classic:
            return [0x000000, 0xaa0000, 0x00aa00, 0xaa5500, 0x0000aa, 0xaa00aa, 0x00aaaa, 0xaaaaaa,
                    0x555555, 0xff5555, 0x55ff55, 0xffff55, 0x5555ff, 0xff55ff, 0x55ffff, 0xffffff]
        case .dracula:
            return [0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
                    0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff]
        case .oneDark:
            return [0x282c34, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xabb2bf,
                    0x5c6370, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xffffff]
        case .solarizedDark:
            return [0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
                    0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3]
        case .gruvbox:
            return [0x282828, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0xa89984,
                    0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f, 0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2]
        }
    }

    private static func term(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16((hex >> 16 & 0xff) * 257),
                        green: UInt16((hex >> 8 & 0xff) * 257),
                        blue: UInt16((hex & 0xff) * 257))
    }

    private static func ns(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255,
                green: CGFloat(hex >> 8 & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
    }
}
