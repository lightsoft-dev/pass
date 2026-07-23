import AppKit
import Foundation
import Observation

/// Executes extension contributions: matches events against enabled rules and runs palette
/// commands. Extension code NEVER runs inside pass — scripts are child processes (crash
/// isolation), sendText goes through ReplyInjector (bare-shell refusal included), and every
/// action re-checks its declared permission before running (validation is advice; this is
/// the enforcement).
@MainActor
@Observable
final class ExtensionRuntime: ExtensionWindowRuntime {
    struct LogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let extensionId: String
        let summary: String
        let ok: Bool
        let detail: String?
    }

    /// Newest-first ring of recent executions — the first place to look when a rule
    /// "didn't fire" (shown in Settings › Extensions).
    private(set) var recentLog: [LogEntry] = []
    private static let logCap = 50

    private let store: ExtensionStore
    private let windows: ExtensionWindowManager
    private weak var appModel: AppModel?
    private var eventSequence: UInt64 = 0

    /// Sessions with a dispatched attention.pending that hasn't resolved yet. EventRouter's
    /// onResolved fires on EVERY started/ended hook (fine for its original job, idempotent
    /// notification clearing) — extensions only get real pending→resolved transitions.
    private var pendingSessions: Set<String> = []

    init(store: ExtensionStore, windows: ExtensionWindowManager, appModel: AppModel) {
        self.store = store
        self.windows = windows
        self.appModel = appModel
    }

    // MARK: Events (wired from EventRouter + SessionStore)

    func attentionPending(sessionName: String, attention: Attention) {
        pendingSessions.insert(sessionName)
        dispatch(event: "attention.pending", kind: attention.kind.rawValue,
                 session: appModel?.sessions?.session(named: sessionName),
                 extra: ["session.name": sessionName, "attention.preview": attention.preview])
    }

    func attentionResolved(sessionName: String) {
        guard pendingSessions.remove(sessionName) != nil else { return }
        dispatch(event: "attention.resolved", kind: nil,
                 session: appModel?.sessions?.session(named: sessionName),
                 extra: ["session.name": sessionName])
    }

    /// (Report sessions the runtime spawns never arrive here — SessionStore excludes
    /// ephemeral command sessions from the created/ended diff at the source.)
    func sessionsCreated(_ created: [Session]) {
        for s in created {
            dispatch(event: "session.created", kind: nil, session: s, extra: [:])
        }
    }

    func sessionsEnded(_ names: [String]) {
        // The session is gone — only its name survives into the context.
        for name in names {
            // Dying while pending resolves the attention implicitly — extensions pairing
            // pending/resolved statefully must not be left hanging.
            if pendingSessions.remove(name) != nil {
                dispatch(event: "attention.resolved", kind: nil, session: nil,
                         extra: ["session.name": name])
            }
            dispatch(event: "session.ended", kind: nil, session: nil, extra: ["session.name": name])
        }
    }

    private func dispatch(event: String, kind: String?, session: Session?, extra: [String: String]) {
        let ctx = context(event: event, kind: kind, session: session, extra: extra)
        eventSequence &+= 1
        windows.publish(name: event, envelope: eventEnvelope(sequence: eventSequence, name: event,
                                                              kind: kind, session: session,
                                                              context: ctx))
        let matched = store.activeRules.filter { $0.rule.matches(event: event, kind: kind) }
        guard !matched.isEmpty else { return }
        for (ext, rule) in matched {
            // Fire-and-forget: one slow script must not delay the next rule or the event source.
            Task { [weak self] in
                let err = await self?.execute(rule.run, extensionId: ext.id,
                                              permissions: Set(ext.manifest.permissions ?? []),
                                              directory: ext.directory, fingerprint: ext.fingerprint,
                                              slug: "rule",
                                              label: "\(ext.manifest.name): \(event)",
                                              context: ctx, session: session)
                self?.log(ext.id, "\(event) → \(rule.run.summary)", ok: err == nil, detail: err)
            }
        }
    }

    // MARK: Commands (from the ⌘P palette)

    /// Run a palette command. Returns nil on success, or a short error for the quick command
    /// to surface (same contract as createWorktreeSession).
    func run(_ item: ExtensionStore.PaletteCommand, session: Session?) async -> String? {
        if item.command.contextKind != "global" && session == nil {
            return "select a session first"
        }
        let ctxSession = item.command.contextKind == "global" ? nil : session
        var extra: [String: String] = ["command.id": item.command.id]
        if let s = ctxSession { extra["session.name"] = s.name }
        let ctx = context(event: nil, kind: nil, session: ctxSession, extra: extra)
        let err = await execute(item.command.run, extensionId: item.extensionId,
                                permissions: item.permissions, directory: item.directory,
                                fingerprint: item.fingerprint,
                                slug: item.command.id, label: item.command.title,
                                context: ctx, session: ctxSession)
        log(item.extensionId, "\(item.token) → \(item.command.run.summary)", ok: err == nil, detail: err)
        return err
    }

    /// Named manifest actions are the only native capabilities exposed to extension JavaScript.
    /// UI input becomes `${input.key}` template values; `sessionName` optionally supplies the
    /// session context required by sendText/session templates.
    func runNamedAction(extensionId: String, actionId: String,
                        input: [String: String]) async -> String? {
        guard let ext = store.activeExtension(id: extensionId) else { return "extension is disabled" }
        guard let action = ext.manifest.contributes?.actions?[actionId] else {
            return "unknown action \"\(actionId)\""
        }
        let session = input["sessionName"].flatMap { appModel?.sessions?.session(named: $0) }
        if action.sendText != nil, session == nil { return "action needs input.sessionName" }
        var extra = ["action.id": actionId]
        for (key, value) in input { extra["input." + key] = value }
        let ctx = context(event: nil, kind: nil, session: session, extra: extra)
        let error = await execute(action, extensionId: extensionId,
                                  permissions: Set(ext.manifest.permissions ?? []),
                                  directory: ext.directory, fingerprint: ext.fingerprint,
                                  slug: actionId,
                                  label: "\(ext.manifest.name): \(actionId)",
                                  context: ctx, session: session)
        log(extensionId, "action \(actionId) → \(action.summary)",
            ok: error == nil, detail: error)
        return error
    }

    /// Read-only state exposed only when a window declared `session:read`.
    func webSnapshot(extensionId: String, permissions: Set<String>) -> [String: Any] {
        guard permissions.contains("session:read"), store.activeExtension(id: extensionId) != nil else {
            return ["schemaVersion": 1, "sessions": []]
        }
        return [
            "schemaVersion": 1,
            "generatedAt": Self.iso8601.string(from: Date()),
            "sessions": (appModel?.sessions?.sessions ?? []).map(Self.sessionPayload),
        ]
    }

    // MARK: Template context

    private func context(event: String?, kind: String?, session: Session?,
                         extra: [String: String]) -> [String: String] {
        var ctx: [String: String] = [:]
        if let event { ctx["event.name"] = event }
        if let kind { ctx["attention.kind"] = kind }
        if let s = session {
            ctx["session.name"] = s.name
            ctx["session.displayName"] = s.displayName
            ctx["session.cwd"] = s.cwd
            ctx["session.agent"] = s.agent.rawValue
            ctx["project.root"] = s.projectRoot
            ctx["project.name"] = URL(fileURLWithPath: s.projectRoot).lastPathComponent
            if let branch = s.git?.branch { ctx["git.branch"] = branch }
        }
        for (k, v) in extra { ctx[k] = v }
        return ctx
    }

    private func eventEnvelope(sequence: UInt64, name: String, kind: String?, session: Session?,
                               context: [String: String]) -> [String: Any] {
        var event: [String: Any] = [
            "schemaVersion": 1,
            "sequence": sequence,
            "name": name,
            "occurredAt": Self.iso8601.string(from: Date()),
            "context": context,
        ]
        if let kind { event["kind"] = kind }
        if let session { event["session"] = Self.sessionPayload(session) }
        return event
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func sessionPayload(_ session: Session) -> [String: Any] {
        var payload: [String: Any] = [
            "name": session.name,
            "displayName": session.displayName,
            "projectRoot": session.projectRoot,
            "cwd": session.cwd,
            "agent": session.agent.rawValue,
            "lastActivity": iso8601.string(from: session.lastActivity),
            "isAttached": session.isAttached,
            "needsUser": session.needsUser,
        ]
        if let branch = session.git?.branch { payload["branch"] = branch }
        switch session.attention {
        case .working: payload["attention"] = ["state": "working"]
        case .idle: payload["attention"] = ["state": "idle"]
        case .pending(let attention):
            payload["attention"] = [
                "state": "pending",
                "kind": attention.kind.rawValue,
                "preview": attention.preview,
                "receivedAt": iso8601.string(from: attention.receivedAt),
            ]
        }
        return payload
    }

    // MARK: Execution

    /// Run one action. Returns nil on success, else a short error message.
    private func execute(_ action: ExtensionManifest.Action, extensionId: String,
                         permissions: Set<String>, directory: URL,
                         fingerprint: String,
                         slug: String, label: String,
                         context ctx: [String: String], session: Session?) async -> String? {
        guard let lease = store.beginExecution(
            extensionId: extensionId, fingerprint: fingerprint, directory: directory)
        else { return "extension is disabled or changed" }
        defer { store.endExecution(lease) }

        // Enforcement, not just validation: undeclared capability → refuse, whatever the manifest
        // said elsewhere. This is the promise the install/enable review makes to the user.
        if let missing = action.requiredPermissions.sorted().first(where: { !permissions.contains($0) }) {
            return "blocked — permission \"\(missing)\" not declared"
        }

        if action.script != nil {
            let url: URL
            switch action.resolveScript(in: directory) { // same resolver validation uses
            case .failure(let error): return error.description
            case .success(let resolved): url = resolved
            }
            let args = (action.args ?? []).map { ExtensionTemplate.expand($0, context: ctx) }
            if action.terminal == true {
                return await runInTerminal(url: url, args: args, slug: slug, label: label,
                                           session: session, lease: lease)
            }
            let payload = try? JSONSerialization.data(withJSONObject: ctx, options: [.sortedKeys])
            let timeout = TimeInterval(min(max(action.timeoutSeconds ?? 30, 1), 600))
            let r = await Self.runScript(url: url, args: args, cwd: directory.path,
                                         stdin: payload, timeout: timeout)
            if r.ok { return nil }
            let tail = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)
            return "exit \(r.code)" + (tail.isEmpty ? "" : ": \(tail)")
        }

        if let text = action.sendText {
            guard let session else { return "needs a session" }
            guard let appModel else { return "not ready" }
            switch await appModel.reply(to: session.name, text: ExtensionTemplate.expand(text, context: ctx)) {
            case .delivered: return nil
            case .refusedShell: return "\(session.displayName): agent not running"
            case .error(let message): return message
            }
        }

        if let n = action.notify {
            // Unique kind per delivery — NotificationService replaces same-identifier banners,
            // and two rules firing seconds apart must not overwrite each other.
            await NotificationService().notify(
                session: "ext:" + extensionId, kind: "extension-" + UUID().uuidString,
                title: ExtensionTemplate.expand(n.title, context: ctx),
                body: ExtensionTemplate.expand(n.body ?? "", context: ctx), sound: false)
            return nil
        }

        if let raw = action.openURL {
            let expanded = ExtensionTemplate.expand(raw, context: ctx)
            guard let u = URL(string: expanded) else { return "bad URL: \(expanded)" }
            NSWorkspace.shared.open(u)
            return nil
        }

        if let windowId = action.openWindow {
            guard let ext = store.activeExtension(id: extensionId) else { return "extension is disabled" }
            guard let window = ext.manifest.contributes?.windows?.first(where: { $0.id == windowId }) else {
                return "unknown window \"\(windowId)\""
            }
            return windows.open(extension: ext, window: window)
        }

        return "action has nothing to run"
    }

    /// Terminal-mode script: run it in a visible tmux command session and open it in the panel.
    /// `; exit` closes the shell (and the session) when the script finishes, so spent report
    /// sessions never pile up in the home feed.
    private func runInTerminal(url: URL, args: [String], slug: String, label: String,
                               session: Session?, lease: ExtensionStore.ExecutionLease) async -> String? {
        guard let appModel, let sessions = appModel.sessions else { return "not ready" }
        guard !sessions.tmuxMissing else { return "tmux is unavailable" }
        let invocation = FileManager.default.isExecutableFile(atPath: url.path)
            ? Shell.singleQuoted(url.path)
            : "/bin/bash " + Shell.singleQuoted(url.path)
        let command = ([invocation] + args.map(Shell.singleQuoted)).joined(separator: " ") + "; exit"
        // Session-context commands run in the project; global ones in the extension folder.
        // Never remember either as a project — a report session is not a workspace.
        let cwd = session?.projectRoot ?? url.deletingLastPathComponent().path
        guard let name = await sessions.createCommandSession(
            projectDir: cwd, slug: slug, command: command, rememberProject: false,
            beforeLaunch: { [store] name in
                store.promoteExecution(lease, toTerminalSession: name)
            },
            launchFinished: { [store] name in
                store.finishTerminalLaunch(name)
            })
        else { return "could not reserve terminal execution" }
        sessions.setAlias(name, "⚙ \(label)")
        // Only steal the route while the panel is up (palette commands) — a background rule
        // must not yank the UI around.
        if appModel.panelVisible { appModel.forceOpenSession = name }
        return nil
    }

    /// Blocking child process off the main actor, with stdin payload + a terminate-on-timeout
    /// watchdog (Shell.run has neither). Scripts with the executable bit run directly (their
    /// shebang decides the interpreter); the rest fall back to bash.
    nonisolated private static func runScript(url: URL, args: [String], cwd: String,
                                              stdin: Data?, timeout: TimeInterval) async -> ProcResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: runScriptSync(url: url, args: args, cwd: cwd,
                                                     stdin: stdin, timeout: timeout))
            }
        }
    }

    /// One pipe's contents, filled by a background drain thread. Locked because the caller
    /// may give up waiting (leaked-grandchild case) while the drain is still appending.
    private final class PipeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    nonisolated private static func runScriptSync(url: URL, args: [String], cwd: String,
                                                  stdin: Data?, timeout: TimeInterval) -> ProcResult {
        let proc = Process()
        if FileManager.default.isExecutableFile(atPath: url.path) {
            proc.executableURL = url
            proc.arguments = args
        } else {
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [url.path] + args
        }
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return ProcResult(stdout: "", stderr: "spawn failed: \(error.localizedDescription)", code: -1)
        }

        // Drain stdout/stderr CONCURRENTLY — a script filling one pipe while we block reading
        // the other would deadlock at ~64KB (Shell.run reads sequentially because it has no
        // stdin/timeout; here both pipes can fill while we're still writing stdin).
        let out = PipeBox(), err = PipeBox()
        let drains = DispatchGroup()
        for (pipe, box) in [(outPipe, out), (errPipe, err)] {
            drains.enter()
            DispatchQueue.global(qos: .utility).async {
                box.set(pipe.fileHandleForReading.readDataToEndOfFile())
                drains.leave()
            }
        }

        // `write(contentsOf:)` (throwing) — the legacy write(_:) raises an uncatchable ObjC
        // exception when a fast script exits without reading stdin (EPIPE → app crash).
        if let stdin, !stdin.isEmpty { try? inPipe.fileHandleForWriting.write(contentsOf: stdin) }
        try? inPipe.fileHandleForWriting.close()

        // Watchdog: SIGTERM at the timeout; SIGKILL if the script ignores/traps it.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak proc] in
            guard let proc, proc.isRunning else { return }
            proc.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak proc] in
                guard let proc, proc.isRunning else { return }
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        proc.waitUntilExit()
        // Give the drains a moment, then abandon them: a grandchild that inherited the pipe
        // write-ends can hold them open indefinitely, and that must not wedge this run —
        // the drain threads finish (and free themselves) whenever the last writer exits.
        _ = drains.wait(timeout: .now() + 2)
        return ProcResult(stdout: String(decoding: out.get(), as: UTF8.self),
                          stderr: String(decoding: err.get(), as: UTF8.self),
                          code: proc.terminationStatus)
    }

    // MARK: Log

    private func log(_ extensionId: String, _ summary: String, ok: Bool, detail: String?) {
        recentLog.insert(LogEntry(date: Date(), extensionId: extensionId, summary: summary,
                                  ok: ok, detail: detail), at: 0)
        if recentLog.count > Self.logCap { recentLog.removeLast(recentLog.count - Self.logCap) }
        if ok {
            Log.ext.info("\(extensionId, privacy: .public): \(summary, privacy: .public)")
        } else {
            Log.ext.error("\(extensionId, privacy: .public): \(summary, privacy: .public) — \(detail ?? "?", privacy: .public)")
        }
    }
}
