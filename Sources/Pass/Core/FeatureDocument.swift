import Foundation

/// A project-local, executable specification for one software feature.
///
/// Documents live in `<project>/.pass/features/<id>.json`. The model deliberately uses only
/// portable values (relative paths, commands, URLs and agent-neutral status) so the files can be
/// committed today and moved to a collaborative cloud store later without a migration.
struct FeatureDocument: Identifiable, Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var id: String
    var title: String
    var summary: String
    var status: FeatureStatus
    var requirements: [String]
    var acceptanceCriteria: [String]
    var development: FeatureDevelopment
    var implementation: FeatureImplementation
    var reviews: [FeatureReview]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        title: String,
        summary: String = "",
        status: FeatureStatus = .draft,
        requirements: [String] = [],
        acceptanceCriteria: [String] = [],
        development: FeatureDevelopment = .init(),
        implementation: FeatureImplementation = .init(),
        reviews: [FeatureReview] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.status = status
        self.requirements = requirements
        self.acceptanceCriteria = acceptanceCriteria
        self.development = development
        self.implementation = implementation
        self.reviews = reviews
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, summary, status, requirements, acceptanceCriteria
        case development, implementation, reviews, createdAt, updatedAt
    }

    /// Defaults make hand-edited and older JSON documents resilient as the schema grows.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        status = try c.decodeIfPresent(FeatureStatus.self, forKey: .status) ?? .draft
        requirements = try c.decodeIfPresent([String].self, forKey: .requirements) ?? []
        acceptanceCriteria = try c.decodeIfPresent([String].self, forKey: .acceptanceCriteria) ?? []
        development = try c.decodeIfPresent(FeatureDevelopment.self, forKey: .development) ?? .init()
        implementation = try c.decodeIfPresent(FeatureImplementation.self, forKey: .implementation) ?? .init()
        reviews = try c.decodeIfPresent([FeatureReview].self, forKey: .reviews) ?? []
        let now = Date()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

enum FeatureStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case draft
    case ready
    case implementing
    case verifying
    case needsReview
    case verified
    case blocked

    var label: String {
        switch self {
        case .draft: return "Draft"
        case .ready: return "Ready"
        case .implementing: return "Implementing"
        case .verifying: return "Verifying"
        case .needsReview: return "Needs review"
        case .verified: return "Verified"
        case .blocked: return "Blocked"
        }
    }

    var symbol: String {
        switch self {
        case .draft: return "doc"
        case .ready: return "checklist"
        case .implementing: return "hammer"
        case .verifying: return "testtube.2"
        case .needsReview: return "eye"
        case .verified: return "checkmark.seal.fill"
        case .blocked: return "exclamationmark.octagon.fill"
        }
    }
}

struct FeatureDevelopment: Codable, Hashable, Sendable {
    /// Shell command the user explicitly runs from the document, for example `npm run dev`.
    var command: String
    /// Portable path relative to the project root. Absolute paths and escaping `..` are refused.
    var workingDirectory: String
    var url: String
    var testCommand: String
    var guide: [String]

    init(command: String = "", workingDirectory: String = ".", url: String = "",
         testCommand: String = "", guide: [String] = []) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.url = url
        self.testCommand = testCommand
        self.guide = guide
    }

    private enum CodingKeys: String, CodingKey { case command, workingDirectory, url, testCommand, guide }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? "."
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        testCommand = try c.decodeIfPresent(String.self, forKey: .testCommand) ?? ""
        guide = try c.decodeIfPresent([String].self, forKey: .guide) ?? []
    }
}

struct FeatureImplementation: Codable, Hashable, Sendable {
    var preferredAgent: AgentKind
    /// Last local session is a hint only. A collaborator can safely ignore it and start another.
    var agentSession: String?
    var summary: String
    /// Project-relative paths touched by the implementation.
    var files: [String]
    var checks: [FeatureCheck]

    init(preferredAgent: AgentKind = .claude, agentSession: String? = nil,
         summary: String = "", files: [String] = [], checks: [FeatureCheck] = []) {
        self.preferredAgent = preferredAgent
        self.agentSession = agentSession
        self.summary = summary
        self.files = files
        self.checks = checks
    }

    private enum CodingKeys: String, CodingKey { case preferredAgent, agentSession, summary, files, checks }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preferredAgent = try c.decodeIfPresent(AgentKind.self, forKey: .preferredAgent) ?? .claude
        agentSession = try c.decodeIfPresent(String.self, forKey: .agentSession)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        checks = try c.decodeIfPresent([FeatureCheck].self, forKey: .checks) ?? []
    }
}

struct FeatureCheck: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var status: FeatureCheckStatus
    var details: String

    init(id: String = UUID().uuidString, name: String, status: FeatureCheckStatus = .pending,
         details: String = "") {
        self.id = id
        self.name = name
        self.status = status
        self.details = details
    }
}

enum FeatureCheckStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case passed
    case failed
}

struct FeatureReview: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var createdAt: Date
    var feedback: String
    var resolution: String?

    init(id: String = UUID().uuidString, createdAt: Date = Date(), feedback: String,
         resolution: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.feedback = feedback
        self.resolution = resolution
    }
}
