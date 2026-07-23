import AppKit
import SwiftTerm
import SwiftUI

/// Owns one persistent mini shell per working directory. Reopening the same project raises its
/// existing shell, preserving command history, environment changes, and running processes.
@MainActor
final class MiniTerminalManager {
    private var controllers: [String: MiniTerminalWindowController] = [:]

    func open(for session: Session) {
        let key = session.cwd
        if let existing = controllers[key] {
            existing.show()
            return
        }
        let controller = MiniTerminalWindowController(session: session) { [weak self] in
            self?.controllers.removeValue(forKey: key)
        }
        controllers[key] = controller
        controller.show()
    }

    func closeAll() {
        let open = Array(controllers.values)
        controllers.removeAll()
        open.forEach { $0.close() }
    }
}

/// A compact operator window: fixed project identity rail above a real local PTY.
@MainActor
private final class MiniTerminalWindowController: NSObject, NSWindowDelegate,
                                                   LocalProcessTerminalViewDelegate {
    private let session: Session
    private let terminalView: IMETerminalView
    private let window: MiniTerminalPanel
    private let onClose: () -> Void
    private var themeObserver: (any NSObjectProtocol)?
    private var closed = false

    init(session: Session, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
        IMETerminalView.installEventBridges()
        terminalView = IMETerminalView(frame: .zero)
        TerminalTheme.current.apply(to: terminalView)

        window = MiniTerminalPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 390),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Mini Terminal — \(session.displayName)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.minSize = NSSize(width: 460, height: 280)
        window.collectionBehavior = [.fullScreenAuxiliary]

        super.init()

        terminalView.processDelegate = self
        window.delegate = self
        window.contentView = NSHostingView(rootView: MiniTerminalContent(
            session: session,
            terminalView: terminalView
        ))
        themeObserver = NotificationCenter.default.addObserver(
            forName: .passTerminalThemeChanged,
            object: nil,
            queue: .main
        ) { [weak terminalView] _ in
            MainActor.assumeIsolated {
                guard let terminalView else { return }
                TerminalTheme.current.apply(to: terminalView)
            }
        }
        startShell()
    }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    func show() {
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        focus()
    }

    func close() {
        guard !closed else { return }
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        terminalView.terminate()
        onClose()
    }

    private func startShell() {
        let environmentShell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        let shell = FileManager.default.isExecutableFile(atPath: environmentShell)
            ? environmentShell
            : "/bin/zsh"
        var environment = Terminal.getEnvironmentVariables()
            .filter { !$0.hasPrefix("PATH=") && !$0.hasPrefix("PASS_PROJECT_ROOT=") }
        environment.append(
            "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(NSHomeDirectory())/.local/bin"
        )
        environment.append("PASS_PROJECT_ROOT=\(session.projectRoot)")
        environment.append("PASS_SESSION_NAME=\(session.name)")
        terminalView.startProcess(
            executable: shell,
            args: ["-l"],
            environment: environment,
            execName: "-\(URL(fileURLWithPath: shell).lastPathComponent)",
            currentDirectory: session.cwd
        )
    }

    private func focus(attempt: Int = 0) {
        guard !closed, attempt < 20 else { return }
        guard terminalView.window != nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.focus(attempt: attempt + 1)
            }
            return
        }
        if !window.makeFirstResponder(terminalView) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.focus(attempt: attempt + 1)
            }
        }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in self?.close() }
    }
}

enum MiniTerminalEditingShortcut {
    static func selector(for event: NSEvent) -> Selector? {
        guard event.modifierFlags.contains(.command) else { return nil }

        // Match the physical key as well as the character. With a non-Latin input source,
        // charactersIgnoringModifiers is the mapped glyph rather than "c", "v", or "a".
        let character = event.charactersIgnoringModifiers?.lowercased()
        switch event.keyCode {
        case 8: return #selector(NSText.copy(_:))
        case 9: return #selector(NSText.paste(_:))
        case 0: return #selector(NSText.selectAll(_:))
        default:
            if character == "c" { return #selector(NSText.copy(_:)) }
            if character == "v" { return #selector(NSText.paste(_:)) }
            if character == "a" { return #selector(NSText.selectAll(_:)) }
            return nil
        }
    }
}

private final class MiniTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Pass is an accessory app, so the normal Edit-menu key equivalents are not reliably
    /// dispatched for this standalone panel. Send them through the responder chain explicitly;
    /// SwiftTerm implements copy, paste, and selectAll on its terminal view.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let selector = MiniTerminalEditingShortcut.selector(for: event),
           NSApp.sendAction(selector, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct MiniTerminalContent: View {
    let session: Session
    let terminalView: LocalProcessTerminalView

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Circle()
                    .fill(ProjectColor.color(for: session.projectRoot))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName)
                        .font(.custom("New York", size: 12).weight(.semibold))
                        .lineLimit(1)
                    Text(session.cwd)
                        .font(.custom("SF Mono", size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Label("PROJECT SHELL", systemImage: "terminal.fill")
                    .font(.custom("SF Mono", size: 8).weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 76)
            .padding(.trailing, 12)
            .padding(.top, 9)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)

            Divider()

            MiniTerminalView(terminalView: terminalView)
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .background(Color(nsColor: TerminalTheme.current.nsBackground))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MiniTerminalView: NSViewRepresentable {
    let terminalView: LocalProcessTerminalView

    func makeNSView(context: Context) -> LocalProcessTerminalView { terminalView }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}

/// Reusable affordance for opening the selected session's project shell.
struct MiniTerminalButton: View {
    let session: Session
    var showLabel = false
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Button { appModel.miniTerminals.open(for: session) } label: {
            if showLabel {
                Label("Mini Terminal", systemImage: "terminal.fill")
            } else {
                Image(systemName: "terminal.fill")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .font(.system(size: 11))
        .help("Open a project shell in \(session.cwd)")
        .accessibilityLabel("Open Mini Terminal")
    }
}
