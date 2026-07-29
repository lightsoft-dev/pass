import AppKit
import Observation
import SwiftTerm
import SwiftUI

enum RecentClipboardPolicy {
    static let maximumAge: TimeInterval = 5 * 60

    static func isRecent(text: String?, changedAt: Date?, now: Date) -> Bool {
        guard let text, !text.isEmpty, let changedAt else { return false }
        let age = now.timeIntervalSince(changedAt)
        return age >= 0 && age <= maximumAge
    }
}

/// NSPasteboard exposes a change counter but no copy timestamp. Observe changes while Pass is
/// running and treat a text value as recent for five minutes after Pass first sees that change.
@MainActor
@Observable
final class ClipboardRecencyMonitor {
    private(set) var currentText: String?
    private(set) var changedAt: Date?
    private(set) var now = Date()

    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private var observedChangeCount: Int
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        observedChangeCount = pasteboard.changeCount
        currentText = pasteboard.string(forType: .string)
        changedAt = currentText == nil ? nil : now
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    deinit {
        pollTask?.cancel()
    }

    var hasRecentText: Bool {
        RecentClipboardPolicy.isRecent(text: currentText, changedAt: changedAt, now: now)
    }

    func refresh(now: Date = Date()) {
        self.now = now
        let changeCount = pasteboard.changeCount
        guard changeCount != observedChangeCount else { return }
        observedChangeCount = changeCount
        currentText = pasteboard.string(forType: .string)
        changedAt = currentText == nil ? nil : now
    }
}

enum MiniTerminalVisibilityPolicy {
    static func shouldShow(
        panelVisible: Bool,
        focusedSessionName: String?,
        terminalSessionName: String
    ) -> Bool {
        panelVisible && focusedSessionName == terminalSessionName
    }
}

/// Owns one persistent mini shell per session. A shell stays alive while hidden, but its window
/// follows the Pass panel and is visible only while that session is the focused session.
@MainActor
final class MiniTerminalManager {
    private var controllers: [String: MiniTerminalWindowController] = [:]
    private let clipboard: ClipboardRecencyMonitor

    init(clipboard: ClipboardRecencyMonitor) {
        self.clipboard = clipboard
    }

    func open(for session: Session, attachedTo parentWindow: NSWindow?) {
        let key = session.name
        controllers.values
            .filter { $0.sessionName != session.name }
            .forEach { $0.hide() }
        if let existing = controllers[key] {
            existing.show(attachedTo: parentWindow, activate: true)
            return
        }
        let controller = MiniTerminalWindowController(
            session: session,
            clipboard: clipboard
        ) { [weak self] in
            self?.controllers.removeValue(forKey: key)
        }
        controllers[key] = controller
        controller.show(attachedTo: parentWindow, activate: true)
    }

    func synchronize(
        panelVisible: Bool,
        focusedSessionName: String?,
        parentWindow: NSWindow?
    ) {
        for controller in controllers.values {
            if MiniTerminalVisibilityPolicy.shouldShow(
                panelVisible: panelVisible,
                focusedSessionName: focusedSessionName,
                terminalSessionName: controller.sessionName
            ) {
                controller.show(attachedTo: parentWindow, activate: false)
            } else {
                controller.hide()
            }
        }
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
    let sessionName: String
    private let terminalView: IMETerminalView
    private let window: MiniTerminalPanel
    private let onClose: () -> Void
    private var themeObserver: (any NSObjectProtocol)?
    private var closed = false

    init(
        session: Session,
        clipboard: ClipboardRecencyMonitor,
        onClose: @escaping () -> Void
    ) {
        self.session = session
        sessionName = session.name
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
        window.level = .normal
        window.minSize = NSSize(width: 460, height: 280)
        window.collectionBehavior = [.fullScreenAuxiliary]

        super.init()

        terminalView.processDelegate = self
        window.delegate = self
        window.contentView = NSHostingView(rootView: MiniTerminalContent(
            session: session,
            terminalView: terminalView,
            clipboard: clipboard,
            pasteClipboard: { [weak terminalView, weak window] in
                guard let terminalView, let window else { return }
                window.makeFirstResponder(terminalView)
                _ = NSApp.sendAction(#selector(NSText.paste(_:)), to: terminalView, from: window)
            }
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

    func show(attachedTo parentWindow: NSWindow?, activate: Bool) {
        guard !closed, let parentWindow, parentWindow.isVisible else {
            hide()
            return
        }
        if window.parent !== parentWindow {
            window.parent?.removeChildWindow(window)
            parentWindow.addChildWindow(window, ordered: .above)
        }
        if !window.isVisible {
            position(relativeTo: parentWindow)
            window.orderFront(nil)
        }
        guard activate else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        focus()
    }

    func hide() {
        guard !closed else { return }
        window.orderOut(nil)
    }

    func close() {
        guard !closed else { return }
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        window.parent?.removeChildWindow(window)
        terminalView.terminate()
        onClose()
    }

    private func position(relativeTo parentWindow: NSWindow) {
        let parent = parentWindow.frame
        let size = window.frame.size
        let screen = parentWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parent
        var origin = NSPoint(
            x: parent.maxX + 12,
            y: parent.maxY - size.height
        )
        if origin.x + size.width > screen.maxX {
            origin.x = max(screen.minX, parent.minX - size.width - 12)
        }
        origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        window.setFrameOrigin(origin)
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
    let clipboard: ClipboardRecencyMonitor
    let pasteClipboard: () -> Void

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
                if clipboard.hasRecentText {
                    Button(action: pasteClipboard) {
                        Label("값 붙여넣기", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("최근 5분 내 복사한 값을 터미널에 붙여넣기")
                }
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
        Button { appModel.openMiniTerminal(for: session) } label: {
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
