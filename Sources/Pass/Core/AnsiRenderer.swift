import SwiftUI

/// Parses `tmux capture-pane -e` output (visible screen + SGR color escapes, no cursor
/// movement) into a SwiftUI AttributedString. Handles the common SGR subset Claude's TUI
/// uses: reset, bold/dim, fg/bg (16-color, 256-color, truecolor), inverse.
enum AnsiRenderer {
    struct Style {
        var fg: Color?
        var bg: Color?
        var bold = false
        var faint = false
        var inverse = false
    }

    static func attributed(_ raw: String, font: Font) -> AttributedString {
        var out = AttributedString()
        var style = Style()
        let scalars = Array(raw.unicodeScalars)
        var i = 0
        var runStart = 0

        func flushRun(upTo end: Int) {
            guard end > runStart else { return }
            let text = String(String.UnicodeScalarView(scalars[runStart..<end]))
            var piece = AttributedString(text)
            piece.font = style.bold ? font.bold() : font
            let fg = style.inverse ? (style.bg ?? .black) : style.fg
            let bg = style.inverse ? (style.fg ?? .primary) : style.bg
            if let fg { piece.foregroundColor = fg }
            else if style.faint { piece.foregroundColor = .secondary }
            if let bg { piece.backgroundColor = bg }
            out += piece
        }

        while i < scalars.count {
            guard scalars[i] == "\u{1b}", i + 1 < scalars.count else { i += 1; continue }
            let next = scalars[i + 1]
            if next == "[" {
                // CSI ... final-byte. We only interpret the SGR (`m`) form; others are skipped.
                flushRun(upTo: i)
                var j = i + 2
                var params = ""
                while j < scalars.count, !isCSIFinal(scalars[j]), scalars[j] != "\u{1b}" {
                    params.unicodeScalars.append(scalars[j]); j += 1
                }
                if j < scalars.count, scalars[j] == "m" { apply(params, to: &style) }
                i = (j < scalars.count && scalars[j] != "\u{1b}") ? j + 1 : j
                runStart = i
            } else if next == "]" {
                // OSC ... terminated by BEL (0x07) or ST (ESC \) — e.g. hyperlinks, titles.
                flushRun(upTo: i)
                var j = i + 2
                while j < scalars.count {
                    if scalars[j] == "\u{07}" { j += 1; break }
                    if scalars[j] == "\u{1b}", j + 1 < scalars.count, scalars[j + 1] == "\\" { j += 2; break }
                    j += 1
                }
                i = j; runStart = i
            } else {
                // Other two-byte escape (charset selection, etc.) — drop it.
                flushRun(upTo: i)
                i += 2; runStart = i
            }
        }
        flushRun(upTo: scalars.count)
        return out
    }

    /// CSI final bytes are 0x40–0x7E (`@`…`~`). Parameter/intermediate bytes precede them.
    private static func isCSIFinal(_ s: Unicode.Scalar) -> Bool {
        (0x40...0x7E).contains(s.value)
    }

    private static func apply(_ params: String, to style: inout Style) {
        let codes = params.split(separator: ";").map { Int($0) ?? 0 }
        var k = 0
        if codes.isEmpty { style = Style(); return }
        while k < codes.count {
            let c = codes[k]
            switch c {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: style.faint = true
            case 7: style.inverse = true
            case 22: style.bold = false; style.faint = false
            case 27: style.inverse = false
            case 30...37: style.fg = basic(c - 30)
            case 39: style.fg = nil
            case 40...47: style.bg = basic(c - 40)
            case 49: style.bg = nil
            case 90...97: style.fg = bright(c - 90)
            case 100...107: style.bg = bright(c - 100)
            case 38, 48:
                // extended color: 38;5;n (256) or 38;2;r;g;b (truecolor)
                if k + 1 < codes.count, codes[k + 1] == 5, k + 2 < codes.count {
                    let color = xterm256(codes[k + 2]); if c == 38 { style.fg = color } else { style.bg = color }
                    k += 2
                } else if k + 1 < codes.count, codes[k + 1] == 2, k + 4 < codes.count {
                    let color = Color(.sRGB, red: Double(codes[k+2])/255, green: Double(codes[k+3])/255, blue: Double(codes[k+4])/255)
                    if c == 38 { style.fg = color } else { style.bg = color }
                    k += 4
                }
            default: break
            }
            k += 1
        }
    }

    // Standard 16-color palette (approximate, tuned for a dark background).
    private static func basic(_ n: Int) -> Color {
        [Color(hex: 0x000000), .init(hex: 0xcc3333), .init(hex: 0x33aa33), .init(hex: 0xcccc33),
         .init(hex: 0x4499ee), .init(hex: 0xcc55cc), .init(hex: 0x33cccc), .init(hex: 0xcccccc)][safe: n] ?? .primary
    }
    private static func bright(_ n: Int) -> Color {
        [Color(hex: 0x777777), .init(hex: 0xff5555), .init(hex: 0x55ff55), .init(hex: 0xffff55),
         .init(hex: 0x77bbff), .init(hex: 0xff77ff), .init(hex: 0x55ffff), .init(hex: 0xffffff)][safe: n] ?? .primary
    }
    private static func xterm256(_ n: Int) -> Color {
        if n < 8 { return basic(n) }
        if n < 16 { return bright(n - 8) }
        if n < 232 {
            let c = n - 16
            let r = (c / 36) % 6, g = (c / 6) % 6, b = c % 6
            func lvl(_ v: Int) -> Double { v == 0 ? 0 : Double(55 + v * 40) / 255 }
            return Color(.sRGB, red: lvl(r), green: lvl(g), blue: lvl(b))
        }
        let v = Double(8 + (n - 232) * 10) / 255
        return Color(.sRGB, red: v, green: v, blue: v)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
