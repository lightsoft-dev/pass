import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private var onboardingModel: OnboardingModel!

    init(appModel: AppModel) {
        super.init(window: nil)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Pass"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self

        let model = OnboardingModel(appModel: appModel) { [weak self] in
            self?.dismissWindow()
        }
        onboardingModel = model
        window.contentView = NSHostingView(rootView: OnboardingView(model: model))
        self.window = window
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        // Already up (launch check + menu bar + Settings can all ask): just raise it. Restarting
        // here would yank a walkthrough in progress back to the welcome step.
        guard !window.isVisible else {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        onboardingModel.restart()
        window.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Take the window off screen for good. `orderOut` first: `close()` alone can be deferred
    /// when it runs from the window's own event handling (the "Open Pass" button lives in this
    /// window's SwiftUI content), which leaves the walkthrough sitting next to the panel that
    /// Open Pass just summoned. The window is reused (`isReleasedWhenClosed = false`), so
    /// closing it only tears down the on-screen state, not the controller.
    func dismissWindow() {
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
        window.close()
    }
}
