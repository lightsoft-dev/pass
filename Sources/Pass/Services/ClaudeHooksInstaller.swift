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
        let (root, changed) = merged(into: existing)
        guard changed else { return .alreadyInstalled }

        backupIfNeeded() // only when we're actually about to change the file
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: .atomic)
            Log.hooks.info("installed pass hooks into \(settingsURL.path, privacy: .public)")
            return .installed
        } catch {
            return .failed(error.localizedDescription)
        }
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
