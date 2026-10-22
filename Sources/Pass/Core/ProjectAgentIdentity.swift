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

    static func isManager(name: String, projectRoot: String) -> Bool {
        name == sessionName(for: projectRoot)
    }

    static func launchCommand(for root: String) -> String? {
        guard let pi = Shell.resolveViaLoginShell("pi"),
              let prompt = Bundle.main.path(forResource: "ProjectAgentInstructions", ofType: "md")
        else { return nil }
        let title = URL(fileURLWithPath: root).lastPathComponent + " · project agent"
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
