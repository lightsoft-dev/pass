import CryptoKit
import Foundation

/// Stable identity for the one Pi coordinator owned by a registered project.
enum ProjectAgentIdentity {
    private static func hash(_ root: String) -> String {
        SHA256.hash(data: Data(root.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func sessionName(for root: String) -> String {
        "pass-manager-" + String(hash(root).prefix(16))
    }

    static func piSessionID(for root: String) -> String {
        let value = hash(root)
        let end = value.index(value.startIndex, offsetBy: 32)
        let id = String(value[..<end])
        return "\(id.prefix(8))-\(id.dropFirst(8).prefix(4))-\(id.dropFirst(12).prefix(4))-\(id.dropFirst(16).prefix(4))-\(id.dropFirst(20))"
    }

    /// Separate from the earlier interactive Pi session, which may still be running in tmux.
    static func rpcSessionID(for root: String) -> String {
        piSessionID(for: root + "#pass-rpc")
    }

    static func isManager(name: String, projectRoot: String) -> Bool {
        name == sessionName(for: projectRoot)
    }

    static func launchCommand(for root: String) -> String? {
        guard let pi = Shell.resolveViaLoginShell("pi"),
              let prompt = Bundle.main.path(forResource: "ProjectAgentInstructions", ofType: "md")
        else { return nil }
        let title = URL(fileURLWithPath: root).lastPathComponent + " · Pa"
        return [Shell.singleQuoted(pi), "--no-extensions", "--session-id", piSessionID(for: root),
                "--name", Shell.singleQuoted(title),
                "--append-system-prompt", Shell.singleQuoted(prompt)].joined(separator: " ")
    }
}

enum ProjectAgentFailure: Error, LocalizedError {
    case unregisteredProject
    case piUnavailable
    case launchFailed

    var errorDescription: String? {
        switch self {
        case .unregisteredProject: return "This project is no longer registered in Pass."
        case .piUnavailable: return "Pi is unavailable. Install pi and restart Pass."
        case .launchFailed: return "The project agent could not start in tmux."
        }
    }
}

/// Pi's selected provider must have a usable local credential before a project agent can reply.
/// OAuth refresh may also succeed later; an expired credential is a good reason to offer login.
enum PiAuthentication {
    static func defaultModelLabel(agentDirectory: URL? = nil) -> String? {
        let directory = agentDirectory ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".pi/agent", isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = settings["defaultProvider"] as? String,
              let model = settings["defaultModel"] as? String else { return nil }
        return provider + "/" + model
    }

    static func hasCredential(for provider: String, agentDirectory: URL? = nil) -> Bool {
        let directory = agentDirectory ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".pi/agent", isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("auth.json")),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credential = auth[provider] as? [String: Any] else { return false }
        if credential["type"] as? String == "api_key" {
            return (credential["key"] as? String)?.isEmpty == false
        }
        if credential["type"] as? String == "oauth",
           let expiry = credential["expires"] as? Double,
           let access = credential["access"] as? String {
            return !access.isEmpty && expiry > Date().timeIntervalSince1970 * 1_000 + 60_000
        }
        return false
    }

    static func needsLogin(now: Date = Date(), agentDirectory: URL? = nil) -> Bool {
        let directory = agentDirectory ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".pi/agent", isDirectory: true)
        guard let settingsData = try? Data(contentsOf: directory.appendingPathComponent("settings.json")),
              let settings = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
              let provider = settings["defaultProvider"] as? String, !provider.isEmpty,
              let authData = try? Data(contentsOf: directory.appendingPathComponent("auth.json")),
              let auth = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let credential = auth[provider] as? [String: Any] else { return true }

        switch credential["type"] as? String {
        case "api_key":
            return (credential["key"] as? String)?.isEmpty != false
        case "oauth":
            guard let expires = credential["expires"] as? Double,
                  let access = credential["access"] as? String else { return true }
            return access.isEmpty || expires <= now.timeIntervalSince1970 * 1_000 + 60_000
        default:
            return true
        }
    }
}
