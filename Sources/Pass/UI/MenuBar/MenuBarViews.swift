import SwiftUI

/// Menu-bar glyph + badge. This is the notification-independent attention channel:
/// even if a banner is missed, the pending count is always visible here.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if appModel.setupProblem != nil {
            Image(systemName: "exclamationmark.triangle.fill")
        } else if appModel.pendingCount > 0 {
            // App-icon glyph + pending count.
            Label { Text("\(appModel.pendingCount)") } icon: { Image(nsImage: MenuBarIcon.image) }
        } else {
            Image(nsImage: MenuBarIcon.image)
        }
    }
}

/// The menu-bar dropdown. Keyboard users route through the panel; this is a mouse courtesy.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage("backupOptimizeGit") private var backupOptimizeGit = true

    var body: some View {
        Button("Open pass") { appModel.summon() }
            .keyboardShortcut(.space, modifiers: .option)

        Menu("New session") {
            ForEach(AgentKind.launchable, id: \.self) { agent in
                Button("\(agent.glyph) \(agent.rawValue)…") { newSession(agent: agent) }
            }
        }
        Button("Specs…") { appModel.showSpecs() }
        Button("Add projects…") { appModel.addProjects(dirs: ProjectPicker.pick()) }
        Button("Back up all projects…") { appModel.exportAllProjects(optimizeGit: backupOptimizeGit) }
            .disabled(appModel.isExporting)
        Button("Device mirror…") { appModel.showDeviceMirror() }

        if appModel.extensions?.activeExtensions.isEmpty == false {
            Menu("Extensions") {
                ForEach(appModel.extensions?.activeExtensions ?? []) { ext in
                    let commands = commands(for: ext.id)
                    Menu(ext.manifest.name) {
                        if commands.isEmpty {
                            Button("Enabled · event rules only") {}
                                .disabled(true)
                        } else {
                            ForEach(commands) { command in
                                Button(command.command.title) { run(command) }
                                    .disabled(!canRun(command))
                            }
                        }
                    }
                }
            }
        }
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

    private func commands(for extensionId: String) -> [ExtensionStore.PaletteCommand] {
        (appModel.extensions?.paletteCommands ?? []).filter { $0.extensionId == extensionId }
    }

    private var contextSession: Session? {
        guard let name = appModel.focusedSessionName else { return nil }
        return appModel.sessions?.session(named: name)
    }

    private func canRun(_ command: ExtensionStore.PaletteCommand) -> Bool {
        command.command.contextKind == "global" || contextSession != nil
    }

    private func run(_ command: ExtensionStore.PaletteCommand) {
        let session = command.command.contextKind == "global" ? nil : contextSession
        Task { _ = await appModel.extensionRuntime?.run(command, session: session) }
    }
}
