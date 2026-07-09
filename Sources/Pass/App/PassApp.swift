import SwiftUI

@main
struct PassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(appDelegate.appModel)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.appModel)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(appDelegate.appModel)
        }
    }
}
