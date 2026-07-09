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
                        ProjectRow(project: p)
                    }
                }
                HStack {
                    Button("Add projects…") { appModel.addProjects(dirs: ProjectPicker.pick()) }
                    if let msg = appModel.lastProjectAddMessage {
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Set an emoji to show it at the front of that project's session cards (⌃⌘Space for the emoji picker).")
                    .font(.caption).foregroundStyle(.secondary)
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

/// One project row in Settings — an emoji field (shown at the front of that project's cards),
/// the name/path, and a remove button.
private struct ProjectRow: View {
    let project: Project
    @Environment(AppModel.self) private var appModel
    @State private var emoji: String = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("🙂", text: $emoji)
                .frame(width: 40)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .onChange(of: emoji) { _, new in
                    let clipped = String(new.prefix(2))
                    if clipped != new { emoji = clipped }
                    appModel.projects?.setEmoji(rootPath: project.rootPath, clipped)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name).font(.system(size: 12, weight: .medium))
                Text(project.rootPath).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Button { appModel.projects?.forget(rootPath: project.rootPath) } label: {
                Image(systemName: "minus.circle")
            }.buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .onAppear { emoji = project.emoji ?? "" }
    }
}
