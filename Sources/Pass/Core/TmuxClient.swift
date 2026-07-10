import Foundation

/// Raw session facts read from tmux, before git identity is resolved.
struct RawSession: Sendable {
    var name: String
    var created: Date
    var attached: Bool
    var activity: Date
    var projectRootOption: String?  // @pass_project_root
    var agentOption: String?        // @pass_agent
    var cwd: String                 // active pane's current path
    var paneCommand: String         // active pane's foreground command
    var paneInMode: Bool
}

/// The ONLY thing that spawns tmux. Resolves the binary once; every call uses the absolute
/// path. Uses the default socket so `tmux attach` from any terminal just works.
actor TmuxClient {
    static let shared = TmuxClient()

    private let tmuxPath: String?

    init() {
        self.tmuxPath = Shell.resolveViaLoginShell("tmux")
        if let tmuxPath { Log.tmux.info("tmux at \(tmuxPath, privacy: .public)") }
        else { Log.tmux.error("tmux not found on PATH") }
    }

    var isAvailable: Bool { tmuxPath != nil }

    private let fieldSep = "\t" // tmux escapes non-printable control bytes in -F output, so
                                // a real separator (tab) is required. Paths with tabs are pathological.

    /// Run tmux off the actor executor (Process.waitUntilExit blocks).
    @discardableResult
    func run(_ args: [String]) async -> ProcResult {
        guard let tmuxPath else {
            return ProcResult(stdout: "", stderr: "tmux not found", code: 127)
        }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Shell.run(tmuxPath, args))
            }
        }
    }

    // MARK: Reconcile

    /// List all sessions with their active pane details. Empty when no tmux server is running.
    func listSessions() async -> [RawSession] {
        let s = fieldSep
        let sess = await run([
            "list-sessions", "-F",
            ["#{session_name}", "#{session_created}", "#{session_attached}",
             "#{session_activity}", "#{@pass_project_root}", "#{@pass_agent}"].joined(separator: s),
        ])
        // No server / no sessions → treat as empty, not an error.
        guard sess.ok else { return [] }

        // Active-pane details, one query for all sessions.
        let panes = await run([
            "list-panes", "-a", "-F",
            ["#{session_name}", "#{pane_active}", "#{pane_current_path}",
             "#{pane_current_command}", "#{pane_in_mode}"].joined(separator: s),
        ])
        var paneBySession: [String: (cwd: String, cmd: String, inMode: Bool)] = [:]
        for line in panes.stdout.split(separator: "\n") {
            let f = line.components(separatedBy: s)
            guard f.count >= 5, f[1] == "1" else { continue } // active pane only
            paneBySession[f[0]] = (f[2], f[3], f[4] == "1")
        }

        var result: [RawSession] = []
        for line in sess.stdout.split(separator: "\n") {
            let f = line.components(separatedBy: s)
            guard f.count >= 6 else { continue }
            let pane = paneBySession[f[0]]
            result.append(RawSession(
                name: f[0],
                created: epoch(f[1]),
                attached: f[2] == "1",
                activity: epoch(f[3]),
                projectRootOption: f[4].isEmpty ? nil : f[4],
                agentOption: f[5].isEmpty ? nil : f[5],
                cwd: pane?.cwd ?? "",
                paneCommand: pane?.cmd ?? "",
                paneInMode: pane?.inMode ?? false
            ))
        }
        return result
    }

    private func epoch(_ s: String) -> Date {
        Date(timeIntervalSince1970: Double(s) ?? 0)
    }

    // MARK: Lifecycle

    func hasSession(_ name: String) async -> Bool {
        await run(["has-session", "-t", name]).ok
    }

    /// Create a detached session running a shell in `cwd`, tag it, then launch the agent.
    /// The agent is launched via send-keys (not as the session command) so a post-mortem
    /// shell survives when the agent exits.
    func newSession(name: String, cwd: String, projectRoot: String, agent: AgentKind,
                    launchCommand: String?) async {
        await run([
            "new-session", "-d", "-s", name, "-c", cwd, "-x", "220", "-y", "50",
            "-e", "\(PassConfig.sessionEnvVar)=\(name)",
        ])
        await run(["set-option", "-t", name, PassConfig.optProjectRoot, projectRoot])
        await run(["set-option", "-t", name, PassConfig.optAgent, agent.rawValue])
        if let cmd = launchCommand, !cmd.isEmpty {
            await run(["send-keys", "-t", name, cmd, "Enter"])
        }
        Log.tmux.info("created session \(name, privacy: .public) agent=\(agent.rawValue) cwd=\(cwd, privacy: .public)")
    }

    func killSession(_ name: String) async {
        await run(["kill-session", "-t", name])
        Log.tmux.info("killed session \(name, privacy: .public)")
    }

    /// Write pass metadata onto an adopted session (created outside pass).
    func adoptTag(name: String, projectRoot: String, agent: AgentKind) async {
        await run(["set-option", "-t", name, PassConfig.optProjectRoot, projectRoot])
        await run(["set-option", "-t", name, PassConfig.optAgent, agent.rawValue])
        await run(["set-environment", "-t", name, PassConfig.sessionEnvVar, name])
    }

    // MARK: Preview & injection primitives (used by ReplyInjector in M2)

    /// Visible pane contents. `colors: true` includes SGR escapes (`-e`).
    func capturePane(_ name: String, colors: Bool) async -> String {
        var args = ["capture-pane", "-p", "-J", "-t", name]
        if colors { args.insert("-e", at: 1) }
        return await run(args).stdout
    }

    /// Resize a session's window so its TUI renders to fit the preview. Only meaningful when
    /// no terminal is attached (an attached client's size wins). Clamped to sane bounds.
    func resizeWindow(_ name: String, cols: Int, rows: Int) async {
        let c = max(40, min(400, cols))
        let r = max(10, min(200, rows))
        await run(["resize-window", "-t", name, "-x", String(c), "-y", String(r)])
    }

    /// Query a pane fact via display-message.
    func display(_ name: String, _ format: String) async -> String {
        await run(["display-message", "-p", "-t", name, format]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// (pane_in_mode, pane_current_command) in one query — the ReplyInjector pre-check.
    func paneState(_ name: String) async -> (inMode: Bool, command: String) {
        let out = await display(name, "#{pane_in_mode}\t#{pane_current_command}")
        let f = out.components(separatedBy: "\t")
        return (f.first == "1", f.count > 1 ? f[1] : "")
    }

    // MARK: send-keys / buffer primitives (ReplyInjector)

    /// Load arbitrary text into the tmux paste buffer. Passed as a single Process argument,
    /// so newlines/quotes/specials need no escaping (no shell involved).
    func setBuffer(_ text: String) async {
        await run(["set-buffer", "--", text])
    }

    /// Paste the buffer into a pane using bracketed paste (`-p`), deleting the buffer (`-d`).
    /// Bracketed paste lets Ink receive multi-line text without submitting (FINDINGS §2).
    func pasteBuffer(into name: String) async {
        await run(["paste-buffer", "-t", name, "-p", "-d"])
    }

    /// Send literal key names (e.g. ["Enter"], ["1"], ["y"]) to a pane.
    func sendKeys(_ name: String, _ keys: [String]) async {
        await run(["send-keys", "-t", name] + keys)
    }

    /// Exit copy-mode (or any pane mode) if the pane is in one.
    func cancelMode(_ name: String) async {
        await run(["send-keys", "-t", name, "-X", "cancel"])
    }
}
