import AppKit
import SwiftUI

/// Owns the single floating panel and its SwiftUI content. Handles summon/dismiss and
/// (from M3) deep-linking to a session when a notification is clicked.
@MainActor
final class PanelController {
    private let appModel: AppModel
    private var panel: SummonPanel?
    private var settingsPresented = false

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
        // Esc never closes the panel — it belongs to the embedded terminal (interrupting the
        // agent) and to in-view editing. Dismiss with the selected global shortcut instead.
        panel.onCancel = nil
        panel.onGoBack = { [weak self] in self?.appModel.requestBack() }
        panel.onToggleFloat = { [weak self] in self?.toggleFloating() }
        panel.onNavigate = { [weak self] event in self?.appModel.keyHandler?(event) ?? false }
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

    /// Remembers where the user dragged the panel in normal-window mode (floating mode always
    /// re-centers, so we don't persist its programmatic re-centering).
    private var savedOrigin: NSPoint? {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: "panel.x") != nil, d.object(forKey: "panel.y") != nil else { return nil }
            return NSPoint(x: d.double(forKey: "panel.x"), y: d.double(forKey: "panel.y"))
        }
        set {
            guard let newValue else { return }
            UserDefaults.standard.set(newValue.x, forKey: "panel.x")
            UserDefaults.standard.set(newValue.y, forKey: "panel.y")
        }
    }

    private lazy var resizeObserver = PanelResizeObserver(
        onResize: { [weak self] size in self?.savedSize = size },
        onMove: { [weak self] origin in
            // Only remember drags in normal mode — floating mode re-centers itself each summon.
            if self?.isFloating == false { self?.savedOrigin = origin }
        }
    )

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
        // Keep the summon panel visible while Settings is open, but temporarily lower it so
        // the normal Settings window can sit in front. Closing Settings restores floating mode.
        panel.level = isFloating && !settingsPresented ? .floating : .normal
        panel.collectionBehavior = isFloating
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
    }

    func setSettingsPresented(_ presented: Bool) {
        settingsPresented = presented
        applyMode()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// The panel currently owns the keyboard (it's the key window). Gate for panel-scoped
    /// modifier gestures like ⇧⇧ so they don't fire while typing in other apps.
    var isKey: Bool { panel?.isKeyWindow ?? false }

    func toggle() {
        if !isVisible { show(preselecting: nil); return }
        // Visible but not focused (buried behind other windows in normal mode, or the user is
        // in another app) → the hotkey means "get me to pass": raise it instead of hiding.
        if panel?.isKeyWindow == true { hide() } else { raise() }
    }

    /// Bring the already-visible panel to the front and give it the keyboard — WITHOUT
    /// repositioning or resetting its view state (unlike show).
    private func raise() {
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func show(preselecting session: String?) {
        let panel = panel ?? makePanel()
        self.panel = panel

        if let session { appModel.pendingPreselect = session }

        applyMode()
        // Floating: re-center where you're working (Spotlight-style). Normal window: restore the
        // spot you dragged it to — but never leave it at the initial (0,0) bottom-left corner or
        // off a disconnected screen; fall back to centering.
        if isFloating { centerOnActiveScreen(panel) } else { positionNormalWindow(panel) }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        appModel.panelVisible = true  // home attaches its live terminal only while visible
        appModel.focusToken &+= 1 // tell the omnibox to (re)take focus on every show
    }

    func hide() {
        appModel.panelVisible = false // detaches the home terminal (the session keeps running)
        panel?.orderOut(nil)
    }

    /// Normal-window placement: reuse the saved drag position if it lands on a connected screen,
    /// otherwise center (so it never sticks at the default bottom-left origin).
    private func positionNormalWindow(_ panel: NSPanel) {
        if let origin = savedOrigin {
            var frame = panel.frame
            frame.origin = origin
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        centerOnActiveScreen(panel)
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

/// NSWindowDelegate that reports the panel's new size/position when the user resizes or moves it.
final class PanelResizeObserver: NSObject, NSWindowDelegate {
    private let onResize: (NSSize) -> Void
    private let onMove: (NSPoint) -> Void
    init(onResize: @escaping (NSSize) -> Void, onMove: @escaping (NSPoint) -> Void = { _ in }) {
        self.onResize = onResize
        self.onMove = onMove
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onResize(window.frame.size)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onMove(window.frame.origin)
    }
}
