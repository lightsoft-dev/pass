import Foundation
import Observation

/// Reads and writes executable feature documents inside each project repository.
/// The repository is the source of truth; there is no app-private mirror to drift out of sync.
@MainActor
@Observable
final class FeatureStore {
    private(set) var documentsByProject: [String: [FeatureDocument]] = [:]
    private(set) var loadErrorByProject: [String: String] = [:]

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func documents(for projectRoot: String) -> [FeatureDocument] {
        documentsByProject[projectRoot, default: []]
    }

    func document(projectRoot: String, id: String) -> FeatureDocument? {
        documents(for: projectRoot).first { $0.id == id }
    }

    /// Re-read disk so edits made by a local agent or a future sync client appear in the UI.
    func reload(projectRoot: String) {
        let directory = featuresDirectory(projectRoot: projectRoot)
        guard fileManager.fileExists(atPath: directory.path) else {
            documentsByProject[projectRoot] = []
            loadErrorByProject[projectRoot] = nil
            return
        }

        do {
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "json" }

            var loaded: [FeatureDocument] = []
            var errors: [String] = []
            let decoder = Self.makeDecoder()
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    let document = try decoder.decode(FeatureDocument.self, from: Data(contentsOf: url))
                    guard document.id == url.deletingPathExtension().lastPathComponent else {
                        errors.append("\(url.lastPathComponent): id must match the file name")
                        continue
                    }
                    loaded.append(document)
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            documentsByProject[projectRoot] = loaded.sorted { $0.updatedAt > $1.updatedAt }
            loadErrorByProject[projectRoot] = errors.isEmpty ? nil : errors.joined(separator: "\n")
        } catch {
            documentsByProject[projectRoot] = []
            loadErrorByProject[projectRoot] = error.localizedDescription
        }
    }

    @discardableResult
    func create(projectRoot: String, title: String = "New feature") throws -> FeatureDocument {
        try ensureStorage(projectRoot: projectRoot)
        reload(projectRoot: projectRoot)

        let base = Slug.make(title).isEmpty ? "feature" : Slug.make(title)
        var id = base
        var suffix = 2
        let existing = Set(documents(for: projectRoot).map(\.id))
        while existing.contains(id) || fileManager.fileExists(atPath: featureURL(projectRoot: projectRoot, id: id).path) {
            id = "\(base)-\(suffix)"
            suffix += 1
        }

        let document = FeatureDocument(
            id: id,
            title: title,
            summary: "Describe the user-visible behavior and why this feature exists.",
            requirements: ["Describe one implementation requirement."],
            acceptanceCriteria: ["Describe one observable success condition."],
            development: FeatureDevelopment(
                guide: ["Start the development server.", "Follow the acceptance criteria in order."]
            )
        )
        try save(document, projectRoot: projectRoot)
        return document
    }

    func save(_ document: FeatureDocument, projectRoot: String) throws {
        guard Self.isSafeID(document.id) else { throw FeatureStoreError.invalidID }
        try ensureStorage(projectRoot: projectRoot)
        var copy = document
        copy.schemaVersion = FeatureDocument.currentSchemaVersion
        copy.updatedAt = Date()
        let data = try Self.makeEncoder().encode(copy)
        try data.write(to: featureURL(projectRoot: projectRoot, id: copy.id), options: .atomic)
        reload(projectRoot: projectRoot)
    }

    func markVerified(projectRoot: String, id: String) throws {
        guard var document = document(projectRoot: projectRoot, id: id) else {
            throw FeatureStoreError.notFound
        }
        document.status = .verified
        try save(document, projectRoot: projectRoot)
    }

    /// Files claimed by the agent but absent from this checkout. This is a cheap, deterministic
    /// implementation-health signal in addition to the agent-authored checks in JSON.
    func missingImplementationFiles(for document: FeatureDocument, projectRoot: String) -> [String] {
        document.implementation.files.filter { relative in
            guard let url = safeProjectURL(projectRoot: projectRoot, relativePath: relative) else { return true }
            return !fileManager.fileExists(atPath: url.path)
        }
    }

    /// Resolve a portable project-relative working directory without allowing a synced document
    /// to escape the repository. The command is only executed after an explicit button click.
    func developmentWorkingDirectory(for document: FeatureDocument, projectRoot: String) -> String? {
        safeProjectURL(projectRoot: projectRoot, relativePath: document.development.workingDirectory)?.path
    }

    func fileURL(projectRoot: String, id: String) -> URL {
        featureURL(projectRoot: projectRoot, id: id)
    }

    private func safeProjectURL(projectRoot: String, relativePath: String) -> URL? {
        guard !relativePath.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath.isEmpty ? "." : relativePath).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate
    }

    private func ensureStorage(projectRoot: String) throws {
        let directory = featuresDirectory(projectRoot: projectRoot)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = directory.deletingLastPathComponent().appendingPathComponent("feature.schema.json")
        if !fileManager.fileExists(atPath: schema.path) {
            try Data(Self.schemaJSON.utf8).write(to: schema, options: .atomic)
        }
    }

    private func featuresDirectory(projectRoot: String) -> URL {
        URL(fileURLWithPath: projectRoot, isDirectory: true)
            .appendingPathComponent(".pass", isDirectory: true)
            .appendingPathComponent("features", isDirectory: true)
    }

    private func featureURL(projectRoot: String, id: String) -> URL {
        featuresDirectory(projectRoot: projectRoot).appendingPathComponent(id).appendingPathExtension("json")
    }

    private static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id == Slug.make(id) && !id.contains("/") && !id.contains("..")
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Checked into each project alongside feature files for editor validation and future cloud
    /// ingestion. Kept intentionally boring: JSON Schema 2020-12 and portable scalar fields.
    private static let schemaJSON = #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://pass.local/schemas/feature-v1.json",
      "title": "Pass software feature",
      "type": "object",
      "required": ["schemaVersion", "id", "title", "status", "requirements", "acceptanceCriteria", "development", "implementation"],
      "properties": {
        "schemaVersion": { "const": 1 },
        "id": { "type": "string", "pattern": "^[a-z0-9]+(?:-[a-z0-9]+)*$" },
        "title": { "type": "string", "minLength": 1 },
        "summary": { "type": "string" },
        "status": { "enum": ["draft", "ready", "implementing", "verifying", "needsReview", "verified", "blocked"] },
        "requirements": { "type": "array", "items": { "type": "string" } },
        "acceptanceCriteria": { "type": "array", "items": { "type": "string" } },
        "development": {
          "type": "object",
          "properties": {
            "command": { "type": "string" },
            "workingDirectory": { "type": "string" },
            "url": { "type": "string" },
            "testCommand": { "type": "string" },
            "guide": { "type": "array", "items": { "type": "string" } }
          },
          "additionalProperties": false
        },
        "implementation": {
          "type": "object",
          "properties": {
            "preferredAgent": { "enum": ["claude", "codex", "pi"] },
            "agentSession": { "type": ["string", "null"] },
            "summary": { "type": "string" },
            "files": { "type": "array", "items": { "type": "string" } },
            "checks": {
              "type": "array",
              "items": {
                "type": "object",
                "required": ["id", "name", "status", "details"],
                "properties": {
                  "id": { "type": "string" },
                  "name": { "type": "string" },
                  "status": { "enum": ["pending", "passed", "failed"] },
                  "details": { "type": "string" }
                },
                "additionalProperties": false
              }
            }
          },
          "additionalProperties": false
        },
        "reviews": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["id", "createdAt", "feedback"],
            "properties": {
              "id": { "type": "string" },
              "createdAt": { "type": "string", "format": "date-time" },
              "feedback": { "type": "string" },
              "resolution": { "type": ["string", "null"] }
            },
            "additionalProperties": false
          }
        },
        "createdAt": { "type": "string", "format": "date-time" },
        "updatedAt": { "type": "string", "format": "date-time" }
      },
      "additionalProperties": false
    }
    """#
}

enum FeatureStoreError: LocalizedError {
    case invalidID
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidID: return "Feature id must be a lowercase, hyphenated slug."
        case .notFound: return "Feature document was not found."
        }
    }
}
