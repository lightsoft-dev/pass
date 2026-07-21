import AppKit
import IOSurface
import SwiftUI

/// Layer-backed view that shows the stream's latest IOSurface, aspect-fit on black — the
/// mirror's "screen". Installing the surface as layer contents is zero-copy: the compositor
/// reads the capture buffer directly, so a 60fps mirror costs almost nothing.
final class MirrorFrameNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(_ surface: IOSurfaceRef) {
        layer?.contents = surface
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }
}

/// SwiftUI wrapper — routes the engine's frames (already on the main queue) into the view.
struct MirrorFrameView: NSViewRepresentable {
    let engine: MirrorEngine

    func makeNSView(context: Context) -> MirrorFrameNSView {
        let view = MirrorFrameNSView(frame: .zero)
        engine.onFrame = { [weak view] surface in view?.present(surface) }
        return view
    }

    func updateNSView(_ nsView: MirrorFrameNSView, context: Context) {
        engine.onFrame = { [weak nsView] surface in nsView?.present(surface) }
    }
}
