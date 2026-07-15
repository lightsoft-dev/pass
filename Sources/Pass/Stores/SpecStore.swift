import Foundation
import Observation

/// Reads and writes each project's single spec document (`<root>/.pass/specs.json`).
/// The repository file is the source of truth — there is no app-private mirror to drift.
@MainActor
@Observable
final class SpecStore {
    private(set) var documentByProject: [String: SpecDocument] = [:]
    private(set) var errorByProject: [String: String] = [:]

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    static func fileURL(projectRoot: String) -> URL {
        URL(fileURLWithPath: projectRoot, isDirectory: true)
            .appendingPathComponent(".pass", isDirectory: true)
            .appendingPathComponent("specs.json")
    }

    func document(for projectRoot: String) -> SpecDocument? {
        documentByProject[projectRoot]
    }

    /// Re-read disk so edits made by an agent (or a future sync client) appear in the UI.
    /// A broken file keeps the last good in-memory copy and surfaces the error instead.
    func reload(projectRoot: String) {
        let url = Self.fileURL(projectRoot: projectRoot)
        guard fileManager.fileExists(atPath: url.path) else {
            documentByProject[projectRoot] = nil
            errorByProject[projectRoot] = nil
            return
        }
        do {
            let doc = try Self.decoder().decode(SpecDocument.self, from: Data(contentsOf: url))
            documentByProject[projectRoot] = doc
            errorByProject[projectRoot] = nil
        } catch {
            errorByProject[projectRoot] = "specs.json: \(error.localizedDescription)"
        }
    }

    /// The project's document, created on first use (titled after the repo folder).
    @discardableResult
    func ensureDocument(projectRoot: String) throws -> SpecDocument {
        reload(projectRoot: projectRoot)
        if let doc = documentByProject[projectRoot] { return doc }
        var doc = SpecDocument()
        doc.title = URL(fileURLWithPath: projectRoot).lastPathComponent
        try save(doc, projectRoot: projectRoot)
        return documentByProject[projectRoot] ?? doc
    }

    func save(_ document: SpecDocument, projectRoot: String) throws {
        var copy = document
        copy.schemaVersion = SpecDocument.currentSchemaVersion
        copy.updatedAt = Date()
        let url = Self.fileURL(projectRoot: projectRoot)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try Self.encoder().encode(copy).write(to: url, options: .atomic)
        documentByProject[projectRoot] = copy
        errorByProject[projectRoot] = nil
    }

    /// Append a new spec with the next stable number (numbers are never reused).
    @discardableResult
    func addSpec(projectRoot: String, title: String) throws -> Spec {
        var doc = try ensureDocument(projectRoot: projectRoot)
        let spec = Spec(number: doc.nextNumber, title: title)
        doc.nextNumber += 1
        doc.specs.append(spec)
        try save(doc, projectRoot: projectRoot)
        return spec
    }

    func updateSpec(projectRoot: String, number: Int, _ mutate: (inout Spec) -> Void) throws {
        guard var doc = documentByProject[projectRoot],
              let idx = doc.specs.firstIndex(where: { $0.number == number }) else {
            throw SpecStoreError.notFound
        }
        mutate(&doc.specs[idx])
        try save(doc, projectRoot: projectRoot)
    }

    func removeSpec(projectRoot: String, number: Int) throws {
        guard var doc = documentByProject[projectRoot] else { throw SpecStoreError.notFound }
        doc.specs.removeAll { $0.number == number }
        try save(doc, projectRoot: projectRoot) // nextNumber untouched — numbers are permanent
    }

    func updateDevelopment(projectRoot: String, _ mutate: (inout SpecDevelopment) -> Void) throws {
        var doc = try ensureDocument(projectRoot: projectRoot)
        mutate(&doc.development)
        try save(doc, projectRoot: projectRoot)
    }

    /// Resolve the document's dev working directory without letting a synced/hand-edited file
    /// escape the repository. nil = unsafe (absolute or ../ traversal).
    func developmentWorkingDirectory(projectRoot: String) -> String? {
        let rel = documentByProject[projectRoot]?.development.workingDirectory ?? ""
        guard !rel.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL
        let candidate = root.appendingPathComponent(rel.isEmpty ? "." : rel).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPrefix) else { return nil }
        return candidate.path
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys] // diff-friendly for git
        return e
    }
}

enum SpecStoreError: Error {
    case notFound
}
