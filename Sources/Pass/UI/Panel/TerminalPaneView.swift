import SwiftUI
import SwiftTerm
import AppKit

/// Owns a real terminal attached to a tmux session. Keystrokes go straight into the session
/// (Claude), color and resize are handled natively by the emulator. Lives outside the SwiftUI
/// view graph so it isn't recreated on redraws.
@MainActor
final class TerminalController {
    let terminalView: LocalProcessTerminalView
    private(set) var alive = true

    init(session: String) {
        terminalView = LocalProcessTerminalView(frame: .zero)
        var env = Terminal.getEnvironmentVariables() // TERM, COLORTERM, LANG… but NOT PATH
        env.append("PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(NSHomeDirectory())/.local/bin")
        let tmux = Shell.resolveViaLoginShell("tmux") ?? "/opt/homebrew/bin/tmux"
        // Attach to the existing session; -A would create if missing, but pass already made it.
        terminalView.startProcess(executable: tmux,
                                  args: ["attach-session", "-t", session],
                                  environment: env)
        Log.ui.info("terminal attached to \(session, privacy: .public)")
    }

    /// Detach the tmux client (the session keeps running) and tear down the PTY.
    func detach() {
        guard alive else { return }
        alive = false
        terminalView.terminate()
    }

    /// Make the terminal the key window's first responder so keystrokes reach the session.
    /// Retries briefly until the view is in a window.
    func focus(attempt: Int = 0) {
        guard alive, attempt < 20 else { return }
        guard let window = terminalView.window else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.focus(attempt: attempt + 1) }
            return
        }
        let ok = window.makeFirstResponder(terminalView)
        Log.ui.debug("terminal focus attempt \(attempt) firstResponder=\(ok)")
        if !ok {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.focus(attempt: attempt + 1) }
        }
    }
}

/// Embeds the terminal view. `makeNSView` returns the controller's long-lived view; we never
/// recreate it in `updateNSView`.
struct TerminalPaneView: NSViewRepresentable {
    let controller: TerminalController

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        controller.terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
