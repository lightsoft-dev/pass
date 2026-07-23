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

/// Separates an authoritative empty tmux server from a transient command/parse failure. Callers
/// that release durable resources must act only on `.reliable` inventories.
enum TmuxSessionInventory: Sendable {
    case reliable([RawSession])
    case unavailable
}

struct TerminalPaneSnapshot: Equatable, Sendable {
    var content: String
    var columns: Int
    var rows: Int
    var cursorX: Int
    var cursorY: Int
}

protocol TerminalPaneAccess: Sendable {
    func terminalSnapshot(_ name: String) async -> TerminalPaneSnapshot?
    func sendTerminalInput(_ input: String, to name: String) async -> Bool
}

/// The ONLY thing that spawns tmux. Resolves the binary once; every call uses the absolute
/// path. Uses the default socket so `tmux attach` from any terminal just works.
actor TmuxClient: TerminalPaneAccess {
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

    /// The tmux CLIENT sanitizes its printed output by the process locale: under C/POSIX
    /// (GUI launch, systemd units, CI — no LANG) tabs in -F output become `_`, which breaks
    /// the tab-separated parsing above, and non-ASCII pane content can be octal-escaped.
    /// Force a UTF-8 LC_ALL for every tmux spawn unless the environment already has one.
    private static let localeEnv: [String: String] = {
        let env = ProcessInfo.processInfo.environment
        let effective = env["LC_ALL"] ?? env["LC_CTYPE"] ?? env["LANG"] ?? ""
        if effective.uppercased().contains("UTF-8") || effective.uppercased().contains("UTF8") {
            return [:]
        }
        return ["LC_ALL": "C.UTF-8"]
    }()

    /// Run tmux off the actor executor (Process.waitUntilExit blocks).
    @discardableResult
    func run(_ args: [String]) async -> ProcResult {
        guard let tmuxPath else {
            return ProcResult(stdout: "", stderr: "tmux not found", code: 127)
        }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Shell.run(tmuxPath, args, extraEnv: Self.localeEnv))
            }
        }
    }

    // MARK: Reconcile

    /// List all sessions with their active pane details. "No server" is an authoritative empty
    /// inventory; missing tmux, command failures, and malformed output are not.
    func sessionInventory() async -> TmuxSessionInventory {
        let s = fieldSep
        let sess = await run([
            "list-sessions", "-F",
            ["#{session_name}", "#{session_created}", "#{session_attached}",
             "#{session_activity}", "#{@pass_project_root}", "#{@pass_agent}"].joined(separator: s),
        ])
        guard sess.ok else {
            let diagnostic = (sess.stdout + "\n" + sess.stderr).lowercased()
            if diagnostic.contains("no server running") || diagnostic.contains("no sessions") {
                return .reliable([])
            }
            return .unavailable
        }
        if sess.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .reliable([])
        }

        // Active-pane details, one query for all sessions.
        let panes = await run([
            "list-panes", "-a", "-F",
            ["#{session_name}", "#{pane_active}", "#{pane_current_path}",
             "#{pane_current_command}", "#{pane_in_mode}"].joined(separator: s),
        ])
        guard panes.ok,
              !panes.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .unavailable }
        var paneBySession: [String: (cwd: String, cmd: String, inMode: Bool)] = [:]
        for line in panes.stdout.split(separator: "\n") {
            let f = line.components(separatedBy: s)
            guard f.count == 5 else { return .unavailable }
            guard f[1] == "1" else { continue } // active pane only
            paneBySession[f[0]] = (f[2], f[3], f[4] == "1")
        }

        var result: [RawSession] = []
        for line in sess.stdout.split(separator: "\n") {
            let f = line.components(separatedBy: s)
            guard f.count == 6 else { return .unavailable }
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
        return .reliable(result)
    }

    /// Convenience for diagnostics and smoke tests that do not own durable state.
    func listSessions() async -> [RawSession] {
        switch await sessionInventory() {
        case .reliable(let sessions): return sessions
        case .unavailable: return []
        }
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
    @discardableResult
    func newSession(name: String, cwd: String, projectRoot: String, agent: AgentKind,
                    launchCommand: String?) async -> Bool {
        let created = await run([
            // 160×42 ≈ the embedded home terminal — history written before the first attach
            // then reflows cleanly instead of arriving as 220-col lines that wrap oddly.
            "new-session", "-d", "-s", name, "-c", cwd, "-x", "160", "-y", "42",
            "-e", "\(PassConfig.sessionEnvVar)=\(name)",
            // Stable passcli path — agents call "$PASS_CLI" (rc files rebuild PATH but never
            // unset foreign env vars, so this survives where a PATH prepend wouldn't).
            "-e", "\(PassConfig.cliEnvVar)=\(PassConfig.cliSymlinkPath)",
        ])
        guard created.ok else {
            Log.tmux.error("create session \(name, privacy: .public) failed: \(created.stderr, privacy: .public)")
            return false
        }
        let taggedRoot = await run(["set-option", "-t", name, PassConfig.optProjectRoot, projectRoot])
        let taggedAgent = await run(["set-option", "-t", name, PassConfig.optAgent, agent.rawValue])
        guard taggedRoot.ok, taggedAgent.ok else {
            await run(["kill-session", "-t", name])
            Log.tmux.error("tag session \(name, privacy: .public) failed")
            return false
        }
        if let cmd = launchCommand, !cmd.isEmpty {
            let sent = await run(["send-keys", "-t", name, cmd, "Enter"])
            guard sent.ok else {
                await run(["kill-session", "-t", name])
                Log.tmux.error("launch session \(name, privacy: .public) failed: \(sent.stderr, privacy: .public)")
                return false
            }
        }
        Log.tmux.info("created session \(name, privacy: .public) agent=\(agent.rawValue) cwd=\(cwd, privacy: .public)")
        return true
    }

    func killSession(_ name: String) async {
        await run(["kill-session", "-t", name])
        Log.tmux.info("killed session \(name, privacy: .public)")
    }

    /// Write pass metadata onto an adopted session (created outside pass). set-environment
    /// only reaches NEW processes — passcli's tmux display-message fallback covers agents
    /// that started before adoption (BROWSER.md §5.3).
    func adoptTag(name: String, projectRoot: String, agent: AgentKind) async {
        await run(["set-option", "-t", name, PassConfig.optProjectRoot, projectRoot])
        await run(["set-option", "-t", name, PassConfig.optAgent, agent.rawValue])
        await run(["set-environment", "-t", name, PassConfig.sessionEnvVar, name])
        await run(["set-environment", "-t", name, PassConfig.cliEnvVar, PassConfig.cliSymlinkPath])
    }

    // MARK: Preview & injection primitives (used by ReplyInjector in M2)

    /// Visible pane contents. `colors: true` includes SGR escapes (`-e`).
    func capturePane(_ name: String, colors: Bool) async -> String {
        var args = ["capture-pane", "-p", "-J", "-t", name]
        if colors { args.insert("-e", at: 1) }
        return await run(args).stdout
    }

    /// Recent scrollback for semantic/readable renderers. This is intentionally separate from
    /// `capturePane`: previews only need the visible grid, while conversation views need turns
    /// that have already scrolled off-screen.
    func capturePaneHistory(_ name: String, lines: Int = 2_000) async -> String {
        await run([
            "capture-pane", "-p", "-J", "-S", "-\(max(1, lines))", "-t", name,
        ]).stdout
    }

    /// Captures the visible terminal grid without joining wrapped rows. Cursor and dimensions
    /// let a remote terminal renderer reconstruct the current screen after every reconnect.
    func terminalSnapshot(_ name: String) async -> TerminalPaneSnapshot? {
        let marker = "__PASS_TERMINAL_PANE__"
        let capture = await run([
            "capture-pane", "-p", "-e", "-t", name,
            ";", "display-message", "-p", "-t", name,
            "\(marker)\t#{pane_width}\t#{pane_height}\t#{cursor_x}\t#{cursor_y}",
        ])
        guard capture.ok,
              let markerRange = capture.stdout.range(
                of: "\n\(marker)\t",
                options: .backwards
              ) else { return nil }
        let paneContent = String(capture.stdout[..<markerRange.lowerBound])
        let factLine = capture.stdout[markerRange.upperBound...]
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let fields = factLine
            .components(separatedBy: "\t")
        guard fields.count == 4,
              let columns = Int(fields[0]), let rows = Int(fields[1]),
              let cursorX = Int(fields[2]), let cursorY = Int(fields[3]),
              columns > 0, rows > 0 else {
            return nil
        }
        return TerminalPaneSnapshot(
            content: paneContent,
            columns: columns,
            rows: rows,
            cursorX: max(0, min(cursorX, columns - 1)),
            cursorY: max(0, min(cursorY, rows - 1))
        )
    }

    /// Literal mode preserves composed Unicode and terminal escape sequences without asking tmux
    /// to reinterpret each UTF-8 byte as a separate key code.
    func sendTerminalInput(_ input: String, to name: String) async -> Bool {
        guard !input.isEmpty else { return true }
        if !input.utf8.contains(0) {
            return await run(["send-keys", "-l", "-t", name, "--", input]).ok
        }
        let hex = input.utf8.map { String(format: "%02x", $0) }
        return await run(["send-keys", "-t", name, "-H"] + hex).ok
    }

    /// Run before a pass client attaches. Older builds called `resize-window` for the text
    /// mirror, which pins the window to `window-size manual` — an attaching client then gets a
    /// clipped, letterboxed view (Claude's bottom status line cut off) instead of the window
    /// reflowing to the client's size. Revert to following the client, and hide tmux's own
    /// status bar so the terminal reads like a plain one (Claude's status line already carries
    /// branch/dir/mode).
    func prepareForAttach(_ name: String) async {
        await run(["set-option", "-w", "-t", name, "window-size", "latest"])
        await run(["set-option", "-t", name, "status", "off"])
        // Scrollback lives in tmux, not the embedded emulator (tmux redraws in place, so the
        // local buffer has nothing to scroll). Mouse mode turns wheel/trackpad scrolling into
        // tmux copy-mode scrolling — SwiftTerm forwards the events via the xterm protocol.
        await run(["set-option", "-t", name, "mouse", "on"])
        // Option-drag copy: normal drags are persistent local SwiftTerm selections. The default
        // MouseDragEnd1Pane binding pipes an explicit tmux selection to `copy-command`.
        await run(["set-option", "-s", "copy-command", "pbcopy"])
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
    @discardableResult
    func setBuffer(_ text: String) async -> Bool {
        await run(["set-buffer", "--", text]).ok
    }

    /// Paste the buffer into a pane using bracketed paste (`-p`), deleting the buffer (`-d`).
    /// Bracketed paste lets Ink receive multi-line text without submitting (FINDINGS §2).
    @discardableResult
    func pasteBuffer(into name: String) async -> Bool {
        await run(["paste-buffer", "-t", name, "-p", "-d"]).ok
    }

    /// Send literal key names (e.g. ["Enter"], ["1"], ["y"]) to a pane.
    @discardableResult
    func sendKeys(_ name: String, _ keys: [String]) async -> Bool {
        await run(["send-keys", "-t", name] + keys).ok
    }

    /// Exit copy-mode (or any pane mode) if the pane is in one.
    func cancelMode(_ name: String) async {
        await run(["send-keys", "-t", name, "-X", "cancel"])
    }
}
