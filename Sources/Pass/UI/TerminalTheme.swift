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
    case nord
    case tokyoNight
    case catppuccinMocha
    case monokai
    case solarizedLight
    case githubLight

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
        case .nord:          return "Nord"
        case .tokyoNight:    return "Tokyo Night"
        case .catppuccinMocha: return "Catppuccin Mocha"
        case .monokai:       return "Monokai"
        case .solarizedLight: return "Solarized Light"
        case .githubLight:   return "GitHub Light"
        }
    }

    /// Short descriptions make the palette picker useful without requiring users to know the
    /// theme names already.
    var detail: String {
        switch self {
        case .classic: return "Familiar xterm contrast"
        case .dracula: return "Lavender night glow"
        case .oneDark: return "Balanced editor dark"
        case .solarizedDark: return "Low-glare blue green"
        case .gruvbox: return "Warm retro contrast"
        case .nord: return "Cool, muted clarity"
        case .tokyoNight: return "Deep city neon"
        case .catppuccinMocha: return "Soft pastel dark"
        case .monokai: return "Vivid code classic"
        case .solarizedLight: return "Warm paper, low glare"
        case .githubLight: return "Clean daylight contrast"
        }
    }

    /// The theme's background as an AppKit color — used by the SwiftUI wrapper to paint a
    /// same-color inset around the terminal (text breathes, but the "terminal" still reads
    /// as filling its whole section).
    var nsBackground: NSColor { Self.ns(background) }
    var nsForeground: NSColor { Self.ns(foreground) }
    /// A compact, representative palette for the Settings preview. The full 16-color ANSI
    /// palette remains private to avoid coupling terminal rendering to the Settings UI.
    var previewColors: [NSColor] {
        [foreground, ansi[1], ansi[2], ansi[4], ansi[6]].map(Self.ns)
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
        case .nord:          return 0xd8dee9
        case .tokyoNight:    return 0xc0caf5
        case .catppuccinMocha: return 0xcdd6f4
        case .monokai:       return 0xf8f8f2
        case .solarizedLight: return 0x657b83
        case .githubLight:   return 0x24292f
        }
    }

    private var background: UInt32 {
        switch self {
        case .classic:       return 0x1e1e1e
        case .dracula:       return 0x282a36
        case .oneDark:       return 0x282c34
        case .solarizedDark: return 0x002b36
        case .gruvbox:       return 0x282828
        case .nord:          return 0x2e3440
        case .tokyoNight:    return 0x1a1b26
        case .catppuccinMocha: return 0x1e1e2e
        case .monokai:       return 0x272822
        case .solarizedLight: return 0xfdf6e3
        case .githubLight:   return 0xf6f8fa
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
        case .nord:
            return [0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
                    0x4c566a, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x8fbcbb, 0xeceff4]
        case .tokyoNight:
            return [0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
                    0x414868, 0xff7a93, 0xb9f27c, 0xff9e64, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5]
        case .catppuccinMocha:
            return [0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xcba6f7, 0x94e2d5, 0xbac2de,
                    0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xcba6f7, 0x94e2d5, 0xa6adc8]
        case .monokai:
            return [0x272822, 0xf92672, 0xa6e22e, 0xf4bf75, 0x66d9ef, 0xae81ff, 0xa1efe4, 0xf8f8f2,
                    0x75715e, 0xf92672, 0xa6e22e, 0xf4bf75, 0x66d9ef, 0xae81ff, 0xa1efe4, 0xf9f8f5]
        case .solarizedLight:
            return [0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
                    0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3]
        case .githubLight:
            return [0x24292f, 0xd73a49, 0x22863a, 0xb08800, 0x005cc5, 0x6f42c1, 0x1b7c83, 0x6a737d,
                    0x959da5, 0xcb2431, 0x22863a, 0xb08800, 0x0366d6, 0x6f42c1, 0x1b7c83, 0x24292f]
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
