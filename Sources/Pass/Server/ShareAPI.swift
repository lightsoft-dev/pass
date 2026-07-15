import Foundation

// JSON shapes for the share-extension bridge. The PassShare extension keeps a mirrored copy
// (separate target, no shared framework) — keep the two in sync.

struct ShareTargetsResponse: Codable {
    struct SessionTarget: Codable {
        var name: String     // tmux session name (send target)
        var display: String  // what the picker shows
        var agent: String
    }
    struct ProjectTarget: Codable {
        var root: String     // project root (new-session target)
        var name: String
    }
    var sessions: [SessionTarget]
    var projects: [ProjectTarget]
}

struct ShareSendRequest: Codable {
    var session: String?      // send into this live session…
    var projectRoot: String?  // …or start a new session here (default agent)
    var note: String?         // the user's 부가 설명 typed in the share sheet
    var text: String?         // shared text / URL
    var files: [String]?      // paths the extension saved (images, file shares)
}

struct ShareSendResponse: Codable {
    var ok: Bool
    var error: String?
}

/// Serves the OS share extension: lists targets, and delivers a shared payload either into a
/// live session (via ReplyInjector) or as a brand-new session's initial prompt.
@MainActor
enum ShareAPI {
    static func targets(_ appModel: AppModel) -> Data {
        let live = appModel.sessions?.sessions ?? []
        let sessions = live.map {
            ShareTargetsResponse.SessionTarget(name: $0.name, display: $0.displayName,
                                               agent: $0.agent.rawValue)
        }
        let liveRoots = Set(live.map(\.projectRoot))
        let projects = (appModel.projects?.projects ?? [])
            .filter { !liveRoots.contains($0.rootPath) }
            .map { ShareTargetsResponse.ProjectTarget(root: $0.rootPath, name: $0.name) }
        let resp = ShareTargetsResponse(sessions: sessions, projects: projects)
        return (try? JSONEncoder().encode(resp)) ?? Data("{}".utf8)
    }

    static func send(_ appModel: AppModel, body: Data) async -> Data {
        func reply(_ ok: Bool, _ error: String? = nil) -> Data {
            (try? JSONEncoder().encode(ShareSendResponse(ok: ok, error: error))) ?? Data()
        }
        guard let req = try? JSONDecoder().decode(ShareSendRequest.self, from: body) else {
            return reply(false, "bad request")
        }
        let message = composeMessage(req)
        guard !message.isEmpty else { return reply(false, "nothing to send") }

        if let name = req.session {
            switch await appModel.reply(to: name, text: message) {
            case .delivered: return reply(true)
            case .refusedShell: return reply(false, "agent not running in that session")
            case .error(let e): return reply(false, e)
            }
        }
        if let root = req.projectRoot {
            await appModel.sessions?.createSession(projectDir: root, initialPrompt: message)
            return reply(true)
        }
        return reply(false, "no target")
    }

    /// note + shared text/URL + saved file paths, blank-line separated — one message the
    /// agent can act on (file paths are readable by the agent directly).
    private static func composeMessage(_ req: ShareSendRequest) -> String {
        var parts: [String] = []
        if let n = req.note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { parts.append(n) }
        if let t = req.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { parts.append(t) }
        if let f = req.files, !f.isEmpty { parts.append(f.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }
}
