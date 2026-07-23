import Foundation

enum ProjectCreationService {
    static let defaultParentDirectoryKey = "newProjectParentDirectory"

    enum Failure: LocalizedError, Equatable {
        case invalidName
        case parentUnavailable
        case alreadyExists
        case createFailed(String)
        case gitInitFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidName:
                return "Use a folder name without / or :."
            case .parentUnavailable:
                return "The new-projects location is not available."
            case .alreadyExists:
                return "A file or folder with that name already exists."
            case .createFailed(let message):
                return "Could not create the project: \(message)"
            case .gitInitFailed(let message):
                return "Could not initialize Git: \(message)"
            }
        }
    }

    /// Creates an empty Git project under a user-selected collection directory.
    /// `initializeGit` is injectable for filesystem-only unit tests.
    static func createProject(
        named rawName: String,
        in parentPath: String,
        initializeGit: Bool = true,
        fileManager: FileManager = .default
    ) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidName(name) else { throw Failure.invalidName }

        let parent = URL(fileURLWithPath: parentPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw Failure.parentUnavailable
        }

        let project = parent.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard !fileManager.fileExists(atPath: project.path) else { throw Failure.alreadyExists }

        do {
            try fileManager.createDirectory(at: project, withIntermediateDirectories: false)
        } catch {
            throw Failure.createFailed(error.localizedDescription)
        }

        guard initializeGit else { return project.path }
        let git = Shell.resolveViaLoginShell("git") ?? "/usr/bin/git"
        let result = Shell.run(git, ["init", project.path])
        guard result.ok else {
            // The directory was created by this call and is still empty when git init fails.
            try? fileManager.removeItem(at: project)
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.gitInitFailed(message.isEmpty ? "git exited with \(result.code)" : message)
        }
        return project.path
    }

    static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed != "."
            && trimmed != ".."
            && !trimmed.hasPrefix(".")
            && !trimmed.contains("/")
            && !trimmed.contains(":")
            && !trimmed.contains("\0")
    }
}
