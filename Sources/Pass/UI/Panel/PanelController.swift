import AppKit
import SwiftUI

/// Owns the single floating panel and its SwiftUI content. Handles summon/dismiss and
/// (from M3) deep-linking to a session when a notification is clicked.
@MainActor
final class PanelController {
    private let appModel: AppModel
    private var panel: SummonPanel?

    private let defaultSize = NSSize(width: 680, height: 460)

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    private func makePanel() -> SummonPanel {
        let rect = NSRect(origin: .zero, size: savedSize)
        let panel = SummonPanel(contentRect: rect)
        let root = CommandView()
            .environment(appModel)
        panel.contentView = NSHostingView(rootView: root)
        panel.onCancel = { [weak self] in self?.hide() }
        panel.onGoBack = { [weak self] in self?.appModel.requestBack() }
        panel.onToggleFloat = { [weak self] in self?.toggleFloating() }
        // Persist the user's chosen size across summons (position is re-centered each time).
        panel.delegate = resizeObserver
        return panel
    }

    /// Remembers the last panel size the user dragged to.
    private var savedSize: NSSize {
        get {
            let w = UserDefaults.standard.double(forKey: "panel.width")
            let h = UserDefaults.standard.double(forKey: "panel.height")
            return (w >= 460 && h >= 300) ? NSSize(width: w, height: h) : defaultSize
        }
        set {
            UserDefaults.standard.set(newValue.width, forKey: "panel.width")
            UserDefaults.standard.set(newValue.height, forKey: "panel.height")
        }
    }

    private lazy var resizeObserver = PanelResizeObserver { [weak self] size in
        self?.savedSize = size
    }

    /// Floating (always-on-top summon panel) vs a normal window that can sit behind others
    /// and stay open while you work. Persisted.
    var isFloating: Bool {
        get { (UserDefaults.standard.object(forKey: "panel.floating") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "panel.floating"); applyMode() }
    }

    func toggleFloating() { isFloating.toggle(); if !isVisible { show(preselecting: nil) } }

    private func applyMode() {
        guard let panel else { return }
        panel.isFloatingPanel = isFloating
        panel.level = isFloating ? .floating : .normal
        panel.collectionBehavior = isFloating
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() } else { show(preselecting: nil) }
    }

    func show(preselecting session: String?) {
        let panel = panel ?? makePanel()
        self.panel = panel

        if let session { appModel.pendingPreselect = session }

        applyMode()
        // Floating: re-center where you're working (Spotlight-style). Normal window: leave it
        // wherever the user last put it.
        if isFloating { centerOnActiveScreen(panel) }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        appModel.focusToken &+= 1 // tell the omnibox to (re)take focus on every show
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func centerOnActiveScreen(_ panel: NSPanel) {
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.08 // sit slightly above center
        )
        panel.setFrameOrigin(origin)
    }
}

/// NSWindowDelegate that reports the panel's new size when the user resizes it.
final class PanelResizeObserver: NSObject, NSWindowDelegate {
    private let onResize: (NSSize) -> Void
    init(onResize: @escaping (NSSize) -> Void) { self.onResize = onResize }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onResize(window.frame.size)
    }
}
