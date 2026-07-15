import AppKit

/// The menu-bar glyph, drawn in code to match the app icon's motif: three octagons stepping
/// up the diagonal. A TEMPLATE image (black + alpha), so macOS tints it correctly for
/// light/dark menu bars and the selected state.
@MainActor
enum MenuBarIcon {
    static let image: NSImage = {
        let side: CGFloat = 18
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            func octagon(_ cx: CGFloat, _ cy: CGFloat, _ radius: CGFloat, _ alpha: CGFloat) {
                let path = NSBezierPath()
                for i in 0..<8 {
                    let a = CGFloat(i) * .pi / 4 + .pi / 8 // flat-ish top, like the artwork
                    let p = NSPoint(x: cx + cos(a) * radius, y: cy + sin(a) * radius)
                    i == 0 ? path.move(to: p) : path.line(to: p)
                }
                path.close()
                NSColor.black.withAlphaComponent(alpha).setFill()
                path.fill()
            }
            // Big top-right, medium centre, small bottom-left — the app icon's composition.
            octagon(11.8, 11.8, 5.9, 1.0)
            octagon(6.6, 6.6, 4.0, 0.62)
            octagon(3.0, 3.0, 2.6, 0.35)
            return true
        }
        img.isTemplate = true
        return img
    }()
}
