import Foundation

/// Installs pass's HTTP hooks into ~/.claude/settings.json by MERGING — it never rewrites
/// or removes entries it didn't create (e.g. the user's Orca/cmux command hooks). Identifies
/// its own hooks by URL, so it is idempotent. Backs the file up before the first change.
enum ClaudeHooksInstaller {
    // SessionStart is intentionally omitted — it does not fire as an HTTP hook (FINDINGS §1).
    private static let events = ["Notification", "Stop", "UserPromptSubmit", "SessionEnd"]

    private static var url: String { "\(PassConfig.hookBaseURL)/hook/claude" }

    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    enum Status: Equatable { case installed, alreadyInstalled, failed(String) }

    /// True if all of pass's hooks are already present (used to gate the first-run prompt).
    static func isInstalled() -> Bool {
        guard let root = readSettings() else { return false }
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return events.allSatisfy { hasOurHook(in: hooks[$0] as? [[String: Any]] ?? []) }
    }

    @discardableResult
    static func install() -> Status {
        let existing = readSettings() ?? [:]
        var (root, changed) = merged(into: existing)
        // The passcli advertise hook installs alongside (individually removable in Settings).
        let advertised = mergedAdvertise(into: root)
        root = advertised.root
        changed = changed || advertised.changed
        guard changed else { return .alreadyInstalled }

        backupIfNeeded() // only when we're actually about to change the file
        return write(root)
    }

    /// Pure merge: add pass's hooks + allowlist entry to a settings dict without removing
    /// anything else. Idempotent. Returns the new dict and whether it changed.
    static func merged(into existing: [String: Any]) -> (root: [String: Any], changed: Bool) {
        var root = existing
        var changed = false

        var allowed = (root["allowedHttpHookUrls"] as? [String]) ?? []
        if !allowed.contains(url) { allowed.append(url); root["allowedHttpHookUrls"] = allowed; changed = true }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            if hasOurHook(in: groups) { continue }
            groups.append(ourGroup(for: event))
            hooks[event] = groups
            changed = true
        }
        root["hooks"] = hooks
        return (root, changed)
    }

    // MARK: passcli advertise (SessionStart command hook — BROWSER.md §5.2)
    // NOTE S6.4: HTTP-type SessionStart does not fire (FINDINGS §1); command-type is a
    // different path and is expected to — validate on-device before relying on it.

    /// Runs via sh, so $HOME expands. `passcli advertise` prints additionalContext JSON only
    /// when it's a pass session AND pass is running — zero noise anywhere else.
    static var advertiseCommand: String { "\"$HOME/.pass/bin/passcli\" advertise" }

    static func isAdvertiseInstalled() -> Bool {
        guard let root = readSettings() else { return false }
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return hasAdvertise(in: hooks["SessionStart"] as? [[String: Any]] ?? [])
    }

    @discardableResult
    static func installAdvertise() -> Status {
        let existing = readSettings() ?? [:]
        let (root, changed) = mergedAdvertise(into: existing)
        guard changed else { return .alreadyInstalled }
        backupIfNeeded()
        return write(root)
    }

    @discardableResult
    static func removeAdvertise() -> Status {
        guard let existing = readSettings() else { return .alreadyInstalled }
        let (root, changed) = removedAdvertise(from: existing)
        guard changed else { return .alreadyInstalled }
        backupIfNeeded()
        return write(root)
    }

    /// Pure merge — add the advertise hook without touching anything else. Idempotent.
    static func mergedAdvertise(into existing: [String: Any]) -> (root: [String: Any], changed: Bool) {
        var root = existing
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var groups = hooks["SessionStart"] as? [[String: Any]] ?? []
        guard !hasAdvertise(in: groups) else { return (existing, false) }
        groups.append(["hooks": [[
            "type": "command",
            "command": advertiseCommand,
            "timeout": 5,
        ] as [String: Any]]])
        hooks["SessionStart"] = groups
        root["hooks"] = hooks
        return (root, true)
    }

    /// Pure removal — strip only our advertise entries; groups that end up empty are dropped,
    /// everything else (the user's own SessionStart hooks) survives untouched.
    static func removedAdvertise(from existing: [String: Any]) -> (root: [String: Any], changed: Bool) {
        var root = existing
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let groups = hooks["SessionStart"] as? [[String: Any]] ?? []
        var changed = false
        let remaining: [[String: Any]] = groups.compactMap { group in
            var g = group
            var inner = g["hooks"] as? [[String: Any]] ?? []
            let before = inner.count
            inner.removeAll { isAdvertiseHook($0) }
            guard inner.count != before else { return g }
            changed = true
            guard !inner.isEmpty else { return nil }
            g["hooks"] = inner
            return g
        }
        guard changed else { return (existing, false) }
        if remaining.isEmpty { hooks.removeValue(forKey: "SessionStart") }
        else { hooks["SessionStart"] = remaining }
        root["hooks"] = hooks
        return (root, true)
    }

    private static func hasAdvertise(in groups: [[String: Any]]) -> Bool {
        groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { isAdvertiseHook($0) }
        }
    }

    private static func isAdvertiseHook(_ hook: [String: Any]) -> Bool {
        guard (hook["type"] as? String) == "command",
              let command = hook["command"] as? String else { return false }
        return command.contains("/.pass/bin/passcli") && command.contains("advertise")
    }

    private static func write(_ root: [String: Any]) -> Status {
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: .atomic)
            Log.hooks.info("updated pass hooks in \(settingsURL.path, privacy: .public)")
            return .installed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: helpers

    private static func ourGroup(for event: String) -> [String: Any] {
        let hook: [String: Any] = [
            "type": "http",
            "url": url,
            "headers": ["X-Pass-Session": "$\(PassConfig.sessionEnvVar)"],
            "allowedEnvVars": [PassConfig.sessionEnvVar],
            "timeout": 3,
        ]
        var group: [String: Any] = ["hooks": [hook]]
        if event == "Notification" {
            group["matcher"] = "permission_prompt|idle_prompt|elicitation_dialog|agent_needs_input"
        }
        return group
    }

    private static func hasOurHook(in groups: [[String: Any]]) -> Bool {
        for group in groups {
            let hooksArr = group["hooks"] as? [[String: Any]] ?? []
            for h in hooksArr where (h["type"] as? String) == "http" && (h["url"] as? String) == url {
                return true
            }
        }
        return false
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func backupIfNeeded() {
        let backup = settingsURL.appendingPathExtension("pass-backup")
        guard FileManager.default.fileExists(atPath: settingsURL.path),
              !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: settingsURL, to: backup)
        Log.hooks.info("backed up settings.json to \(backup.lastPathComponent, privacy: .public)")
    }
}
