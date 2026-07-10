import SwiftUI

/// Menu-bar glyph + badge. This is the notification-independent attention channel:
/// even if a banner is missed, the pending count is always visible here.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if appModel.setupProblem != nil {
            Image(systemName: "exclamationmark.triangle.fill")
        } else if appModel.pendingCount > 0 {
            // Glyph + count. SF Symbols has filled number badges up to 50.
            Label("\(appModel.pendingCount)", systemImage: "tray.full.fill")
        } else {
            Image(systemName: "tray")
        }
    }
}

/// The menu-bar dropdown. Keyboard users route through the panel; this is a mouse courtesy.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Button("Open pass") { appModel.summon() }
            .keyboardShortcut(.space, modifiers: .option)

        Menu("New session") {
            ForEach(AgentKind.launchable, id: \.self) { agent in
                Button("\(agent.glyph) \(agent.rawValue)…") { newSession(agent: agent) }
            }
        }
        Button("Add projects…") { appModel.addProjects(dirs: ProjectPicker.pick()) }
        Toggle("Float above windows", isOn: Binding(
            get: { appModel.panelFloating },
            set: { appModel.setPanelFloating($0) })
        ).keyboardShortcut("f", modifiers: [.command, .shift])

        if appModel.needsHookInstall {
            Divider()
            Text("⚠ Claude hooks not installed")
            Button("Install Claude hooks") { appModel.installHooks() }
        }
        if appModel.hookServerFailed {
            Divider()
            Text("⚠ Hook listener failed (port \(String(PassConfig.hookPort)) busy)")
        }

        if let problem = appModel.setupProblem {
            Divider()
            Text("⚠ \(problem)")
        }

        if appModel.notificationsBlocked {
            Divider()
            Text("⚠ Notifications are off")
            Button("Enable notifications…") { NotificationService.openSystemSettings() }
        }

        Divider()
        // SettingsLink is the reliable way to open the Settings scene (the old
        // showSettingsWindow: selector is flaky on recent macOS). SettingsView.onAppear then
        // hides the floating panel and activates, so Settings isn't stuck behind the panel.
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit pass") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func newSession(agent: AgentKind) {
        guard let dir = ProjectPicker.pickOne(
            prompt: "New session",
            message: "Choose a project directory to run \(agent.rawValue) in") else { return }
        appModel.createSession(projectDir: dir, agent: agent)
    }
}
