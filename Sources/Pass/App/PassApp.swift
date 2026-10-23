import SwiftUI

@main
struct PassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        PassFont.registerBundledFonts()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .font(PassFont.ui(size: 12))
                .environment(appDelegate.appModel)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.appModel)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .font(PassFont.ui(size: 12))
                .environment(appDelegate.appModel)
        }
    }
}
