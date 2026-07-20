import SwiftUI

/// The panel's top system bar for installed extensions. It exposes only enabled + valid
/// manifests, and execution still travels through ExtensionRuntime's permission enforcement.
struct ExtensionLauncherBar: View {
    let contextSession: Session?

    @Environment(AppModel.self) private var appModel
    @State private var running: Set<String> = []
    @State private var error: String?

    private var extensions: [ExtensionStore.Loaded] {
        appModel.extensions?.activeExtensions ?? []
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .help("Enabled extensions")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(extensions) { ext in
                        launcher(for: ext)
                    }
                }
            }

            if let error {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(error)
                Button { self.error = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private func launcher(for ext: ExtensionStore.Loaded) -> some View {
        let commands = commands(for: ext.id)
        if commands.count == 1, let command = commands.first {
            Button { run(command) } label: { chip(ext.manifest.name) }
                .buttonStyle(.plain)
                .disabled(!canRun(command) || running.contains(command.id))
                .help(commandHelp(command))
        } else if !commands.isEmpty {
            Menu {
                ForEach(commands) { command in
                    Button(command.command.title) { run(command) }
                        .disabled(!canRun(command) || running.contains(command.id))
                }
            } label: {
                chip(ext.manifest.name, showsDisclosure: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("\(ext.manifest.name) commands")
        } else {
            chip(ext.manifest.name)
                .opacity(0.65)
                .help("Enabled event extension — no manual commands")
        }
    }

    private func chip(_ name: String, showsDisclosure: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(name).lineLimit(1)
            if showsDisclosure {
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .contentShape(Capsule())
    }

    private func commands(for extensionId: String) -> [ExtensionStore.PaletteCommand] {
        (appModel.extensions?.paletteCommands ?? [])
            .filter { $0.extensionId == extensionId }
    }

    private func canRun(_ command: ExtensionStore.PaletteCommand) -> Bool {
        command.command.contextKind == "global" || contextSession != nil
    }

    private func commandHelp(_ command: ExtensionStore.PaletteCommand) -> String {
        if canRun(command) { return command.command.title }
        return "\(command.command.title) — select a session first"
    }

    private func run(_ command: ExtensionStore.PaletteCommand) {
        guard canRun(command) else { return }
        error = nil
        running.insert(command.id)
        let session = command.command.contextKind == "global" ? nil : contextSession
        Task {
            let failure = await appModel.extensionRuntime?.run(command, session: session)
            running.remove(command.id)
            if let failure { error = "\(command.token): \(failure)" }
        }
    }
}
