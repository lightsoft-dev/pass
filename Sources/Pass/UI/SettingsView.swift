import SwiftUI
import KeyboardShortcuts

/// Settings window (⌘,). Keyboard-first users rarely open it, but it's where the hotkey,
/// launch-at-login, and one-time setup (hooks, notifications) live.
struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var launchAtLogin = LoginItemService.isEnabled
    @State private var floating = true

    var body: some View {
        Form {
            Section("Shortcut") {
                KeyboardShortcuts.Recorder("Summon pass:", name: .summonPass)
            }

            Section("Projects") {
                let projects = appModel.projects?.projects ?? []
                if projects.isEmpty {
                    Text("No projects yet — add some to jump to them with @.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(projects) { p in
                        HStack(spacing: 8) {
                            Circle().fill(ProjectColor.color(for: p.rootPath)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.system(size: 12, weight: .medium))
                                Text(p.rootPath).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                            Spacer()
                            Button { appModel.projects?.forget(rootPath: p.rootPath) } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Add projects…") { appModel.addProjects(dirs: ProjectPicker.pick()) }
                    if let msg = appModel.lastProjectAddMessage {
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("General") {
                Toggle("Launch pass at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if !LoginItemService.setEnabled(on) { launchAtLogin = LoginItemService.isEnabled }
                    }
                Toggle("Float above other windows", isOn: $floating)
                    .onChange(of: floating) { _, on in appModel.setPanelFloating(on) }
                Text("Off: pass behaves like a normal window you can put beside your editor (⌘⇧F toggles).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Claude Code hooks") {
                LabeledContent("Status") {
                    Text(appModel.needsHookInstall ? "Not installed" : "Installed")
                        .foregroundStyle(appModel.needsHookInstall ? .orange : .green)
                }
                Button(appModel.needsHookInstall ? "Install hooks" : "Reinstall hooks") {
                    appModel.installHooks()
                }
                Text("Merges into ~/.claude/settings.json (backed up first, never overwrites your other hooks). New Claude sessions pick them up.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Notifications") {
                LabeledContent("Status") {
                    Text(appModel.notificationsBlocked ? "Blocked" : "On")
                        .foregroundStyle(appModel.notificationsBlocked ? .orange : .green)
                }
                if appModel.notificationsBlocked {
                    Button("Open System Settings…") { NotificationService.openSystemSettings() }
                }
            }

            Section("Hook listener") {
                LabeledContent("Address", value: "127.0.0.1:\(String(PassConfig.hookPort))")
                LabeledContent("Status") {
                    Text(appModel.hookServerFailed ? "Failed (port busy)" : "Listening")
                        .foregroundStyle(appModel.hookServerFailed ? .red : .green)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 520)
        .onAppear { floating = appModel.panelFloating }
    }
}
