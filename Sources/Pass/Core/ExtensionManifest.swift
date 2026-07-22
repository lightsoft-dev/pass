import Foundation

/// The permission / event / context vocabulary extensions can use (docs/EXTENSIONS.md §5).
/// Kept in one place so validation, runtime enforcement, and the docs never drift apart.
enum ExtensionCatalog {
    static let permissions: Set<String> = [
        "run:script",       // run a script bundled in the extension folder
        "session:send",     // inject text into a session (ReplyInjector rules apply)
        "session:create",   // start a tmux session (terminal-mode scripts)
        "session:read",     // read the current session snapshot from a web UI
        "notify",           // post a macOS notification
        "open:url",         // open a URL in the default handler
        "ui:window",        // open an extension-owned HTML/CSS/JS window
        "events:attention", // subscribe to attention.* events
        "events:session",   // subscribe to session.* events
    ]

    static let events: Set<String> = [
        "attention.pending",  // a session started waiting on the user (decision/input/finished)
        "attention.resolved", // it no longer is
        "session.created",    // a tmux session appeared
        "session.ended",      // one vanished
    ]

    static let commandContexts: Set<String> = ["session", "project", "global"]

    /// The permission a rule must declare to subscribe to an event.
    static func permission(forEvent event: String) -> String? {
        if event.hasPrefix("attention.") { return "events:attention" }
        if event.hasPrefix("session.") { return "events:session" }
        return nil
    }
}

/// One extension's `extension.json` (`~/.pass/extensions/<id>/`). The file on disk is the only
/// source of truth — pass never mirrors it (same rule as SpecDocument). This type is pure data
/// + validation; loading lives in ExtensionStore, execution in ExtensionRuntime.
struct ExtensionManifest: Codable, Hashable, Sendable {
    var apiVersion: Int
    var id: String
    var name: String
    var version: String?
    var description: String?
    /// Capabilities declared up front — shown to the user in Settings and enforced again at
    /// run time (an action whose permission isn't declared is refused, not just warned about).
    var permissions: [String]?
    var contributes: Contributes?

    struct Contributes: Codable, Hashable, Sendable {
        var commands: [Command]?
        var rules: [Rule]?
        /// Named actions exposed to a web UI through `pass.runAction(id, input)`. The page can
        /// request only these actions; it never receives a raw shell/filesystem bridge.
        var actions: [String: Action]?
        var windows: [Window]?
    }

    /// An app-owned NSWindow whose content is rendered by an isolated WKWebView. `entry` and all
    /// of its relative assets stay inside the extension directory and load through the private
    /// pass-extension:// scheme (never file://).
    struct Window: Codable, Hashable, Sendable {
        var id: String
        var title: String
        var entry: String
        var width: Double?
        var height: Double?
        var subscriptions: [String]?
    }

    /// A quick-command palette entry, typed as `>id` (the `>` prefix is VS Code's command
    /// convention — `/` is NOT used because slash commands like `/compact` must keep flowing
    /// to the agent session). `context` names what must be selected when it runs: "session" /
    /// "project" hand the selected session to the action's templates; "global" (default) runs bare.
    struct Command: Codable, Hashable, Sendable {
        var id: String
        var title: String
        var context: String?
        var run: Action

        var contextKind: String { context ?? "global" }
    }

    /// Event → action. Rules are pure observers: they can never swallow, answer, or reorder
    /// the event they fire on (v1 design decision — see docs/EXTENSIONS.md §8).
    struct Rule: Codable, Hashable, Sendable {
        var on: String
        var filter: Filter?
        var run: Action

        // The JSON key is `if` (reads naturally in a manifest); Swift-side it's `filter`.
        enum CodingKeys: String, CodingKey {
            case on, run
            case filter = "if"
        }

        func matches(event: String, kind: String?) -> Bool {
            guard on == event else { return false }
            if let kinds = filter?.kind, !kinds.isEmpty {
                guard let kind, kinds.contains(kind) else { return false }
            }
            return true
        }
    }

    struct Filter: Codable, Hashable, Sendable {
        /// Narrow attention events by kind: "decision" | "input" | "finished".
        var kind: [String]?
    }

    /// What a command/rule does — exactly ONE effect.
    struct Action: Codable, Hashable, Sendable {
        /// Path of a script INSIDE the extension folder (relative, no escapes).
        var script: String?
        /// argv for the script, template-expanded. The full context also arrives as JSON on stdin.
        var args: [String]?
        /// Background scripts only (default 30s, clamped to 1…600). Terminal scripts run visibly
        /// in their own session and are the user's to interrupt.
        var timeoutSeconds: Int?
        /// true → the script runs in a visible tmux command session (opened in the panel)
        /// instead of headless. The session closes when the script exits.
        var terminal: Bool?
        /// Text injected into the context session — inherits ReplyInjector's bare-shell refusal.
        var sendText: String?
        var notify: Notify?
        var openURL: String?
        /// Opens a contributed HTML window by id. Web windows require apiVersion 2.
        var openWindow: String?

        /// Permissions this action needs the manifest to have declared.
        var requiredPermissions: Set<String> {
            var p: Set<String> = []
            if script != nil {
                p.insert("run:script")
                if terminal == true { p.insert("session:create") }
            }
            if sendText != nil { p.insert("session:send") }
            if notify != nil { p.insert("notify") }
            if openURL != nil { p.insert("open:url") }
            if openWindow != nil { p.insert("ui:window") }
            return p
        }

        var effectCount: Int {
            [script != nil, sendText != nil, notify != nil, openURL != nil, openWindow != nil]
                .filter { $0 }.count
        }

        /// Short human label for logs ("script usage.sh", "sendText", …).
        var summary: String {
            if let script { return (terminal == true ? "terminal " : "script ") + script }
            if sendText != nil { return "sendText" }
            if notify != nil { return "notify" }
            if openURL != nil { return "openURL" }
            if let openWindow { return "openWindow " + openWindow }
            return "(empty)"
        }
    }

    struct Notify: Codable, Hashable, Sendable {
        var title: String
        var body: String?
    }
}

// MARK: - Validation

extension ExtensionManifest {
    /// Everything wrong with this manifest, in load order. A non-empty result blocks enabling —
    /// broken extensions surface in Settings with these messages instead of silently vanishing.
    func problems(directory: URL, fileManager: FileManager = .default) -> [String] {
        var out: [String] = []
        if ![1, 2].contains(apiVersion) {
            out.append("apiVersion \(apiVersion) is not supported (this pass supports 1 and 2)")
        }
        if !Self.isValidIdentifier(id) {
            out.append("id \"\(id)\" must be lowercase letters, digits, and '-'")
        }
        if id != directory.lastPathComponent {
            out.append("id \"\(id)\" must match its folder name \"\(directory.lastPathComponent)\"")
        }
        let declared = Set(permissions ?? [])
        for p in declared.sorted() where !ExtensionCatalog.permissions.contains(p) {
            out.append("unknown permission \"\(p)\"")
        }

        let windows = contributes?.windows ?? []
        let windowIds = Set(windows.map(\.id))
        if apiVersion < 2, !windows.isEmpty || !(contributes?.actions?.isEmpty ?? true) {
            out.append("windows and named actions require apiVersion 2")
        }

        var seenWindowIds: Set<String> = []
        for window in windows {
            let label = "window \(window.id)"
            if !Self.isValidIdentifier(window.id) {
                out.append("\(label): id must be lowercase letters, digits, and '-'")
            }
            if !seenWindowIds.insert(window.id).inserted {
                out.append("\(label): duplicate window id")
            }
            if window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append("\(label): title must not be empty")
            }
            if let width = window.width, !(320...1920).contains(width) {
                out.append("\(label): width must be between 320 and 1920")
            }
            if let height = window.height, !(240...1200).contains(height) {
                out.append("\(label): height must be between 240 and 1200")
            }
            if !declared.contains("ui:window") {
                out.append("\(label): permission \"ui:window\" not declared")
            }
            if !window.entry.lowercased().hasSuffix(".html") {
                out.append("\(label): entry must be an HTML file")
            }
            if case .failure(let problem) = Self.resolveResource(window.entry, in: directory,
                                                                  fileManager: fileManager) {
                out.append("\(label): \(problem.message)")
            }
            var subscriptions: Set<String> = []
            for event in window.subscriptions ?? [] {
                if !subscriptions.insert(event).inserted {
                    out.append("\(label): duplicate subscription \"\(event)\"")
                }
                if !ExtensionCatalog.events.contains(event) {
                    out.append("\(label): unknown event \"\(event)\"")
                } else if let needed = ExtensionCatalog.permission(forEvent: event),
                          !declared.contains(needed) {
                    out.append("\(label): permission \"\(needed)\" not declared")
                }
            }
        }

        for (id, action) in contributes?.actions ?? [:] {
            let label = "action \(id)"
            if !Self.isValidIdentifier(id) {
                out.append("\(label): id must be lowercase letters, digits, and '-'")
            }
            out += actionProblems(action, label: label, declared: declared,
                                  directory: directory, fileManager: fileManager)
            if let target = action.openWindow, !windowIds.contains(target) {
                out.append("\(label): unknown window \"\(target)\"")
            }
        }

        var commandIds: Set<String> = []
        for cmd in contributes?.commands ?? [] {
            let label = "command /\(cmd.id)"
            if !Self.isValidIdentifier(cmd.id) {
                out.append("\(label): id must be lowercase letters, digits, and '-'")
            }
            if !commandIds.insert(cmd.id).inserted {
                out.append("\(label): duplicate command id")
            }
            if !ExtensionCatalog.commandContexts.contains(cmd.contextKind) {
                out.append("\(label): unknown context \"\(cmd.contextKind)\"")
            }
            if cmd.run.sendText != nil && cmd.contextKind != "session" {
                out.append("\(label): sendText needs context \"session\"")
            }
            out += actionProblems(cmd.run, label: label, declared: declared,
                                  directory: directory, fileManager: fileManager)
            if let target = cmd.run.openWindow, !windowIds.contains(target) {
                out.append("\(label): unknown window \"\(target)\"")
            }
        }
        for rule in contributes?.rules ?? [] {
            let label = "rule on \(rule.on)"
            if !ExtensionCatalog.events.contains(rule.on) {
                out.append("\(label): unknown event")
            } else if let needed = ExtensionCatalog.permission(forEvent: rule.on),
                      !declared.contains(needed) {
                out.append("\(label): permission \"\(needed)\" not declared")
            }
            if rule.run.openWindow != nil {
                out.append("\(label): openWindow is command/action-only")
            }
            out += actionProblems(rule.run, label: label, declared: declared,
                                  directory: directory, fileManager: fileManager)
        }
        return out
    }

    private func actionProblems(_ action: Action, label: String, declared: Set<String>,
                                directory: URL, fileManager: FileManager) -> [String] {
        var out: [String] = []
        if action.effectCount != 1 {
            out.append("\(label): exactly one of script / sendText / notify / openURL / openWindow")
        }
        if action.terminal == true && action.script == nil {
            out.append("\(label): terminal needs a script")
        }
        for p in action.requiredPermissions.sorted() where !declared.contains(p) {
            out.append("\(label): permission \"\(p)\" not declared")
        }
        if action.script != nil,
           case .failure(let problem) = action.resolveScript(in: directory, fileManager: fileManager) {
            out.append("\(label): \(problem.message)")
        }
        return out
    }

    /// Extension / command ids: lowercase ascii letters, digits, '-'; must not start with '-'.
    static func isValidIdentifier(_ s: String) -> Bool {
        guard let first = s.first, first != "-" else { return false }
        return s.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    struct ResourceError: Error, CustomStringConvertible, ExpressibleByStringLiteral {
        let message: String
        init(_ message: String) { self.message = message }
        init(stringLiteral value: String) { message = value }
        var description: String { message }
    }

    /// Resolve any extension-owned file and follow symlinks before enforcing containment. This
    /// closes the lexical-only hole where `ui/index.html` or a script was a symlink to a file
    /// outside the reviewed extension directory.
    static func resolveResource(_ path: String, in directory: URL,
                                fileManager: FileManager = .default) -> Result<URL, ResourceError> {
        guard !path.isEmpty else { return .failure("resource path must not be empty") }
        guard !path.hasPrefix("/") else {
            return .failure("resource must be a relative path inside the extension folder")
        }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let url = directory.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root + "/") else {
            return .failure("resource must stay inside the extension folder")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .failure(ResourceError("resource not found: \(path)"))
        }
        return .success(url)
    }
}

extension ExtensionManifest.Action {
    /// Why a script path was rejected — carried as the `Result` failure so callers can surface
    /// the exact reason. A string literal is enough to construct one (`Result` requires the
    /// failure to be an `Error`, which a bare `String` is not).
    struct ScriptError: Error, CustomStringConvertible, ExpressibleByStringLiteral {
        let message: String
        init(_ message: String) { self.message = message }
        init(stringLiteral value: String) { message = value }
        var description: String { message }
    }

    /// Resolve `script` against the extension folder, refusing anything that escapes it.
    /// The ONE containment rule, shared by validation (`problems`) and runtime enforcement —
    /// two hand-rolled copies would drift the first time either is hardened. Path-normalizing
    /// (`a/./b`, `sub/../x`) rather than substring-matching, so a file legitimately named
    /// `report..v2.sh` is not rejected.
    func resolveScript(in directory: URL, fileManager: FileManager = .default) -> Result<URL, ScriptError> {
        guard let script, !script.isEmpty else { return .failure("action has no script") }
        switch ExtensionManifest.resolveResource(script, in: directory, fileManager: fileManager) {
        case .success(let url): return .success(url)
        case .failure(let error):
            let message = error.message.replacingOccurrences(of: "resource", with: "script")
            return .failure(ScriptError(message))
        }
    }
}

// MARK: - Templates

/// `${key}` substitution for action strings (args, sendText, notify, openURL). Unknown keys
/// expand to "" — a missing value must never leak the literal placeholder into a session.
enum ExtensionTemplate {
    static func expand(_ template: String, context: [String: String]) -> String {
        guard template.contains("${") else { return template }
        var out = ""
        var rest = template[...]
        while let start = rest.range(of: "${") {
            out += rest[..<start.lowerBound]
            let after = rest[start.upperBound...]
            guard let end = after.firstIndex(of: "}") else {
                out += rest[start.lowerBound...] // unterminated → keep literally
                return out
            }
            out += context[String(after[..<end])] ?? ""
            rest = after[after.index(after: end)...]
        }
        out += rest
        return out
    }
}
