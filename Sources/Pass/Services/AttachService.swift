import AppKit
import Foundation

/// Opens a real terminal attached to a tmux session — the "I need real hands" escape hatch.
/// Prefers Ghostty, falls back to Terminal.app. Both use AppleScript (needs
/// NSAppleEventsUsageDescription + a one-time Automation permission grant).
enum AttachService {
    private static let tmuxPath = Shell.resolveViaLoginShell("tmux") ?? "/opt/homebrew/bin/tmux"

    static func attach(session: String) {
        let cmd = "\(tmuxPath) attach-session -t \(session)"
        openCommand(cmd)
    }

    /// Open a trusted command in an interactive terminal. Account/device authorization flows
    /// need a visible prompt that can hand off to the browser and accept user input.
    static func openCommand(_ command: String) {
        let cmd = appleScriptEscaped(command)
        if ghosttyInstalled(), runAppleScript(ghosttyScript(cmd)) { return }
        _ = runAppleScript(terminalScript(cmd))
    }

    private static func ghosttyInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil
    }

    private static func ghosttyScript(_ cmd: String) -> String {
        """
        tell application "Ghostty"
          activate
          set cfg to new surface configuration
          set command of cfg to "\(cmd)"
          new window with configuration cfg
        end tell
        """
    }

    private static func terminalScript(_ cmd: String) -> String {
        """
        tell application "Terminal"
          activate
          do script "\(cmd)"
        end tell
        """
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        script?.executeAndReturnError(&error)
        if let error {
            Log.app.error("attach AppleScript failed: \(error, privacy: .public)")
            return false
        }
        return true
    }
}
