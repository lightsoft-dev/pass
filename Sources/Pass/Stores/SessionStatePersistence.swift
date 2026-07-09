import Foundation

/// Persists the parts of session state that aren't derivable from tmux/git — the "needs you"
/// queue and each session's last response — so they survive an app restart. (Sessions
/// themselves survive because tmux owns them; this is the layer pass adds on top.)
enum SessionStatePersistence {
    struct Snapshot: Codable {
        struct Pending: Codable {
            var kind: String        // Attention.Kind rawValue
            var receivedAt: Date
            var preview: String
        }
        var pending: [String: Pending] = [:]   // only .pending states are worth restoring
        var lastMessages: [String: String] = [:]
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
