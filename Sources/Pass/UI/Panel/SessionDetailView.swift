import SwiftUI

/// Interactive terminal attached to the session. Keystrokes go straight into the session
/// (Claude) — including Enter, arrows, ctrl-keys, and permission answers. `⌘[` steps back,
/// `⌘⏎` opens a full terminal in Ghostty.
struct SessionDetailView: View {
    let session: Session
    let onBack: () -> Void

    @Environment(AppModel.self) private var appModel
    @State private var terminal: TerminalController?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            terminalBody
            Divider()
            footer
        }
        .task(id: session.name) {
            let controller = TerminalController(session: session.name)
            terminal = controller
            appModel.focusedSessionName = session.name // this workspace is on screen
            await controller.start()
            appModel.reconcileOnOpen(session)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { controller.focus() }
            defer { controller.detach(); terminal = nil }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(2)) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Back to list (⌘[ or ⌘W)")
                Circle().fill(ProjectColor.color(for: session.projectRoot)).frame(width: 8, height: 8)
                Text(session.agent.glyph).foregroundStyle(.secondary)
                Text(session.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                attentionBadge
                Button { appModel.attach(session) } label: {
                    Image(systemName: "macwindow.on.rectangle").foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Open in Ghostty (⌘⏎)")
            }
            Text("\(session.cwd)   ·   tmux: \(session.name)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder
    private var attentionBadge: some View {
        switch session.attention {
        case .working: Text("● working").font(.system(size: 11)).foregroundStyle(.blue)
        case .idle: Text("○ idle").font(.system(size: 11)).foregroundStyle(.secondary)
        case .pending(let a):
            Text(a.kind == .decision ? "⚡ needs decision" : a.kind == .input ? "✎ needs input" : "✓ finished")
                .font(.system(size: 11)).foregroundStyle(.orange)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("keys go to the session").foregroundStyle(.tertiary)
            Spacer()
            Text("⌘B  browser").foregroundStyle(.tertiary)
            Text("⌘[ or ⌘W  back to list").foregroundStyle(.secondary)
            Text("⌘⏎  open in Ghostty").foregroundStyle(.tertiary)
        }
        .font(.system(size: 10))
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    @ViewBuilder
    private var terminalBody: some View {
        if let terminal {
            SessionWorkspaceView(session: session) {
                TerminalPaneView(controller: terminal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
