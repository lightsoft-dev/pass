import Foundation

enum ProjectCreationService {
    static let defaultParentDirectoryKey = "newProjectParentDirectory"

    struct GitHubRepository: Equatable, Sendable {
        let owner: String
        let name: String
        let cloneURL: String

        var displayName: String { "\(owner)/\(name)" }
    }

    enum Failure: LocalizedError, Equatable {
        case invalidName
        case parentUnavailable
        case alreadyExists
        case invalidRepositoryURL
        case createFailed(String)
        case gitInitFailed(String)
        case cloneFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidName:
                return "Use a folder name without / or :."
            case .parentUnavailable:
                return "The new-projects location is not available."
            case .alreadyExists:
                return "A file or folder with that name already exists."
            case .invalidRepositoryURL:
                return "Enter a GitHub repository URL such as https://github.com/owner/repository."
            case .createFailed(let message):
                return "Could not create the project: \(message)"
            case .gitInitFailed(let message):
                return "Could not initialize Git: \(message)"
            case .cloneFailed(let message):
                return "Could not clone the GitHub repository: \(message)"
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

    /// Clone a GitHub repository into the configured projects directory. The destination name
    /// always comes from the repository URL, and `--` keeps URL text out of Git's option parser.
    static func cloneProject(
        from rawRepository: String,
        in parentPath: String,
        fileManager: FileManager = .default,
        runGit: (_ executable: String, _ arguments: [String]) -> ProcResult = {
            Shell.run($0, $1, extraEnv: ["GIT_TERMINAL_PROMPT": "0"])
        }
    ) throws -> String {
        guard let repository = githubRepository(from: rawRepository) else {
            throw Failure.invalidRepositoryURL
        }

        let parent = URL(fileURLWithPath: parentPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw Failure.parentUnavailable
        }

        let project = parent.appendingPathComponent(repository.name, isDirectory: true)
            .standardizedFileURL
        guard !fileManager.fileExists(atPath: project.path) else { throw Failure.alreadyExists }

        let git = Shell.resolveViaLoginShell("git") ?? "/usr/bin/git"
        let result = runGit(
            git,
            ["clone", "--origin", "origin", "--", repository.cloneURL, project.path]
        )
        guard result.ok else {
            // Only remove the destination we proved did not exist before this clone attempt.
            try? fileManager.removeItem(at: project)
            let detail = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "git exited with \(result.code)"
            throw Failure.cloneFailed(detail)
        }

        guard fileManager.fileExists(atPath: project.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw Failure.cloneFailed("Git finished without creating the project folder.")
        }
        return project.path
    }

    /// Accept the two GitHub clone forms users commonly paste: the browser HTTPS URL and SSH.
    /// Browser URLs are normalized to an HTTPS clone URL so `/tree/...` pages are rejected rather
    /// than silently cloning a different target than the one shown in the palette.
    static func githubRepository(from rawValue: String) -> GitHubRepository? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("-") else { return nil }

        if value.lowercased().hasPrefix("git@github.com:") {
            let start = value.index(value.startIndex, offsetBy: "git@github.com:".count)
            guard let parts = repositoryParts(String(value[start...])) else { return nil }
            return GitHubRepository(
                owner: parts.owner,
                name: parts.name,
                cloneURL: "git@github.com:\(parts.owner)/\(parts.name).git"
            )
        }

        guard let components = URLComponents(string: value),
              components.query == nil,
              components.fragment == nil,
              components.port == nil,
              let host = components.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            return nil
        }

        let scheme = components.scheme?.lowercased()
        guard scheme == "https" || (scheme == "ssh" && components.user == "git") else {
            return nil
        }
        guard let parts = repositoryParts(components.path) else { return nil }
        let cloneURL = scheme == "ssh"
            ? "git@github.com:\(parts.owner)/\(parts.name).git"
            : "https://github.com/\(parts.owner)/\(parts.name).git"
        return GitHubRepository(owner: parts.owner, name: parts.name, cloneURL: cloneURL)
    }

    static func looksLikeGitHubRepositoryInput(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().contains("github.com")
    }

    private static func repositoryParts(_ rawPath: String) -> (owner: String, name: String)? {
        let pieces = rawPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard pieces.count == 2 else { return nil }
        let owner = pieces[0]
        var name = pieces[1]
        if name.lowercased().hasSuffix(".git") { name.removeLast(4) }
        guard safeRepositoryComponent(owner), safeRepositoryComponent(name) else { return nil }
        return (owner, name)
    }

    private static func safeRepositoryComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains(":")
            && !value.contains("\0")
            && value.unicodeScalars.allSatisfy { !$0.properties.isWhitespace }
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
