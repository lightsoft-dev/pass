import Foundation

/// Persists the parts of session state that aren't derivable from tmux/git — the "needs you"
/// queue and each session's last response — so they survive an app restart. (Sessions
/// themselves survive because tmux owns them; this is the layer pass adds on top.)
enum SessionStatePersistence {
    /// Enough to recreate a session after its tmux server dies (reboot / `kill-server`): the live
    /// list is tmux-derived and vanishes with the server, and the project/agent binding lives only
    /// in tmux options. Persisting it lets pass respawn the session (same dir + agent, `--continue`
    /// for Claude) on the next launch.
    struct SessionRef: Codable, Equatable {
        var name: String
        var projectRoot: String
        var cwd: String
        var agent: String   // AgentKind rawValue
    }

    struct Snapshot: Codable {
        struct Pending: Codable {
            var kind: String        // Attention.Kind rawValue
            var receivedAt: Date
            var preview: String
        }
        var pending: [String: Pending] = [:]   // only .pending states are worth restoring
        var lastMessages: [String: String] = [:]
        // Sessions with a needs-you request the user hasn't checked yet (keeps the highlighted
        // border across restarts). Optional so older state.json files still decode.
        var unacked: [String]?
        // User-assigned display names per session (display-only aliases). Optional for the same
        // backward-compat reason.
        var aliases: [String: String]?
        // Each session's embedded-browser URL (BrowserStore) — restored on relaunch so the
        // split comes back showing the same page. Optional for backward compat. Owned by
        // BrowserStore; SessionStore load-modify-saves so it never clobbers this field.
        var browserURLs: [String: String]?
        // The previous run's live launchable-agent sessions, so they can be recreated if the
        // tmux server was restarted meanwhile. Optional for backward compat.
        var sessions: [SessionRef]?
    }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pass", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    static func load() -> Snapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return Snapshot() }
        return snap
    }

    static func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
