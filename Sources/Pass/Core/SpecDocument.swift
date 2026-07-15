import Foundation

/// ONE executable spec document per project, stored at `<project>/.pass/specs.json`.
/// The document holds the project's dev-server command plus a NUMBERED list of specs, each
/// carrying its own work status — so progress reads at a glance, and agents update the same
/// file in place (the repository copy is the single source of truth; commit it, share it).
struct SpecDocument: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var title: String = ""
    var development: SpecDevelopment = .init()
    /// The next number to assign. Numbers are permanent — deleting spec 2 never renumbers
    /// spec 3, so "스펙 3" stays meaningful in conversations, commits and agent prompts.
    var nextNumber: Int = 1
    var specs: [Spec] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, title, development, nextNumber, specs, createdAt, updatedAt
    }

    /// Defaults keep hand-edited and older JSON decodable as the schema grows.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        development = try c.decodeIfPresent(SpecDevelopment.self, forKey: .development) ?? .init()
        specs = try c.decodeIfPresent([Spec].self, forKey: .specs) ?? []
        let maxNumber = specs.map(\.number).max() ?? 0
        nextNumber = Swift.max(try c.decodeIfPresent(Int.self, forKey: .nextNumber) ?? 1, maxNumber + 1)
        let now = Date()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

/// How to run the project while working on its specs. Only executed on an explicit click;
/// the working directory is validated to stay inside the repository.
struct SpecDevelopment: Codable, Hashable, Sendable {
    var command: String = ""          // e.g. "pnpm dev"
    var workingDirectory: String = "" // project-relative; empty = repo root
    var url: String = ""              // e.g. "http://localhost:3000"

    init() {}

    private enum CodingKeys: String, CodingKey { case command, workingDirectory, url }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
    }
}

/// One numbered spec inside the document.
struct Spec: Identifiable, Codable, Hashable, Sendable {
    var number: Int
    var title: String
    var detail: String = ""
    var status: SpecStatus = .draft
    /// The session that last worked on this spec (reused while it's alive).
    var agentSession: String?
    /// Human rework notes, oldest first — agents see the latest one in their prompt.
    var feedback: [SpecFeedback] = []

    var id: Int { number }

    init(number: Int, title: String) {
        self.number = number
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case number, title, detail, status, agentSession, feedback
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Spec \(number)"
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        // Tolerate unknown status strings (typos from hand edits / older agents) as .draft.
        let raw = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        status = SpecStatus(rawValue: raw) ?? .draft
        agentSession = try c.decodeIfPresent(String.self, forKey: .agentSession)
        feedback = try c.decodeIfPresent([SpecFeedback].self, forKey: .feedback) ?? []
    }
}

struct SpecFeedback: Codable, Hashable, Sendable {
    var text: String
    var createdAt: Date = Date()

    init(text: String) { self.text = text }

    private enum CodingKeys: String, CodingKey { case text, createdAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// A spec's work state — a badge in the UI, and the field agents update when they finish.
enum SpecStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case draft        // being written
    case ready        // spec agreed, not started
    case implementing // an agent is building it
    case verifying    // an agent is checking acceptance
    case needsReview  // waiting for the human
    case verified     // done
    case blocked      // can't proceed

    var label: String {
        switch self {
        case .draft:        return "Draft"
        case .ready:        return "Ready"
        case .implementing: return "Implementing"
        case .verifying:    return "Verifying"
        case .needsReview:  return "Needs review"
        case .verified:     return "Verified"
        case .blocked:      return "Blocked"
        }
    }
}
