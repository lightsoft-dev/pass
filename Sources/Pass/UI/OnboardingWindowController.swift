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

        let model = OnboardingModel(appModel: appModel) { [weak window] in
            window?.close()
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
        onboardingModel.restart()
        window.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
