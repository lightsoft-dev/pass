import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import KeyboardShortcuts

/// Settings window (⌘,). Keyboard-first users rarely open it, but it's where the hotkey,
/// launch-at-login, and one-time setup (hooks, notifications) live.
struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var launchAtLogin = LoginItemService.isEnabled
    @State private var floating = true
    @State private var cliLinked = false
    @State private var advertiseOn = false
    @AppStorage("homeMode") private var homeModeRaw = HomeMode.stack.rawValue
    @AppStorage(SessionStore.restoreDefaultsKey) private var restoreSessions = true
    @AppStorage("backupOptimizeGit") private var backupOptimizeGit = true
    @AppStorage(TerminalTheme.storageKey) private var terminalThemeRaw = TerminalTheme.classic.rawValue
    @AppStorage(RemoteGatewayPreferenceKey.enabled) private var remoteAccessEnabled = false
    @AppStorage(RemoteGatewayPreferenceKey.relayURL) private var remoteRelayURL = ""
    @AppStorage(RemoteGatewayPreferenceKey.authorizationToken) private var remoteAuthorizationToken = ""

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

            Section("Backup") {
                Toggle("Optimize git repos (store remote URL only)", isOn: $backupOptimizeGit)
                HStack(spacing: 8) {
                    Button("Export backup…") { appModel.exportAllProjects(optimizeGit: backupOptimizeGit) }
                        .disabled(appModel.isExporting || (appModel.projects?.projects.isEmpty ?? true))
                    if appModel.isExporting { ProgressView().controlSize(.small) }
                    if let msg = appModel.lastExportMessage {
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Bundles every registered project + settings into one .tar.gz you can move to another Mac. Build artifacts (node_modules, .build, …) are excluded. With optimize on, git repos that have a remote are stored as URL + commit instead of copied.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Agent commands") {
                ForEach(AgentKind.launchable, id: \.self) { agent in
                    AgentCommandRow(agent: agent)
                }
                Text("The command pass types into a new session for each agent (e.g. add flags like --dangerously-skip-permissions). Leave a field at its default to keep the built-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Extensions") {
                let store = appModel.extensions
                let loaded = store?.loaded ?? []
                let errors = store?.loadErrors ?? []
                if loaded.isEmpty && errors.isEmpty {
                    Text("No extensions yet — one folder per extension in ~/.pass/extensions (manifest schema: docs/EXTENSIONS.md).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(loaded) { ext in
                    ExtensionRow(ext: ext)
                }
                ForEach(errors) { err in
                    Label("\(err.folder): \(err.message)", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(store?.bundledInstallable ?? [], id: \.self) { id in
                    HStack {
                        Text("\(id) (bundled example)").font(.system(size: 12))
                        Spacer()
                        Button("Install") { try? store?.installBundled(id: id) }
                            .controlSize(.small)
                    }
                }
                HStack {
                    Button("Reload") { store?.reload() }
                    Button("Open folder…") {
                        if let dir = store?.revealDirectory() { NSWorkspace.shared.open(dir) }
                    }
                }
                Text("Extensions run scripts with your user permissions — enable only what you trust. Commands appear in the quick command as >name.")
                    .font(.caption).foregroundStyle(.secondary)
                let log = appModel.extensionRuntime?.recentLog ?? []
                if !log.isEmpty {
                    DisclosureGroup("Recent activity (\(log.count))") {
                        ForEach(log.prefix(8)) { entry in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(entry.ok ? "✓" : "✕") \(entry.extensionId) — \(entry.summary)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(entry.ok ? Color.secondary : .orange)
                                if let detail = entry.detail {
                                    Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(2)
                                }
                            }
                        }
                    }
                    .font(.caption)
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
                Toggle("Restore sessions after a restart", isOn: $restoreSessions)
                Text("If tmux was restarted (e.g. after a reboot), recreates your sessions with the same project and agent on launch — Claude resumes with --continue.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(appModel.remotePublicAccessAvailable ? "Mobile access" : "Mobile access · developer preview") {
                if appModel.remotePublicAccessAvailable {
                    LabeledContent("Account", value: remoteAccountStatus)
                    if appModel.remoteUsesPublicCredentials {
                        LabeledContent("Desktop ID") {
                            Text(appModel.remoteDesktopID)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        LabeledContent("Connection") {
                            Text(remoteGatewayStatus.label)
                                .font(.caption)
                                .foregroundStyle(remoteGatewayStatus.color)
                                .multilineTextAlignment(.trailing)
                        }
                        Button("Create one-time pairing code", systemImage: "qrcode") {
                            appModel.createRemotePairing()
                        }
                        .disabled(remoteAccountBusy)
                        if let payload = appModel.remotePublicPairingPayload {
                            HStack(alignment: .top, spacing: 12) {
                                if let qrCode = remotePairingQRCode(for: payload) {
                                    Image(nsImage: qrCode)
                                        .resizable()
                                        .interpolation(.none)
                                        .frame(width: 112, height: 112)
                                        .accessibilityLabel("One-time pairing QR code")
                                }
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("One-time pairing")
                                        .font(.caption.weight(.semibold))
                                    Text("Scan with Pass Remote. This code expires after five minutes and can be used once.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Button("Copy pairing JSON") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(payload, forType: .string)
                                    }
                                }
                            }
                        }
                        Button("Sign out and revoke this Mac", role: .destructive) {
                            appModel.signOutFromRemoteAccess()
                        }
                        .disabled(remoteAccountBusy)
                    } else {
                        Button("Sign in", systemImage: "person.crop.circle") {
                            appModel.signInForRemoteAccess()
                        }
                        .disabled(remoteAccountBusy)
                    }
                    if remoteAccountBusy {
                        ProgressView().controlSize(.small)
                    }
                    if case .failed(let message) = appModel.remoteAccountState {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text("The Mac connects outbound to the relay. Account and desktop credentials are stored in Keychain; pairing codes are short-lived and device-scoped.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle("Enable outbound relay connection", isOn: $remoteAccessEnabled)
                    TextField("wss://relay.example/connect", text: $remoteRelayURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    SecureField("Shared relay token", text: $remoteAuthorizationToken)
                        .textFieldStyle(.roundedBorder)

                LabeledContent("Desktop ID") {
                    Text(appModel.remoteDesktopID)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Status") {
                    Text(remoteGatewayStatus.label)
                        .font(.caption)
                        .foregroundStyle(remoteGatewayStatus.color)
                        .multilineTextAlignment(.trailing)
                }
                Button("Apply connection settings") {
                    appModel.reconfigureRemoteGateway()
                }
                if let payload = developmentRemotePairingPayload {
                    HStack(alignment: .top, spacing: 12) {
                        if let qrCode = remotePairingQRCode(for: payload) {
                            Image(nsImage: qrCode)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: 112, height: 112)
                                .accessibilityLabel("Developer pairing QR code")
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Developer pairing")
                                .font(.caption.weight(.semibold))
                            Text("Scan this in Pass Remote, or copy the same JSON to the mobile pairing screen.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Copy pairing JSON") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(payload, forType: .string)
                            }
                        }
                    }
                } else {
                    Label(remotePairingUnavailableMessage, systemImage: "qrcode")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("The Mac only dials out; the local hook listener stays on 127.0.0.1. This development QR carries one reusable shared token. PASS_REMOTE_* environment values override these fields.")
                    .font(.caption).foregroundStyle(.secondary)
                }
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

            Section("Embedded browser · passcli") {
                LabeledContent("Agent CLI") {
                    Text(PassConfig.cliSymlinkPath)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
                LabeledContent("Status") {
                    Text(cliLinked ? "Linked" : "Not linked")
                        .foregroundStyle(cliLinked ? .green : .orange)
                }
                if !cliLinked {
                    Button("Link CLI") {
                        CLIInstaller.refreshSymlink()
                        cliLinked = CLIInstaller.isLinked
                    }
                }
                Toggle("Tell agents about passcli (SessionStart hook)", isOn: $advertiseOn)
                    .onChange(of: advertiseOn) { _, on in
                        if on { ClaudeHooksInstaller.installAdvertise() }
                        else { ClaudeHooksInstaller.removeAdvertise() }
                        advertiseOn = ClaudeHooksInstaller.isAdvertiseInstalled()
                    }
                Text("Agents open pages beside their terminal (passcli browser open) and can read them back (screenshot/read). Note: whatever the embedded browser shows is readable by that session's agent.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear browser website data") {
                    Task { await WebViewPool.clearWebsiteData() }
                }
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
            cliLinked = CLIInstaller.isLinked
            advertiseOn = ClaudeHooksInstaller.isAdvertiseInstalled()
            // The summon panel floats above normal windows, so it would sit on top of Settings.
            // Hide it and pull the app forward so Settings is actually visible/focused.
            appModel.hidePanel()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var remoteGatewayStatus: (label: String, color: Color) {
        switch appModel.remoteGatewayState {
        case .disabled:
            return ("Disabled", .secondary)
        case .stopped:
            return ("Stopped", .secondary)
        case .connecting:
            return ("Connecting…", .orange)
        case .connected:
            return ("Connected", .green)
        case .waitingToReconnect(let attempt, let lastError):
            return ("Retrying #\(attempt): \(lastError)", .orange)
        case .failedConfiguration(let message):
            return (message, .red)
        }
    }

    private var remoteAccountBusy: Bool {
        switch appModel.remoteAccountState {
        case .signingIn, .creatingPairing, .signingOut: true
        default: false
        }
    }

    private var remoteAccountStatus: String {
        switch appModel.remoteAccountState {
        case .unavailable: "Unavailable"
        case .signedOut: "Signed out"
        case .signingIn: "Signing in..."
        case .registered: "Signed in"
        case .creatingPairing: "Creating pairing code..."
        case .signingOut: "Signing out..."
        case .failed: appModel.remoteUsesPublicCredentials ? "Signed in" : "Sign in required"
        }
    }

    private var developmentRemotePairingPayload: String? {
        let configuration = RemoteGatewayConfiguration.load()
        let token = configuration.authorizationToken?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { return nil }
        guard let websocketURL = try? configuration.validatedRelayURL(),
              var components = URLComponents(url: websocketURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = websocketURL.scheme?.lowercased() == "wss" ? "https" : "http"
        guard let relayURL = components.url?.absoluteString else { return nil }

        let payload = DeveloperPairingPayload(
            relayURL: relayURL,
            desktopID: configuration.desktopID,
            authorizationToken: token
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private var remotePairingUnavailableMessage: String {
        let configuration = RemoteGatewayConfiguration.load()
        let token = configuration.authorizationToken?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasValidRelayURL = (try? configuration.validatedRelayURL()) != nil

        switch (hasValidRelayURL, token.isEmpty) {
        case (false, true):
            return "Enter a valid relay URL and shared token to generate the pairing QR code."
        case (false, false):
            return "Enter a valid relay URL to generate the pairing QR code."
        case (true, true):
            return "Enter the shared relay token to generate the pairing QR code."
        case (true, false):
            return "The pairing QR code could not be generated."
        }
    }

    private func remotePairingQRCode(for payload: String) -> NSImage? {
        guard let message = payload.data(using: .utf8), message.count <= 2_048 else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = message
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: 8, y: 8)
        ) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

struct DeveloperPairingPayload: Encodable {
    let v = RemoteProtocolVersion.current
    let relayURL: String
    let desktopID: String
    let authorizationToken: String

    private enum CodingKeys: String, CodingKey {
        case v
        case relayURL = "relayUrl"
        case desktopID = "desktopId"
        case authorizationToken
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

/// One extension row — name/version/description, its declared permissions, and the enable
/// toggle. A broken manifest shows its problems instead and can't be enabled (the runtime
/// only ever executes enabled AND valid extensions).
private struct ExtensionRow: View {
    let ext: ExtensionStore.Loaded
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ext.manifest.name).font(.system(size: 12, weight: .medium))
                    if let v = ext.manifest.version {
                        Text(v).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                if let desc = ext.manifest.description, !desc.isEmpty {
                    Text(desc).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let perms = ext.manifest.permissions, !perms.isEmpty {
                    Text("permissions: " + perms.sorted().joined(separator: ", "))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                }
                ForEach(ext.problems, id: \.self) { p in
                    Text("⚠ \(p)").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            Spacer()
            // Binding straight into the store — a @State mirror goes stale when SwiftUI
            // reuses this row for a different extension after a Reload reorders the list.
            Toggle("", isOn: Binding(
                get: { appModel.extensions?.isEnabled(ext.id) ?? false },
                set: { appModel.extensions?.setEnabled(ext.id, $0) }
            ))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            .disabled(!ext.isValid)
        }
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
