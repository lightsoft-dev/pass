import SwiftUI
import AppKit
import KeyboardShortcuts

/// Settings window (⌘,). Keyboard-first users rarely open it, but it's where the hotkey,
/// launch-at-login, and one-time setup (hooks, notifications) live.
struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var launchAtLogin = LoginItemService.isEnabled
    @State private var floating = true
    @AppStorage("homeMode") private var homeModeRaw = HomeMode.stack.rawValue
    @AppStorage(TerminalTheme.storageKey) private var terminalThemeRaw = TerminalTheme.classic.rawValue

    var body: some View {
        Form {
            Section("Shortcut") {
                KeyboardShortcuts.Recorder("Summon pass:", name: .summonPass)
            }

            Section("Home") {
                Picker("Layout", selection: $homeModeRaw) {
                    ForEach(HomeMode.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text("Card stack: the focused session shown large with its own input, others small. Compact list: uniform rows with one input at the bottom.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Terminal theme", selection: $terminalThemeRaw) {
                    ForEach(TerminalTheme.allCases, id: \.rawValue) { theme in
                        Text(theme.label).tag(theme.rawValue)
                    }
                }
                .onChange(of: terminalThemeRaw) { _, _ in
                    // Every live terminal (home pool + detail) restyles immediately.
                    NotificationCenter.default.post(name: .passTerminalThemeChanged, object: nil)
                }
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
                Text("Tip: click the dot at the front of a session card to give its project an emoji.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Agent commands") {
                ForEach(AgentKind.launchable, id: \.self) { agent in
                    AgentCommandRow(agent: agent)
                }
                Text("The command pass types into a new session for each agent (e.g. add flags like --dangerously-skip-permissions). Leave a field at its default to keep the built-in.")
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
        .onAppear {
            floating = appModel.panelFloating
            // The summon panel floats above normal windows, so it would sit on top of Settings.
            // Hide it and pull the app forward so Settings is actually visible/focused.
            appModel.hidePanel()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// One agent's launch command — the glyph, the agent name, and an editable command field.
/// Blank/default clears the override (see `LaunchCommands`).
private struct AgentCommandRow: View {
    let agent: AgentKind
    @State private var command: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Text(agent.glyph).frame(width: 16)
            Text(agent.rawValue).font(.system(size: 12, weight: .medium)).frame(width: 56, alignment: .leading)
            TextField(agent.defaultLaunchCommand ?? "command", text: $command)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onChange(of: command) { _, new in LaunchCommands.setCommand(new, for: agent) }
        }
        .onAppear { command = LaunchCommands.editableCommand(for: agent) }
    }
}

/// One project row in Settings — name/path and a remove button. (Emoji is set inline from the
/// session card's leading dot, not here.)
private struct ProjectRow: View {
    let project: Project
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(spacing: 8) {
            SessionBadge(emoji: project.emoji, projectRoot: project.rootPath, size: 15).frame(width: 20)
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
    }
}
