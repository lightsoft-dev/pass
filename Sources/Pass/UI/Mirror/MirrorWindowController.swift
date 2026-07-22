import AppKit
import SwiftUI

/// Owns the Vysor-style device-mirror panel: a resizable window (floating by default, so it
/// behaves like a visor over your editor) that live-mirrors one on-screen window — an iOS
/// Simulator, an Android emulator, or real hardware shown through QuickTime/scrcpy. While a
/// stream is live the panel is locked to the device's aspect ratio, so it always reads as a
/// phone screen rather than a letterboxed video.
@MainActor
final class MirrorWindowController {
    private let engine = MirrorEngine()
    private var panel: NSPanel?

    /// Size the panel returns to whenever the source picker is showing.
    private let pickerSize = NSSize(width: 440, height: 540)
    private let minContentSize = NSSize(width: 240, height: 200)

    /// Window-delegate shim, PanelResizeObserver-style — the controller itself stays a plain
    /// MainActor class.
    private lazy var panelDelegate = MirrorPanelDelegate(onClose: { [weak self] in
        self?.engine.shutdown()
    })

    /// Floating keeps the mirror above every window and follows you across Spaces (the visor
    /// behavior); off, it's a normal window you can stack like any other. Persisted.
    var isFloating: Bool {
        get { (UserDefaults.standard.object(forKey: "mirror.floating") as? Bool) ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "mirror.floating")
            applyLevel()
        }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        applyLevel()
        NSApp.activate(ignoringOtherApps: true)
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        engine.windowShown()
    }

    private func makePanel() -> NSPanel {
        engine.onStreamChange = { [weak self] size, name in
            self?.streamChanged(size: size, name: name)
        }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: pickerSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Device Mirror"
        panel.minSize = minContentSize
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = panelDelegate
        let hosting = NSHostingView(rootView: MirrorView(
            engine: engine,
            onToggleFloat: { [weak self] in self?.isFloating.toggle() }
        ))
        // The panel's size is managed here (aspect lock while streaming); don't let the
        // SwiftUI content impose its own window sizing constraints on top.
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }

    private func applyLevel() {
        guard let panel else { return }
        panel.isFloatingPanel = isFloating
        panel.level = isFloating ? .floating : .normal
        panel.collectionBehavior = isFloating
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenAuxiliary]
    }

    /// Lock the panel to the device's aspect ratio while streaming; restore the picker size
    /// (and free resizing) when the stream ends.
    private func streamChanged(size: CGSize, name: String?) {
        guard let panel else { return }
        panel.title = name.map { "Mirror · \($0)" } ?? "Device Mirror"
        guard size.width > 0, size.height > 0 else {
            panel.contentAspectRatio = .zero
            panel.setContentSize(pickerSize)
            return
        }
        panel.contentAspectRatio = size
        let currentWidth = panel.contentRect(forFrameRect: panel.frame).width
        let width = max(minContentSize.width, currentWidth)
        panel.setContentSize(NSSize(width: width, height: (width * size.height / size.width).rounded()))
    }
}

/// NSWindowDelegate that reports the mirror panel closing (so the stream stops with it).
private final class MirrorPanelDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
